import { router, promptAction, MeasureText } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../model/Prefs.ets';
import { FileService } from '../model/FileService.ets';
import { UtilTextCodecs } from '../model/TextCodecs.ets';
import type { TextCodecs } from '../core/EncodingDetector.ets';
import type { EditorMode } from '../model/Types.ets';
import {
  findAll, replaceAllLiteral, replaceAllRegex, replaceRange, replaceCurrentRegex
} from '../core/SearchEngine.ets';
import {
  UTF_8, USER_CHOICES, looksBinary, resolveCharset, stripBom,
  labelOf, isAuto
} from '../core/EncodingDetector.ets';
import {
  tierFor, readLimit, allowsSave, readOnlyReason, FULL_VIEW_LIMIT, HEAD_LIMIT
} from '../core/FileSizePolicy.ets';
import { defaultFileName, sanitize, ensureTxtExtension, parentOf } from '../core/SaveNames.ets';
import { decide } from '../core/StartupDecision.ets';
import { write as atomicWrite, restoreFromBackup, backupExists } from '../core/AtomicFileOps.ets';

/**
 * 编辑器页（对应安卓版 MainActivity）。
 *
 * 复刻：三态模型（草稿/文件/URI）、冷启动路由、原子保存+.bak、自动保存、
 * 查找替换（大小写/全词/正则）、编码切换、记住行号、分享接收、只读预览。
 *
 * 平台差异（ArkUI 限制，如实说明）：
 * 1. TextArea 不支持自绘与 span 高亮：行号栏实现为底部状态条
 *    “共 N 行 · 第 K 行”（行号开关控制其显隐）；查找只显示计数并跳转，
 *    不做全文染色。只读大文件用 List 懒加载实现虚拟化（行内仍有行号）。
 * 2. TextArea 恒为自动换行（ArkUI 无横向滚动开关）；“自动换行”设置项
 *    控制只读预览是否换行。
 * 3. 光标行经 TextArea.onTextSelectionChange 实时跟踪（含用户点选），
 *    行号状态条/记住行号/查找跳转都准确；顶栏样式与按钮收纳对齐安卓
 *    DarkActionBar（深底 + 白图标，常驻 关闭/保存/查找 + ⋮ 溢出菜单）。
 * 4. 真实路径 ↔ Picker URI：FILE 模式既可是沙箱路径也可是持久授权 URI；
 *    沙箱内走原子写，Picker URI 走覆盖写（save 面板拿到的 URI 本来就是
 *    用户刚确认的位置，不做 .bak）。
 */

const FIND_DEBOUNCE_MS: number = 150;
const VIEWER_LINE_CAP: number = 50000;
const DOMAIN: number = 0xFF00;
const TAG: string = 'PaperIndex';

@CustomDialog
struct SaveDialogContent {
  controller?: CustomDialogController;
  fileName: string = '';
  dirPath: string = '';
  onBrowse: (name: string) => void = (name: string): void => {};
  onSystem: (name: string) => void = (name: string): void => {};
  onOk: (name: string) => void = (name: string): void => {};

  build() {
    Column({ space: 8 }) {
      Text('保存文件').fontSize(18).fontWeight(FontWeight.Bold);
      // 对齐 dialog_save.xml：文件名输入 + [保存到：][目录][浏览图标]
      TextInput({ placeholder: '文件名（默认 .txt）', text: this.fileName })
        .fontSize(16)
        .onChange((v: string): void => {
          this.fileName = v;
        });
      Row({ space: 0 }) {
        Text('保存到：').fontSize(14);
        Text(this.dirPath === '' ? '（未选择）' : this.dirPath)
          .fontSize(13)
          .fontColor('#FF444444')
          .layoutWeight(1)
          .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        Image($r('app.media.ic_folder_open_b'))
          .width(24)
          .height(24)
          .margin(8)
          .id('saveBrowse')
          .onClick((): void => {
            const n: string = this.fileName;
            this.controller?.close();
            this.onBrowse(n);
          });
      }.width('100%');
      // 对话框按钮统一用文字样式（同安卓 AlertDialog），“其他位置…”走系统面板
      Row({ space: 4 }) {
        Button('其他位置…')
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .onClick((): void => {
            const n: string = this.fileName;
            this.controller?.close();
            this.onSystem(n);
          });
        Button('取消')
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .id('saveCancel')
          .onClick((): void => {
            this.controller?.close();
          });
        Button('保存')
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .id('saveOk')
          .onClick((): void => {
            const n: string = this.fileName;
            this.controller?.close();
            this.onOk(n);
          });
      }.justifyContent(FlexAlign.End).width('100%');
    }.padding(20).width('90%');
  }
}

@CustomDialog
struct RenameDialogContent {
  controller?: CustomDialogController;
  fileName: string = '';
  onOk: (name: string) => void = (name: string): void => {};

  build() {
    Column({ space: 8 }) {
      Text('重命名').fontSize(18).fontWeight(FontWeight.Bold);
      TextInput({ placeholder: '新文件名', text: this.fileName })
        .fontSize(16)
        .onChange((v: string): void => {
          this.fileName = v;
        });
      Row({ space: 4 }) {
        Button('取消')
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .id('renameCancel')
          .onClick((): void => {
            this.controller?.close();
          });
        Button('保存')
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .id('renameOk')
          .onClick((): void => {
            const n: string = this.fileName;
            this.controller?.close();
            this.onOk(n);
          });
      }.justifyContent(FlexAlign.End).width('100%');
    }.padding(20).width('90%');
  }
}

/**
 * 深色顶栏上的白图标按钮。安卓实测（API 30 / density 2.75）：
 * actionBar 高 56dp，每个菜单项 48×48dp、图标 24dp 居中；
 * 禁用时 alpha = disabledAlpha = 0.5。
 */
@Builder
function BarIcon(icon: Resource, enabled: boolean, id: string, onTap: () => void) {
  Column() {
    Image(icon).width(24).height(24);
  }
  .width(48)
  .height(48)
  .justifyContent(FlexAlign.Center)
  .opacity(enabled ? 1 : 0.5)
  .enabled(enabled)
  .id(id)
  .onClick(onTap);
}

/**
 * 中间省略。安卓标题用自定义 TextView + TruncateAt.MIDDLE，ArkUI 只有尾部省略，
 * 这里按实际宽度用 MeasureText 逐字收缩，复刻“首尾都保留、中间打点”的效果。
 */
function fitMiddle(text: string, availVp: number, fontSize: number): string {
  if (availVp <= 8 || text.length < 5) {
    return text;
  }
  try {
    const maxPx: number = vp2px(availVp);
    const measure: (s: string) => number = (s: string): number =>
      MeasureText.measureText({ textContent: s, fontSize: fontSize });
    if (measure(text) <= maxPx) {
      return text;
    }
    let keep: number = text.length - 1;
    while (keep > 1) {
      const left: number = Math.ceil(keep / 2);
      const cand: string = text.substring(0, left) + '…' +
        text.substring(text.length - (keep - left));
      if (measure(cand) <= maxPx) {
        return cand;
      }
      keep--;
    }
    return '…';
  } catch (e) {
    return text;
  }
}

/** 浅色弹出菜单/子菜单的文本色（安卓 primary_text_material_light / disabled 版）。 */
const MENU_TEXT: string = '#DE000000';
const MENU_TEXT_DISABLED: string = '#42000000';

/** 浅色界面上的深色图标按钮（对齐安卓 borderless ImageButton，40dp；传 6 得 36dp）。 */
@Builder
function ToolIcon(icon: Resource, margin: number, id: string, onTap: () => void) {
  Image(icon)
    .width(24)
    .height(24)
    .margin(margin)
    .id(id)
    .onClick(onTap);
}

@Entry
@Component
struct Index {
  @State content: string = '';
  @State mode: EditorMode = 'scratch';
  @State fileKey: string = '';
  @State fileName: string = '未命名';
  @State encoding: string = UTF_8;
  @State readOnly: boolean = false;
  @State banner: string = '';
  @State dirty: boolean = false;
  @State findOpen: boolean = false;
  @State query: string = '';
  @State replacement: string = '';
  @State matchInfo: string = '';
  @State caseSens: boolean = false;
  @State useRegex: boolean = false;
  @State wholeWord: boolean = false;
  @State fontSize: number = 16;
  @State showNumbers: boolean = true;
  @State wordWrap: boolean = true;
  @State caretLine: number = 0;
  @State loading: boolean = false;
  @State loadingText: string = '';
  @State viewerCapped: boolean = false;
  @State viewerLines: string[] = [];
  @State overflowOpen: boolean = false;
  @State overflowSubmenu: boolean = false;
  @State titleWidth: number = 0;

  private prefs: Prefs | null = null;
  private files: FileService | null = null;
  private codecs: TextCodecs | null = null;
  private ctl: TextAreaController = new TextAreaController();
  private viewerScroller: Scroller = new Scroller();
  private matches: number[] = [];
  private matchIndex: number = -1;
  private matchQuery: string = '\u0000';
  private matchCase: boolean = false;
  private matchRegex: boolean = false;
  private matchWord: boolean = false;
  private findTimer: number = -1;
  private autoTimer: number = -1;
  private lastSaveAt: number = 0;
  private lastKnownMtime: number = 0;
  private conflictNotified: boolean = false;
  private pendingAfterSave: (() => void) | null = null;
  private pendingShareText: string | null = null;
  private pendingShareUri: string | null = null;
  private pendingSaveName: string = '';
  /** 行首偏移缓存：内容变化时置空，读取时重建（对应安卓 buildLineStarts）。 */
  private lineStartsCache: number[] | null = null;
  /** Ability 上下文：注册/注销运行中分享事件、返回退出时用。 */
  private abilityCtx: common.UIAbilityContext | null = null;
  /** 只读预览的数据源（带命中行标记，见 LineDataSource）。 */
  private viewerSource: LineDataSource = new LineDataSource([]);

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.abilityCtx = ctx;
    this.prefs = new Prefs(ctx);
    this.files = new FileService(ctx);
    this.codecs = new UtilTextCodecs();
    this.applySettings();
    // 应用运行中再次收到分享（onNewWant）时，EntryAbility 经 eventHub 通知这里
    try {
      ctx.eventHub.on('paperShareArrived', (): void => {
        this.consumeShareNow();
      });
    } catch (e) {
      // ignore
    }
    this.consumeShare();
    if (!this.takePendingShare()) {
      this.routeStartup();
    }
    this.autoTimer = setInterval((): void => {
      this.maybeAutosave();
    }, 1000);
  }

  aboutToDisappear(): void {
    this.recordCaretLine();
    const ctx: common.UIAbilityContext | null = this.abilityCtx;
    if (ctx !== null) {
      try {
        ctx.eventHub.off('paperShareArrived');
      } catch (e) {
        // ignore
      }
    }
    if (this.autoTimer >= 0) {
      clearInterval(this.autoTimer);
      this.autoTimer = -1;
    }
    if (this.findTimer >= 0) {
      clearTimeout(this.findTimer);
      this.findTimer = -1;
    }
  }

  onPageShow(): void {
    this.applySettings();
    // 取浏览器的返回结果（打开文件 / 新建 / 选择目录）
    try {
      const openPath: string = AppStorage.get<string>('paperOpenPath') ?? '';
      if (openPath !== '') {
        AppStorage.setOrCreate('paperOpenPath', '');
        if (openPath.indexOf('://') >= 0) {
          // 系统选择器给的是 URI（file://docs/… 等），走 URI 打开与覆盖写
          this.openUri(openPath);
        } else {
          this.openPath(openPath, -1);
        }
        return;
      }
      const newFile: boolean = AppStorage.get<boolean>('paperNewFile') ?? false;
      if (newFile) {
        AppStorage.setOrCreate('paperNewFile', false);
        this.resetToScratch(null);
        return;
      }
      const pickDir: string = AppStorage.get<string>('paperPickDir') ?? '';
      if (pickDir !== '') {
        AppStorage.setOrCreate('paperPickDir', '');
        this.prefs?.recordDirectory(pickDir);
        this.openSaveDialog(pickDir, this.pendingSaveName, this.pendingAfterSave);
        this.pendingAfterSave = null;
      }
    } catch (e) {
      // ignore
    }
  }

  /** 页面隐藏（进浏览器/设置或退到后台）时记住光标行（对应安卓 onStop）。 */
  onPageHide(): void {
    this.recordCaretLine();
  }

  /**
   * 系统返回键：先关查找栏，再有未保存修改则确认，否则交回系统退出
   * （对应安卓 onBackPressed 的 findBar → dirty 判定顺序）。
   */
  onBackPress(): boolean {
    hilog.info(DOMAIN, TAG, 'onBackPress findOpen=%{public}s dirty=%{public}s',
      String(this.findOpen), String(this.dirty));
    if (this.findOpen) {
      this.findOpen = false;
      this.clearMatches();
      return true;
    }
    if (this.dirty) {
      this.confirmDiscardThen((): void => {
        this.recordCaretLine();
        const ctx: common.UIAbilityContext | null = this.abilityCtx;
        if (ctx !== null) {
          ctx.terminateSelf();
        }
      });
      return true;
    }
    this.recordCaretLine();
    return false;
  }

  // ---- 设置应用 ----

  private applySettings(): void {
    const p: Prefs | null = this.prefs;
    if (p === null) {
      return;
    }
    // 样式变更绝不能误标 dirty（content 本体不动，只改 @State 外观量）
    this.fontSize = p.fontSizeSp();
    this.showNumbers = p.showLineNumbers();
    this.wordWrap = p.wordWrap();
  }

  // ---- 启动与分享 ----

  private async routeStartup(): Promise<void> {
    const p: Prefs | null = this.prefs;
    const f: FileService | null = this.files;
    if (p === null || f === null) {
      this.resetToScratch(null);
      return;
    }
    const lastFile: string = p.lastFilePath();
    const lastDir: string = p.lastDirectory();
    const lastIsScratch: boolean = p.lastIsScratch();
    const fileOk: boolean =
      !lastIsScratch && lastFile !== '' && (await f.isFile(lastFile));
    const dirOk: boolean = lastDir !== '' && (await f.isDirectory(lastDir));
    const target: string = decide(
      p.startupMode(), lastFile, lastIsScratch, lastDir,
      (): boolean => fileOk,
      (): boolean => dirOk
    );
    if (target === 'openFile') {
      const line: number = p.rememberLastLine() ? p.lineFor(lastFile) : -1;
      if (lastFile.indexOf('://') >= 0) {
        this.openUri(lastFile);
      } else {
        this.openPath(lastFile, line);
      }
    } else if (target === 'browser') {
      AppStorage.setOrCreate('paperBrowserStart', lastDir);
      AppStorage.setOrCreate('paperBrowserMode', 'open');
      router.pushUrl({ url: 'pages/Browser' });
    } else {
      this.resetToScratch(null);
    }
  }

  /** 解析 EntryAbility 暂存的分享 Want（多键兼容，解析不到就忽略）。 */
  private consumeShare(): void {
    try {
      const has: boolean = AppStorage.get<boolean>('paperHasShare') ?? false;
      if (!has) {
        return;
      }
      AppStorage.setOrCreate('paperHasShare', false);
      const raw: string = AppStorage.get<string>('paperShareParams') ?? '{}';
      AppStorage.setOrCreate('paperShareParams', '{}');
      // viewData 的目标文件在 want.uri（EntryAbility 单独转存），优先于参数扫描
      const directUri: string = AppStorage.get<string>('paperShareUri') ?? '';
      AppStorage.setOrCreate('paperShareUri', '');
      if (directUri !== '') {
        this.pendingShareUri = directUri;
        return;
      }
      const params = JSON.parse(raw) as Record<string, string | string[]>;
      const texts: string[] = [];
      const uris: string[] = [];
      for (const key of Object.keys(params)) {
        const v: string | string[] = params[key];
        if (typeof v === 'string') {
          if (v.indexOf('://') >= 0) {
            uris.push(v);
          } else {
            texts.push(v);
          }
        } else if (Array.isArray(v)) {
          for (const item of v) {
            if (item.indexOf('://') >= 0) {
              uris.push(item);
            } else {
              texts.push(item);
            }
          }
        }
      }
      if (uris.length > 0) {
        this.pendingShareUri = uris[0];
      } else if (texts.length > 0) {
        this.pendingShareText = texts.join('\n');
      }
    } catch (e) {
      // 解析失败按无分享处理
    }
  }

  /** 打开并清空暂存的分享内容；无分享内容时返回 false。 */
  private takePendingShare(): boolean {
    const uri: string | null = this.pendingShareUri;
    const text: string | null = this.pendingShareText;
    if (uri === null && text === null) {
      return false;
    }
    this.pendingShareUri = null;
    this.pendingShareText = null;
    if (uri !== null) {
      this.openUri(uri);
    } else {
      this.resetToScratch(text);
      this.toast('已粘贴分享的文本（未保存）');
    }
    return true;
  }

  /** 运行中收到的新分享：有未保存修改先确认，再消费（对应安卓 handleShareIntent）。 */
  private consumeShareNow(): void {
    this.consumeShare();
    if (this.pendingShareUri === null && this.pendingShareText === null) {
      return;
    }
    const next: () => void = (): void => {
      this.takePendingShare();
    };
    if (this.dirty) {
      this.confirmDiscardThen(next);
      return;
    }
    next();
  }

  private resetToScratch(initialText: string | null): void {
    this.mode = 'scratch';
    this.fileKey = '';
    this.fileName = '未命名';
    this.encoding = UTF_8;
    this.readOnly = false;
    this.banner = '';
    this.dirty = false;
    this.lastKnownMtime = 0;
    this.conflictNotified = false;
    this.pendingAfterSave = null;
    this.viewerLines = [];
    this.viewerSource = new LineDataSource(this.viewerLines);
    this.viewerCapped = false;
    this.content = initialText === null ? '' : initialText;
    this.invalidateLines();
    this.caretLine = 0;
    this.clearMatches();
    try {
      this.ctl.caretPosition(this.content.length);
    } catch (e) {
      // ignore
    }
  }

  // ---- 打开 ----

  private async openPath(path: string, restoreLine: number): Promise<void> {
    const f: FileService | null = this.files;
    const p: Prefs | null = this.prefs;
    const codecs: TextCodecs | null = this.codecs;
    if (f === null || p === null || codecs === null || path === '') {
      return;
    }
    if (path.startsWith('file:///')) {
      // file:///sdcard/x 这类本地 URI 才是真路径；file://docs/… 是选择器 URI，原样交给 fs
      path = path.substring(7);
    }
    const st = await f.statInfo(path);
    if (st === null || !st.isFile) {
      this.toast('打开失败：文件不存在');
      const lastDir: string = p.lastDirectory();
      if (await f.isDirectory(lastDir)) {
        AppStorage.setOrCreate('paperBrowserStart', lastDir);
        AppStorage.setOrCreate('paperBrowserMode', 'open');
        router.pushUrl({ url: 'pages/Browser' });
      } else {
        this.resetToScratch(null);
      }
      return;
    }
    this.showLoading('正在加载…');
    try {
      const head: Uint8Array = await f.readRange(path, 0, 8192);
      const binary: boolean = looksBinary(head);
      const tier = tierFor(st.size, binary);
      const limit: number = readLimit(tier, st.size);
      const data: Uint8Array = limit >= st.size
        ? await f.readBytes(path, limit)
        : await f.readRange(path, 0, limit);
      const truncated: boolean = data.length < st.size;
      const charset: string = resolveCharset(p.defaultEncoding(), data, codecs);
      const text: string = stripBom(codecs.decode(data, charset), charset);
      this.applyLoadedText(text, path, null, charset, tier, binary, truncated);
      if (restoreLine > 0 && tier === 'editable' && !binary) {
        const starts: number[] = buildLineStarts(text);
        if (restoreLine < starts.length) {
          const off: number = Math.min(starts[restoreLine], text.length);
          this.caretLine = restoreLine;
          setTimeout((): void => {
            try {
              this.ctl.caretPosition(off);
            } catch (e) {
              // ignore
            }
          }, 50);
        }
      }
      this.lastKnownMtime = st.mtimeMs;
      this.conflictNotified = false;
      p.recordOpened(path, false);
    } catch (e) {
      this.toast('打开失败：' + String(e));
    } finally {
      this.hideLoading();
    }
  }

  private async openUri(uri: string): Promise<void> {
    const f: FileService | null = this.files;
    const p: Prefs | null = this.prefs;
    const codecs: TextCodecs | null = this.codecs;
    if (f === null || p === null || codecs === null) {
      return;
    }
    this.showLoading('正在加载…');
    try {
      const st = await f.statInfo(uri);
      const size: number = st !== null ? st.size : 0;
      const headOnly: boolean = size <= 0 || size > FULL_VIEW_LIMIT;
      const data: Uint8Array = headOnly
        ? await f.readRange(uri, 0, HEAD_LIMIT)
        : await f.readBytes(uri, FULL_VIEW_LIMIT);
      const binary: boolean = looksBinary(data);
      const truncated: boolean = size > 0 && data.length < size;
      const tier = tierFor(size > 0 ? size : data.length, binary);
      const charset: string = resolveCharset(p.defaultEncoding(), data, codecs);
      const text: string = stripBom(codecs.decode(data, charset), charset);
      this.applyLoadedText(text, null, uri, charset, tier, binary, truncated);
      await f.persistPermission(uri);
      if (allowsSave(tier) && !binary) {
        this.toast('分享的内容：保存时需另存为真实文件');
      }
    } catch (e) {
      this.toast('打开失败：' + String(e));
    } finally {
      this.hideLoading();
    }
  }

  private applyLoadedText(
    text: string,
    path: string | null,
    uri: string | null,
    charset: string,
    tier: 'editable' | 'readonly' | 'head',
    binary: boolean,
    truncated: boolean
  ): void {
    this.encoding = charset;
    this.readOnly = !allowsSave(tier) || binary;
    this.dirty = false;
    if (path !== null) {
      this.mode = 'file';
      this.fileKey = path;
      this.fileName = baseName(path);
    } else if (uri !== null) {
      this.mode = 'uri';
      this.fileKey = uri;
      this.fileName = baseName(uri);
    } else {
      this.mode = 'scratch';
      this.fileKey = '';
      this.fileName = '未命名';
    }
    if (allowsSave(tier) && !binary) {
      this.content = text;
      this.invalidateLines();
      this.viewerLines = [];
      this.viewerSource = new LineDataSource(this.viewerLines);
      this.caretLine = 0;
      setTimeout((): void => {
        try {
          this.ctl.caretPosition(0);
        } catch (e) {
          // ignore
        }
      }, 50);
    } else {
      this.viewerLines = splitCapped(text);
      this.viewerSource = new LineDataSource(this.viewerLines);
      this.viewerCapped = this.viewerLines.length >= VIEWER_LINE_CAP;
      this.content = text;
      this.invalidateLines();
      this.caretLine = 0;
    }
    let bannerText: string | null = readOnlyReason(tier, binary);
    if (bannerText === null && truncated) {
      bannerText = '文件过大：仅显示部分内容，保存已禁用';
    }
    if (bannerText === null && this.readOnly) {
      bannerText = '只读模式：此位置无法写入，保存已禁用';
    }
    this.banner = bannerText === null ? '' : bannerText;
    this.clearMatches();
  }

  // ---- 保存 ----

  private async actionSave(): Promise<void> {
    const after: (() => void) | null = this.pendingAfterSave;
    this.pendingAfterSave = null;
    if (this.mode === 'file' && !this.readOnly && this.fileKey !== '') {
      const f: FileService | null = this.files;
      if (f !== null) {
        const st = await f.statInfo(this.fileKey);
        if (st !== null && this.lastKnownMtime > 0 && st.mtimeMs !== this.lastKnownMtime) {
          const target: string = this.fileKey;
          const next: (() => void) | null = after;
          AlertDialog.show({
            title: '关闭文件',
            message: '这个文件已被其他程序修改。仍要覆盖吗？',
            autoCancel: false,
            alignment: DialogAlignment.Center,
            primaryButton: {
              value: '保存',
              action: (): void => {
                this.writeToPath(target, true, next);
              }
            },
            secondaryButton: {
              value: '取消',
              action: (): void => {}
            }
          });
          return;
        }
        this.writeToPath(this.fileKey, true, after);
      }
    } else if ((this.mode === 'uri' || this.mode === 'scratch') && !this.readOnly) {
      const p: Prefs | null = this.prefs;
      this.openSaveDialog(p !== null ? p.lastDirectory() : '', defaultFileName(Date.now()), after);
    } else {
      this.toast('只读模式，无法保存');
    }
  }

  private actionSaveAs(): void {
    if (this.readOnly) {
      this.toast('只读模式，无法另存为');
      return;
    }
    const p: Prefs | null = this.prefs;
    const name: string =
      this.mode === 'file' && this.fileKey !== ''
        ? baseName(this.fileKey)
        : defaultFileName(Date.now());
    this.openSaveDialog(p !== null ? p.lastDirectory() : '', name, null);
  }

  private actionClose(): void {
    this.confirmDiscardThen((): void => {
      this.recordCaretLine();
      this.prefs?.recordOpened('', true);
      this.resetToScratch(null);
      const p: Prefs | null = this.prefs;
      AppStorage.setOrCreate('paperBrowserStart', p !== null ? p.lastDirectory() : '');
      AppStorage.setOrCreate('paperBrowserMode', 'open');
      router.pushUrl({ url: 'pages/Browser' });
    });
  }

  private confirmDiscardThen(next: () => void): void {
    if (!this.dirty) {
      next();
      return;
    }
    AlertDialog.show({
      title: '关闭文件',
      message: '当前文件有未保存的修改',
      autoCancel: false,
      alignment: DialogAlignment.Center,
      buttons: [
        {
          value: '保存并关闭',
          action: (): void => {
            this.pendingAfterSave = next;
            this.actionSave();
          }
        },
        {
          value: '不保存',
          action: (): void => {
            next();
          }
        },
        {
          value: '取消',
          action: (): void => {}
        }
      ]
    });
  }

  private actionRename(): void {
    if (this.mode !== 'file' || this.fileKey === '') {
      this.toast('只有已保存的文件可以重命名');
      return;
    }
    if (this.readOnly) {
      this.toast('只读模式，无法重命名');
      return;
    }
    if (this.fileKey.startsWith('file://') || this.fileKey.indexOf('://') >= 0) {
      this.toast('该位置不支持重命名，请用另存为');
      return;
    }
    const src: string = this.fileKey;
    const dlg: CustomDialogController = new CustomDialogController({
      builder: RenameDialogContent({
        fileName: baseName(src),
        onOk: (name: string): void => {
          this.doRename(src, name);
        }
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center
    });
    dlg.open();
  }

  private async doRename(src: string, rawName: string): Promise<void> {
    let name: string = sanitize(rawName);
    if (name === '') {
      this.toast('请输入文件名');
      return;
    }
    if (name.lastIndexOf('.') <= 0) {
      name = ensureTxtExtension(name);
    }
    const dir: string = parentOf(src);
    const dst: string = (dir === '' ? '' : dir + '/') + name;
    if (dst === src) {
      return;
    }
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    if (await f.isFile(dst)) {
      this.toast('同名文件已存在');
      return;
    }
    try {
      await f.renameFile(src, dst);
      this.fileKey = dst;
      this.fileName = name;
      const st = await f.statInfo(dst);
      this.lastKnownMtime = st !== null ? st.mtimeMs : 0;
      this.prefs?.recordOpened(dst, false);
    } catch (e) {
      this.toast('重命名失败：' + name);
    }
  }

  private openSaveDialog(dir: string, name: string, after: (() => void) | null): void {
    this.pendingSaveName = name;
    this.pendingAfterSave = after;
    if (dir === '') {
      // “新建必须选目录”：无历史目录时先强制进浏览器选目录
      this.toast('请先选择一个目录');
      AppStorage.setOrCreate('paperBrowserStart', '');
      AppStorage.setOrCreate('paperBrowserMode', 'pickDir');
      router.pushUrl({ url: 'pages/Browser' });
      return;
    }
    this.renderSaveDialog(dir, name);
  }

  private renderSaveDialog(dir: string, name: string): void {
    const after: (() => void) | null = this.pendingAfterSave;
    this.pendingAfterSave = null;
    const dlg: CustomDialogController = new CustomDialogController({
      builder: SaveDialogContent({
        fileName: name,
        dirPath: dir,
        onBrowse: (current: string): void => {
          this.pendingSaveName = current;
          this.pendingAfterSave = after;
          AppStorage.setOrCreate('paperBrowserStart', dir);
          AppStorage.setOrCreate('paperBrowserMode', 'pickDir');
          router.pushUrl({ url: 'pages/Browser' });
        },
        onSystem: (current: string): void => {
          this.saveToArbitraryLocation(current, after);
        },
        onOk: (inputName: string): void => {
          this.commitSave(dir, inputName, after);
        }
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center
    });
    dlg.open();
  }

  private async commitSave(dir: string, rawName: string, after: (() => void) | null): Promise<void> {
    let name: string = sanitize(rawName);
    if (name === '') {
      this.toast('请输入文件名');
      return;
    }
    if (name.lastIndexOf('.') <= 0) {
      name = ensureTxtExtension(name);
    }
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    if (!(await f.canWriteDir(dir))) {
      this.toast('目录不可写，请换一个目录');
      return;
    }
    const target: string = (dir === '' ? '' : dir + '/') + name;
    if (await f.isFile(target)) {
      AlertDialog.show({
        title: '保存文件',
        message: '文件已存在，是否覆盖？',
        autoCancel: false,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '保存',
          action: (): void => {
            this.writeToPath(target, true, after);
          }
        },
        secondaryButton: {
          value: '取消',
          action: (): void => {}
        }
      });
      return;
    }
    this.writeToPath(target, true, after);
  }

  /** 经系统保存面板存到沙箱外任意位置（对应安卓“保存到任意真实路径”）。 */
  private async saveToArbitraryLocation(rawName: string, after: (() => void) | null): Promise<void> {
    let name: string = sanitize(rawName);
    if (name === '') {
      this.toast('请输入文件名');
      return;
    }
    if (name.lastIndexOf('.') <= 0) {
      name = ensureTxtExtension(name);
    }
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    try {
      const uris: string[] = await f.pickSave(name);
      if (uris.length > 0) {
        await f.persistPermission(uris[0]);
        this.writeToPath(uris[0], true, after);
      }
    } catch (e) {
      this.toast('未选择保存位置');
    }
  }

  /** 唯一写盘路径（手动/另存/自动保存都走这里）。 */
  private async writeToPath(target: string, userInitiated: boolean, after: (() => void) | null): Promise<void> {
    const f: FileService | null = this.files;
    const p: Prefs | null = this.prefs;
    const codecs: TextCodecs | null = this.codecs;
    if (f === null || p === null || codecs === null) {
      return;
    }
    // 任何带 scheme 的 URI（选择器给的 file://docs/… 等）走覆盖写；沙箱真路径走原子写+.bak
    const isUri: boolean = target.indexOf('://') >= 0;
    const data: Uint8Array = codecs.encode(this.content, this.encoding);
    if (userInitiated) {
      this.showLoading('正在保存…');
    }
    try {
      if (isUri) {
        await f.writeUri(target, data);
      } else {
        await atomicWrite(f.atomic(), target, data);
      }
      const st = await f.statInfo(target);
      this.mode = 'file';
      this.fileKey = target;
      this.fileName = baseName(target);
      this.dirty = false;
      this.readOnly = false;
      this.banner = '';
      this.lastKnownMtime = st !== null ? st.mtimeMs : Date.now();
      this.conflictNotified = false;
      p.recordOpened(target, false);
      if (userInitiated) {
        this.toast('已保存');
      }
      if (after !== null) {
        after();
      }
    } catch (e) {
      if (userInitiated) {
        this.toast('保存失败：' + String(e));
      }
    } finally {
      if (userInitiated) {
        this.hideLoading();
      }
    }
  }

  private maybeAutosave(): void {
    const p: Prefs | null = this.prefs;
    if (p === null) {
      return;
    }
    const interval: number = p.autosaveIntervalSec();
    if (interval <= 0 || this.readOnly || this.mode !== 'file' || !this.dirty) {
      return;
    }
    const now: number = Date.now();
    if (this.lastSaveAt === 0) {
      this.lastSaveAt = now;
      return;
    }
    if (now - this.lastSaveAt < interval * 1000) {
      return;
    }
    this.lastSaveAt = now;
    const target: string = this.fileKey;
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    f.statInfo(target).then((st): void => {
      if (st !== null && this.lastKnownMtime > 0 && st.mtimeMs !== this.lastKnownMtime) {
        // 绝不静默覆盖外部修改
        if (!this.conflictNotified) {
          this.conflictNotified = true;
          this.toast('文件已被外部修改，已暂停自动保存');
        }
        return;
      }
      this.writeToPath(target, false, null);
    });
  }

  private async restoreBackup(): Promise<void> {
    const key: string = this.fileKey;
    if (this.mode !== 'file' || key === '' || key.indexOf('://') >= 0) {
      this.toast('只有已保存的文件才有备份');
      return;
    }
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    if (!(await backupExists(f.atomic(), key))) {
      this.toast('没有找到备份文件');
      return;
    }
    AlertDialog.show({
      title: '恢复备份',
      message: '用 .bak 备份覆盖当前文件？',
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '保存',
        action: (): void => {
          const fs: FileService | null = this.files;
          if (fs === null) {
            return;
          }
          const target: string = key;
          restoreFromBackup(fs.atomic(), target).then((): void => {
            this.openPath(target, -1);
          }).catch((e: BusinessError): void => {
            this.toast('保存失败：' + String(e));
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {}
      }
    });
  }

  // ---- 查找替换 ----

  private currentText(): string {
    return this.content;
  }

  /** 开关查找栏；打开时聚焦查找框并立即重跑（对应安卓 toggleFindBar）。 */
  private toggleFindBar(): void {
    const show: boolean = !this.findOpen;
    this.findOpen = show;
    if (show) {
      if (this.query !== '') {
        this.runFindNow();
      }
      setTimeout((): void => {
        try {
          this.getUIContext().getFocusController().requestFocus('findInput');
        } catch (e) {
          // ignore
        }
      }, 50);
    } else {
      this.clearMatches();
    }
  }

  private scheduleFind(): void {
    if (this.findTimer >= 0) {
      clearTimeout(this.findTimer);
    }
    this.findTimer = setTimeout((): void => {
      this.findTimer = -1;
      this.runFindNow();
    }, FIND_DEBOUNCE_MS);
  }

  private runFindNow(): void {
    if (!this.findOpen) {
      return;
    }
    const q: string = this.query;
    if (q === '') {
      this.clearMatches();
      return;
    }
    const text: string = this.currentText();
    const cs: boolean = this.caseSens;
    const rx: boolean = this.useRegex;
    const ww: boolean = this.wholeWord;
    // 可编辑文本 ≤5MB，同步扫描即可（安卓版走线程池；此处量级下亚秒完成，
    // 且防抖保证输入期不频繁触发）。
    const result: number[] = findAll(text, q, cs, rx, ww);
    this.matches = result;
    this.matchQuery = q;
    this.matchCase = cs;
    this.matchRegex = rx;
    this.matchWord = ww;
    this.matchIndex = result.length > 0 ? 0 : -1;
    this.matchInfo = (result.length > 0 ? 1 : 0) + '/' + result.length / 2;
    this.refreshViewerMarks();
    if (this.matchIndex >= 0) {
      this.gotoMatch(0);
    }
  }

  private refreshMatchesIfStale(): void {
    const q: string = this.query;
    if (q === this.matchQuery && this.caseSens === this.matchCase &&
      this.useRegex === this.matchRegex && this.wholeWord === this.matchWord) {
      return;
    }
    this.matches = findAll(this.content, q, this.caseSens, this.useRegex, this.wholeWord);
    this.matchQuery = q;
    this.matchCase = this.caseSens;
    this.matchRegex = this.useRegex;
    this.matchWord = this.wholeWord;
    this.matchIndex = this.matches.length > 0 ? 0 : -1;
  }

  private clearMatches(): void {
    this.matches = [];
    this.matchIndex = -1;
    this.matchQuery = '\u0000';
    this.matchInfo = '';
    this.refreshViewerMarks();
  }

  /**
   * 只读预览的命中标记：命中所在行标黄、当前命中行标绿。
   * 安卓版在 VirtualTextView 里画字符区间底色；ArkUI 的 Text 不支持区间背景，
   * 这里按“整行底色”近似（同样只标前 2000 处，与安卓上限一致）。
   */
  private refreshViewerMarks(): void {
    if (!this.readOnly) {
      return;
    }
    const marks: Map<number, number> = new Map<number, number>();
    const total: number = this.matches.length / 2;
    const cap: number = Math.min(total, 2000);
    for (let i: number = 0; i < cap; i++) {
      const line: number = lineOf(this.cachedLineStarts(), this.matches[i * 2]);
      const kind: number = i === this.matchIndex ? 2 : 1;
      const existing: number = marks.get(line) ?? 0;
      if (kind === 2 || existing === 0) {
        marks.set(line, kind);
      }
    }
    this.viewerSource.setMarks(marks);
  }

  private gotoMatch(index: number): void {
    if (this.matches.length === 0) {
      return;
    }
    const total: number = this.matches.length / 2;
    this.matchIndex = ((index % total) + total) % total;
    this.matchInfo = this.matchIndex + 1 + '/' + total;
    const start: number = this.matches[this.matchIndex * 2];
    const end: number = this.matches[this.matchIndex * 2 + 1];
    this.caretLine = lineOf(this.cachedLineStarts(), start);
    if (this.readOnly) {
      // 只读预览：滚到命中所在行（当前命中行标绿，见 refreshViewerMarks）
      this.viewerScroller.scrollToIndex(Math.min(this.caretLine, this.viewerLines.length - 1));
      this.refreshViewerMarks();
      return;
    }
    // 选中当前命中（对应安卓 setSelection(end, start)）
    try {
      this.ctl.setTextSelection(start, end);
    } catch (e) {
      // ignore
    }
  }

  private replaceCurrent(): void {
    if (this.readOnly) {
      this.toast('只读模式，无法替换');
      return;
    }
    this.refreshMatchesIfStale();
    if (this.matchIndex < 0 || this.matchIndex * 2 + 1 >= this.matches.length) {
      return;
    }
    const start: number = this.matches[this.matchIndex * 2];
    const end: number = this.matches[this.matchIndex * 2 + 1];
    const newText: string = this.matchRegex
      ? replaceCurrentRegex(this.content, this.query, start, end, this.replacement,
        this.matchCase, this.matchWord)
      : replaceRange(this.content, start, end, this.replacement);
    const caret: number = Math.min(start + this.replacement.length, newText.length);
    this.content = newText;
    this.invalidateLines();
    this.markDirty();
    try {
      this.ctl.caretPosition(caret);
    } catch (e) {
      // ignore
    }
    this.runFindNow();
  }

  private replaceAll(): void {
    if (this.readOnly) {
      this.toast('只读模式，无法替换');
      return;
    }
    if (this.query === '') {
      return;
    }
    this.refreshMatchesIfStale();
    const total: number = this.matches.length / 2;
    const newText: string = this.matchRegex
      ? replaceAllRegex(this.content, this.query, this.replacement, this.matchCase, this.matchWord)
      : replaceAllLiteral(this.content, this.matches, this.replacement);
    if (newText === this.content) {
      return;
    }
    this.content = newText;
    this.invalidateLines();
    this.markDirty();
    try {
      this.ctl.caretPosition(0);
    } catch (e) {
      // ignore
    }
    this.toast('已替换 ' + total + ' 处');
    this.runFindNow();
  }

  // ---- 编码 ----

  private async onEncodingChosen(chosen: string): Promise<void> {
    const codecs: TextCodecs | null = this.codecs;
    const f: FileService | null = this.files;
    if (codecs === null) {
      return;
    }
    if (this.mode === 'scratch') {
      this.encoding = isAuto(chosen) ? UTF_8 : chosen;
      return;
    }
    if (this.dirty) {
      // 有未保存修改：重释内存文本，绝不丢用户输入（与安卓版同）
      const raw: Uint8Array = codecs.encode(this.currentText(), this.encoding);
      const charset: string = isAuto(chosen)
        ? (await importCharsetOf(raw, codecs))
        : chosen;
      this.content = stripBom(codecs.decode(raw, charset), charset);
      this.invalidateLines();
      this.encoding = charset;
      this.clearMatches();
      return;
    }
    this.showLoading('重新解码…');
    try {
      let data: Uint8Array = new Uint8Array(0);
      if (this.mode === 'file' && this.fileKey !== '' && f !== null) {
        const st = await f.statInfo(this.fileKey);
        const size: number = st !== null ? st.size : 0;
        const tier = tierFor(size, false);
        const limit: number = readLimit(tier, size);
        data = size <= limit
          ? await f.readBytes(this.fileKey, limit)
          : await f.readRange(this.fileKey, 0, limit);
      }
      const charset: string = isAuto(chosen)
        ? (await importCharsetOf(data, codecs))
        : chosen;
      this.content = stripBom(codecs.decode(data, charset), charset);
      this.invalidateLines();
      this.encoding = charset;
      this.viewerLines = this.readOnly ? splitCapped(this.content) : [];
      this.viewerSource = new LineDataSource(this.viewerLines);
      this.clearMatches();
    } catch (e) {
      this.toast('打开失败：' + String(e));
    } finally {
      this.hideLoading();
    }
  }

  // ---- 行号/杂项 ----

  private lineCount(): number {
    return this.cachedLineStarts().length - 1;
  }

  /** 行首偏移表（内容变化后重建，见 invalidateLines）。 */
  private cachedLineStarts(): number[] {
    if (this.lineStartsCache === null) {
      this.lineStartsCache = buildLineStarts(this.content);
    }
    return this.lineStartsCache;
  }

  /** content 每次变化都要调用，否则行号/光标行会读到旧表。 */
  private invalidateLines(): void {
    this.lineStartsCache = null;
  }

  private markDirty(): void {
    if (!this.dirty) {
      this.dirty = true;
      this.lastSaveAt = Date.now();
    }
  }

  private recordCaretLine(): void {
    if (this.mode !== 'file' || this.fileKey === '' || this.readOnly) {
      return;
    }
    const p: Prefs | null = this.prefs;
    if (p !== null && p.rememberLastLine()) {
      p.recordLine(this.fileKey, this.caretLine);
    }
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
      // ignore
    }
  }

  private showLoading(text: string): void {
    this.loadingText = text;
    this.loading = true;
  }

  private hideLoading(): void {
    this.loading = false;
  }

  /** 预览行底色：当前命中行 > 命中行 > 当前行。 */
  private rowBackground(index: number): ResourceColor {
    const kind: number = this.viewerSource.markKind(index);
    if (kind === 2) {
      return $r('app.color.find_current');
    }
    if (kind === 1) {
      return $r('app.color.find_highlight');
    }
    if (this.caretLine === index) {
      return $r('app.color.current_line');
    }
    return '#00000000';
  }

  /** 新建（脏时先确认，对应安卓 action_new）。 */
  private confirmNewFile(): void {
    if (this.dirty) {
      this.confirmDiscardThen((): void => {
        this.resetToScratch(null);
      });
    } else {
      this.resetToScratch(null);
    }
  }

  /** 打开（脏时先确认，对应安卓 action_open）。 */
  private openBrowserPage(): void {
    const openBrowser: () => void = (): void => {
      const p: Prefs | null = this.prefs;
      AppStorage.setOrCreate('paperBrowserStart', p !== null ? p.lastDirectory() : '');
      AppStorage.setOrCreate('paperBrowserMode', 'open');
      router.pushUrl({ url: 'pages/Browser' });
    };
    if (this.dirty) {
      this.confirmDiscardThen(openBrowser);
    } else {
      openBrowser();
    }
  }

  /**
   * 溢出菜单（⋮）。安卓实测：弹出层宽 196dp、无内边距，每项 48dp 高、16sp、
   * 文字左缩 16dp，**菜单项不显示图标**（actionBar 只在图标区显示图标）；
   * “编码”项带右向三角，展开为 226dp 宽的子菜单（顶部“编码 · X”标题行 +
   * 7 个 48dp 单选行，勾选框贴右 16dp）——子菜单在同一个弹出层内切换，
   * 与安卓 SubMenu 的收纳关系一致。
   */
  @Builder
  overflowPopup() {
    Column({ space: 0 }) {
      if (this.overflowSubmenu) {
        Row() {
          Text('编码 · ' + this.encoding)
            .fontSize(16)
            .fontColor(MENU_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 });
        ForEach(USER_CHOICES, (c: string) => {
          Row() {
            Text(labelOf(c))
              .fontSize(16)
              .fontColor(MENU_TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Checkbox()
              .select(this.encodingChoiceSelected(c))
              .selectedColor($r('app.color.brand'))
              .width(24)
              .height(24)
              .hitTestBehavior(HitTestMode.None);
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .onClick((): void => {
            this.overflowOpen = false;
            this.overflowSubmenu = false;
            this.onEncodingChosen(c);
          });
        }, (c: string): string => c);
      } else {
        Row() {
          Text('新建').fontSize(16).fontColor(MENU_TEXT).maxLines(1).layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuNew')
        .onClick((): void => {
          this.overflowOpen = false;
          this.confirmNewFile();
        });
        Row() {
          Text('打开').fontSize(16).fontColor(MENU_TEXT).maxLines(1).layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuOpen')
        .onClick((): void => {
          this.overflowOpen = false;
          this.openBrowserPage();
        });
        Row() {
          Text('重命名')
            .fontSize(16)
            .fontColor(this.mode === 'file' && !this.readOnly ? MENU_TEXT : MENU_TEXT_DISABLED)
            .maxLines(1)
            .layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuRename')
        .onClick((): void => {
          if (this.mode === 'file' && !this.readOnly) {
            this.overflowOpen = false;
            this.actionRename();
          }
        });
        Row() {
          Text('另存为')
            .fontSize(16)
            .fontColor(this.readOnly ? MENU_TEXT_DISABLED : MENU_TEXT)
            .maxLines(1)
            .layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuSaveAs')
        .onClick((): void => {
          if (!this.readOnly) {
            this.overflowOpen = false;
            this.actionSaveAs();
          }
        });
        Row() {
          Text('编码 · ' + this.encoding)
            .fontSize(16)
            .fontColor(MENU_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          Image($r('app.media.ic_submenu_arrow')).width(24).height(24);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuEncoding')
        .onClick((): void => {
          this.overflowSubmenu = true;
        });
        Row() {
          Text('恢复备份')
            .fontSize(16)
            .fontColor(this.mode === 'file' ? MENU_TEXT : MENU_TEXT_DISABLED)
            .maxLines(1)
            .layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuRestore')
        .onClick((): void => {
          if (this.mode === 'file') {
            this.overflowOpen = false;
            this.restoreBackup();
          }
        });
        Row() {
          Text('设置').fontSize(16).fontColor(MENU_TEXT).maxLines(1).layoutWeight(1);
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .id('menuSettings')
        .onClick((): void => {
          this.overflowOpen = false;
          router.pushUrl({ url: 'pages/Settings' });
        });
      }
    }
    .width(this.overflowSubmenu ? 226 : 196)
    .backgroundColor('#FFFAFAFA');
  }

  /** 顶栏标题（安卓：文件名 + 未保存时的 “ •”），超宽时中间省略。 */
  private titleLabel(): string {
    const name: string = this.dirty ? this.fileName + ' •' : this.fileName;
    return fitMiddle(name, this.titleWidth > 12 ? this.titleWidth - 12 : 0, 18);
  }

  /** 编码子菜单的勾选状态（与安卓 onPrepareOptionsMenu 的判定表达式一致）。 */
  private encodingChoiceSelected(c: string): boolean {
    if (c === this.encoding) {
      return true;
    }
    const p: Prefs | null = this.prefs;
    return isAuto(c) && p !== null && isAuto(p.defaultEncoding());
  }

  // ---- 界面 ----

  build() {
    Stack() {
      Column({ space: 0 }) {
        // 顶栏（对齐安卓 DarkActionBar：深底 #212121 + 白字标题 + 白图标；
        // 右侧常驻 关闭/保存/查找 + ⋮（各 48×48dp，溢出钮 40×48dp），
        // 其余收纳进溢出菜单，分组顺序与 menu/main.xml 一致）
        Row({ space: 0 }) {
          Text(this.titleLabel())
            .fontSize(18)
            .fontColor($r('app.color.white'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 6, right: 6 })
            .margin({ left: 16 })
            .layoutWeight(1)
            .id('actionTitle')
            .onAreaChange((oldArea: Area, newArea: Area): void => {
              const w: number = Number(newArea.width);
              if (Math.abs(w - this.titleWidth) > 0.5) {
                this.titleWidth = w;
              }
            })
            .onClick((): void => {
              this.actionRename();
            });
          BarIcon($r('app.media.ic_close_w'), true, 'actionClose', (): void => {
            this.actionClose();
          });
          BarIcon($r('app.media.ic_save_w'), !this.readOnly, 'actionSave', (): void => {
            this.actionSave();
          });
          BarIcon($r('app.media.ic_search_w'), true, 'actionFind', (): void => {
            this.toggleFindBar();
          });
          // 溢出钮：安卓实测 40×48dp；弹出层与图标格顶边对齐（下拉位置回退一格）
          Column() {
            Image($r('app.media.ic_more_w')).width(24).height(24);
          }
          .width(40)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .id('actionMore')
          .bindPopup(this.overflowOpen, {
            builder: this.overflowPopup,
            placement: Placement.BottomRight,
            // 安卓弹出层右缘距屏右 3.4dp、顶边与图标格顶边齐（dropDownVerticalOffset 4dp）
            offset: { x: 4, y: -48 },
            radius: 2,
            popupColor: '#FFFAFAFA',
            shadow: { radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 },
            mask: false,
            enableArrow: false,
            autoCancel: true,
            onStateChange: (e: PopupStateChangeParam): void => {
              if (!e.isVisible) {
                this.overflowSubmenu = false;
              }
            }
          })
          .onClick((): void => {
            this.overflowSubmenu = false;
            this.overflowOpen = !this.overflowOpen;
          });
        }
        .backgroundColor($r('app.color.action_bar'))
        .width('100%')
        .height(56);

        // 状态条（行号开关控制显隐；光标行在程序性移动后精确）
        if (this.showNumbers) {
          Text('共 ' + this.lineCount() + ' 行 · 第 ' + (this.caretLine + 1) + ' 行')
            .fontSize(12)
            .fontColor($r('app.color.gutter_text'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(4);
        }

        // 只读横幅
        if (this.banner !== '') {
          Text(this.banner)
            .fontSize(13)
            .fontColor($r('app.color.banner_text'))
            .backgroundColor($r('app.color.banner_bg'))
            .width('100%')
            .padding(8);
        }

        // 查找替换栏（行 1：查询 + 计数 + 上/下 + 三个开关；行 2：替换 + 替换/全部 + 关闭）
        if (this.findOpen) {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              TextInput({ placeholder: '查找…', text: this.query })
                .id('findInput')
                .layoutWeight(1)
                .fontSize(14)
                .onChange((v: string): void => {
                  this.query = v;
                  this.scheduleFind();
                })
                .onSubmit((): void => {
                  if (this.matches.length > 0) {
                    this.gotoMatch(this.matchIndex + 1);
                  } else {
                    this.runFindNow();
                  }
                });
              Text(this.matchInfo).fontSize(12).fontColor('#666666');
              ToolIcon($r('app.media.ic_chevron_up_b'), 6, 'findPrev', (): void => {
                this.gotoMatch(this.matchIndex - 1);
              });
              ToolIcon($r('app.media.ic_chevron_down_b'), 6, 'findNext', (): void => {
                this.gotoMatch(this.matchIndex + 1);
              });
              Button('Aa').fontSize(14).backgroundColor('#00000000')
                .fontColor(this.caseSens ? $r('app.color.find_toggle_on') : $r('app.color.find_toggle_off'))
                .onClick((): void => {
                  this.caseSens = !this.caseSens;
                  this.runFindNow();
                });
              Button('.*').fontSize(14).backgroundColor('#00000000')
                .fontColor(this.useRegex ? $r('app.color.find_toggle_on') : $r('app.color.find_toggle_off'))
                .onClick((): void => {
                  this.useRegex = !this.useRegex;
                  this.runFindNow();
                });
              Button('[wd]').fontSize(14).backgroundColor('#00000000')
                .fontColor(this.wholeWord ? $r('app.color.find_toggle_on') : $r('app.color.find_toggle_off'))
                .onClick((): void => {
                  this.wholeWord = !this.wholeWord;
                  this.runFindNow();
                });
            }
            Row({ space: 6 }) {
              TextInput({ placeholder: '替换为…', text: this.replacement })
                .layoutWeight(1)
                .fontSize(14)
                .onChange((v: string): void => {
                  this.replacement = v;
                });
              ToolIcon($r('app.media.ic_swap_horiz_b'), 6, 'findReplaceOne', (): void => {
                this.replaceCurrent();
              });
              ToolIcon($r('app.media.ic_done_all_b'), 6, 'findReplaceAll', (): void => {
                this.replaceAll();
              });
              ToolIcon($r('app.media.ic_close_b'), 6, 'findClose', (): void => {
                this.toggleFindBar();
              });
            }
          }
          .padding(8)
          .backgroundColor('#FFF9F9F9');
        }

        // 编辑区 / 只读预览
        if (!this.readOnly) {
          TextArea({ placeholder: '', text: this.content, controller: this.ctl })
            .layoutWeight(1)
            .width('100%')
            .fontSize(this.fontSize)
            .caretColor($r('app.color.brand'))
            .onChange((v: string): void => {
              if (v !== this.content) {
                this.content = v;
                this.invalidateLines();
                this.markDirty();
                this.scheduleFind();
              }
            })
            .onTextSelectionChange((start: number, end: number): void => {
              // 用户点选/拖选光标后同步光标行（安卓版在 EditText 里做同样的事）
              const line: number = lineOf(this.cachedLineStarts(), start);
              if (line !== this.caretLine) {
                this.caretLine = line;
              }
            });
        } else {
          List({ scroller: this.viewerScroller }) {
            LazyForEach(this.viewerSource, (line: string, index: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  if (this.showNumbers) {
                    Text((index + 1).toString())
                      .fontSize(this.fontSize - 2)
                      .fontColor($r('app.color.gutter_text'))
                      .width(44)
                      .textAlign(TextAlign.End);
                  }
                  if (this.wordWrap) {
                    Text(line === '' ? ' ' : line).fontSize(this.fontSize);
                  } else {
                    Text(line === '' ? ' ' : line)
                      .fontSize(this.fontSize)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                  }
                }
                .alignItems(VerticalAlign.Top)
                .padding({ top: 1, bottom: 1 })
                .backgroundColor(this.rowBackground(index))
              }
            }, (line: string, index: number) => index.toString());
          }
          .layoutWeight(1)
          .width('100%')
          .edgeEffect(EdgeEffect.Spring);
          if (this.viewerCapped) {
            Text('行数过多，仅显示前 ' + VIEWER_LINE_CAP + ' 行')
              .fontSize(12)
              .fontColor('#666666')
              .padding(4);
          }
        }
      }.width('100%').height('100%');

      if (this.loading) {
        Column() {
          LoadingProgress().width(48).height(48);
          Text(this.loadingText).fontSize(14).margin({ top: 8 });
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .backgroundColor('#88000000');
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_bg'));
  }
}

/** 纯函数：行首偏移表（末尾哨兵便于二分）。 */
function buildLineStarts(text: string): number[] {
  const starts: number[] = [0];
  for (let i: number = 0; i < text.length; i++) {
    if (text.charAt(i) === '\n') {
      starts.push(i + 1);
    }
  }
  starts.push(text.length);
  return starts;
}

function lineOf(starts: number[], offset: number): number {
  let lo: number = 0;
  let hi: number = starts.length - 2;
  while (lo < hi) {
    const mid: number = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

function baseName(path: string): string {
  const i: number = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

function splitCapped(text: string): string[] {
  const lines: string[] = text.split('\n');
  if (lines.length > VIEWER_LINE_CAP) {
    return lines.slice(0, VIEWER_LINE_CAP);
  }
  return lines;
}

async function importCharsetOf(data: Uint8Array, codecs: TextCodecs): Promise<string> {
  // isAuto 分支的检测：BOM→严格UTF-8→GBK系→Latin-1（与 core.detect 一致，
  // 这里经注入 codecs 走平台解码器做严格校验）。
  if (data.length >= 3 && data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf) {
    return UTF_8;
  }
  if (data.length >= 2 && data[0] === 0xff && data[1] === 0xfe) {
    return 'UTF-16LE';
  }
  if (data.length >= 2 && data[0] === 0xfe && data[1] === 0xff) {
    return 'UTF-16BE';
  }
  if (data.length === 0) {
    return UTF_8;
  }
  try {
    codecs.decode(data, UTF_8);
    // 非严格解码恒成功；用往返一致性近似严格校验
    const back: Uint8Array = codecs.encode(codecs.decode(data, UTF_8), UTF_8);
    if (back.length === data.length) {
      let same: boolean = true;
      for (let i: number = 0; i < data.length; i++) {
        if (back[i] !== data[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        return UTF_8;
      }
    }
  } catch (e) {
    // fallthrough
  }
  return 'GB18030';
}

/**
 * LazyForEach 数据源（只读预览虚拟化：只渲染可视行）。
 * 额外带一份“行 → 命中标记”（1 普通命中 / 2 当前命中），
 * 变更时整表 reload，重渲染可视行即可（不逐行通知，避免上千次回调）。
 */
class LineDataSource implements IDataSource {
  private lines: string[];
  private listeners: DataChangeListener[] = [];
  private marks: Map<number, number> = new Map<number, number>();

  constructor(lines: string[]) {
    this.lines = lines;
  }

  totalCount(): number {
    return this.lines.length;
  }

  getData(index: number): string {
    return this.lines[index];
  }

  /** 该行的命中标记：0 无 / 1 普通命中 / 2 当前命中。 */
  markKind(index: number): number {
    return this.marks.get(index) ?? 0;
  }

  setMarks(next: Map<number, number>): void {
    this.marks = next;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}
