import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
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
 * 3. 光标行 K 只在程序性移动（打开恢复/查找跳转）后精确已知；
 *    用户触摸移动光标后 K 会滞后——这是 ArkUI 未暴露 caret 事件所致，
 *    行号总数与保存/查找逻辑不受影响。
 * 4. 真实路径 ↔ Picker URI：FILE 模式既可是沙箱路径也可是持久授权 URI；
 *    沙箱内走原子写，Picker URI 走覆盖写（save 面板拿到的 URI 本来就是
 *    用户刚确认的位置，不做 .bak）。
 */

const FIND_DEBOUNCE_MS: number = 150;
const VIEWER_LINE_CAP: number = 50000;

@CustomDialog
struct SaveDialogContent {
  controller?: CustomDialogController;
  fileName: string = '';
  dirPath: string = '';
  onBrowse: (name: string) => void = (name: string): void => {};
  onSystem: (name: string) => void = (name: string): void => {};
  onOk: (name: string) => void = (name: string): void => {};

  build() {
    Column({ space: 12 }) {
      Text('保存文件').fontSize(18).fontWeight(FontWeight.Bold);
      TextInput({ placeholder: '文件名（默认 .txt）', text: this.fileName })
        .onChange((v: string): void => {
          this.fileName = v;
        });
      Text('保存到：' + (this.dirPath === '' ? '（未选择）' : this.dirPath))
        .fontSize(13)
        .width('100%');
      Row({ space: 12 }) {
        Button('浏览…').fontSize(14).onClick((): void => {
          const n: string = this.fileName;
          this.controller?.close();
          this.onBrowse(n);
        });
        Button('其他位置…').fontSize(14).onClick((): void => {
          const n: string = this.fileName;
          this.controller?.close();
          this.onSystem(n);
        });
      }.justifyContent(FlexAlign.End).width('100%');
      Row({ space: 12 }) {
        Button('取消').onClick((): void => {
          this.controller?.close();
        });
        Button('保存', { type: ButtonType.Capsule, stateEffect: true }).onClick((): void => {
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
    Column({ space: 12 }) {
      Text('重命名').fontSize(18).fontWeight(FontWeight.Bold);
      TextInput({ placeholder: '新文件名', text: this.fileName })
        .onChange((v: string): void => {
          this.fileName = v;
        });
      Row({ space: 12 }) {
        Button('取消').onClick((): void => {
          this.controller?.close();
        });
        Button('保存', { type: ButtonType.Capsule, stateEffect: true }).onClick((): void => {
          const n: string = this.fileName;
          this.controller?.close();
          this.onOk(n);
        });
      }.justifyContent(FlexAlign.End).width('100%');
    }.padding(20).width('90%');
  }
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

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.prefs = new Prefs(ctx);
    this.files = new FileService(ctx);
    this.codecs = new UtilTextCodecs();
    this.applySettings();
    this.consumeShare();
    if (this.pendingShareUri !== null || this.pendingShareText !== null) {
      const uri: string | null = this.pendingShareUri;
      const text: string | null = this.pendingShareText;
      this.pendingShareUri = null;
      this.pendingShareText = null;
      if (uri !== null) {
        this.openUri(uri);
      } else {
        this.resetToScratch(text);
        this.toast('已粘贴分享的文本（未保存）');
      }
    } else {
      this.routeStartup();
    }
    this.autoTimer = setInterval((): void => {
      this.maybeAutosave();
    }, 1000);
  }

  aboutToDisappear(): void {
    this.recordCaretLine();
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
        this.openPath(openPath, -1);
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
      if (lastFile.indexOf('://') >= 0 && !lastFile.startsWith('file://')) {
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
    this.viewerCapped = false;
    this.content = initialText === null ? '' : initialText;
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
    if (path.startsWith('file://')) {
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
      this.fileName = '分享文件';
    } else {
      this.mode = 'scratch';
      this.fileKey = '';
      this.fileName = '未命名';
    }
    if (allowsSave(tier) && !binary) {
      this.content = text;
      this.viewerLines = [];
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
      this.viewerCapped = this.viewerLines.length >= VIEWER_LINE_CAP;
      this.content = text;
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
    // Picker URI（或沙箱外）走覆盖写；沙箱路径走原子写+.bak
    const isUri: boolean = target.indexOf('://') >= 0 && !target.startsWith('file://');
    const data: Uint8Array = codecs.encode(this.content, this.encoding);
    if (userInitiated) {
      this.showLoading('正在保存…');
    }
    try {
      if (isUri) {
        await f.writeUri(target, data);
      } else {
        const realPath: string = target.startsWith('file://') ? target.substring(7) : target;
        await atomicWrite(f.atomic(), realPath, data);
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
    let key: string = this.fileKey;
    if (key.startsWith('file://')) {
      key = key.substring(7);
    }
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
  }

  private gotoMatch(index: number): void {
    if (this.matches.length === 0) {
      return;
    }
    const total: number = this.matches.length / 2;
    this.matchIndex = ((index % total) + total) % total;
    this.matchInfo = this.matchIndex + 1 + '/' + total;
    const start: number = this.matches[this.matchIndex * 2];
    if (this.readOnly) {
      // 只读预览：滚到命中所在行并高亮该行
      const line: number = lineOf(buildLineStarts(this.content), start);
      this.viewerScroller.scrollToIndex(Math.min(line, this.viewerLines.length - 1));
      this.caretLine = line;
      return;
    }
    const end: number = this.matches[this.matchIndex * 2 + 1];
    this.caretLine = lineOf(buildLineStarts(this.content), start);
    try {
      this.ctl.caretPosition(end);
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
      this.encoding = charset;
      this.viewerLines = this.readOnly ? splitCapped(this.content) : [];
      this.clearMatches();
    } catch (e) {
      this.toast('打开失败：' + String(e));
    } finally {
      this.hideLoading();
    }
  }

  // ---- 行号/杂项 ----

  private lineCount(): number {
    let n: number = 1;
    const t: string = this.content;
    for (let i: number = 0; i < t.length; i++) {
      if (t.charAt(i) === '\n') {
        n++;
      }
    }
    return n;
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

  private encodingIndex(): number {
    for (let i: number = 0; i < USER_CHOICES.length; i++) {
      if (USER_CHOICES[i] === this.encoding) {
        return i;
      }
    }
    return 0;
  }

  // ---- 界面 ----

  build() {
    Stack() {
      Column({ space: 0 }) {
        // 标题（可点击重命名，对应安卓 clickable title）
        Text((this.dirty ? '• ' : '') + this.fileName + ' · ' + this.encoding)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 6 })
          .onClick((): void => {
            this.actionRename();
          });

        // 工具栏（放顶部：对应安卓顶栏菜单；放底部会被输入法盖住）
        Scroll() {
          Row({ space: 8 }) {
            Button('新建').fontSize(13).onClick((): void => {
              if (this.dirty) {
                this.confirmDiscardThen((): void => {
                  this.resetToScratch(null);
                });
              } else {
                this.resetToScratch(null);
              }
            });
            Button('打开').fontSize(13).onClick((): void => {
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
            });
            Button('保存').fontSize(13).enabled(!this.readOnly).onClick((): void => {
              this.actionSave();
            });
            Button('关闭').fontSize(13).onClick((): void => {
              this.actionClose();
            });
            Button('重命名').fontSize(13)
              .enabled(this.mode === 'file' && !this.readOnly)
              .onClick((): void => {
                this.actionRename();
              });
            Button('另存为').fontSize(13).enabled(!this.readOnly).onClick((): void => {
              this.actionSaveAs();
            });
            Button('查找').fontSize(13).onClick((): void => {
              this.findOpen = !this.findOpen;
              if (this.findOpen && this.query !== '') {
                this.runFindNow();
              }
              if (!this.findOpen) {
                this.clearMatches();
              }
            });
            Button('备份').fontSize(13).enabled(this.mode === 'file').onClick((): void => {
              this.restoreBackup();
            });
            Select(USER_CHOICES.map((c: string): SelectOption => {
              return { value: labelOf(c) };
            }))
              .selected(this.encodingIndex())
              .onSelect((index: number): void => {
                this.onEncodingChosen(USER_CHOICES[index]);
              });
            Button('设置').fontSize(13).onClick((): void => {
              router.pushUrl({ url: 'pages/Settings' });
            });
          }.padding({ left: 8, right: 8, top: 6, bottom: 6 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%');

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

        // 查找替换栏
        if (this.findOpen) {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              TextInput({ placeholder: '查找…', text: this.query })
                .layoutWeight(1)
                .fontSize(14)
                .onChange((v: string): void => {
                  this.query = v;
                  this.scheduleFind();
                });
              Text(this.matchInfo).fontSize(12).fontColor('#666666');
              Button('上').fontSize(13).onClick((): void => {
                this.gotoMatch(this.matchIndex - 1);
              });
              Button('下').fontSize(13).onClick((): void => {
                this.gotoMatch(this.matchIndex + 1);
              });
            }
            Row({ space: 6 }) {
              TextInput({ placeholder: '替换为…', text: this.replacement })
                .layoutWeight(1)
                .fontSize(14)
                .onChange((v: string): void => {
                  this.replacement = v;
                });
              Button('替换').fontSize(13).onClick((): void => {
                this.replaceCurrent();
              });
              Button('全部').fontSize(13).onClick((): void => {
                this.replaceAll();
              });
              Button('Aa').fontSize(13)
                .type(this.caseSens ? ButtonType.Capsule : ButtonType.Normal)
                .onClick((): void => {
                  this.caseSens = !this.caseSens;
                  this.runFindNow();
                });
              Button('.*').fontSize(13)
                .type(this.useRegex ? ButtonType.Capsule : ButtonType.Normal)
                .onClick((): void => {
                  this.useRegex = !this.useRegex;
                  this.runFindNow();
                });
              Button('[w]').fontSize(13)
                .type(this.wholeWord ? ButtonType.Capsule : ButtonType.Normal)
                .onClick((): void => {
                  this.wholeWord = !this.wholeWord;
                  this.runFindNow();
                });
              Button('✕').fontSize(13).onClick((): void => {
                this.findOpen = false;
                this.clearMatches();
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
                this.markDirty();
                this.scheduleFind();
              }
            });
        } else {
          List({ scroller: this.viewerScroller }) {
            LazyForEach(new LineDataSource(this.viewerLines), (line: string, index: number) => {
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
                .backgroundColor(this.caretLine === index ? $r('app.color.current_line') : '#00000000')
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
    }.width('100%').height('100%');
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

/** LazyForEach 数据源（只读预览虚拟化：只渲染可视行）。 */
class LineDataSource implements IDataSource {
  private lines: string[];
  private listeners: DataChangeListener[] = [];

  constructor(lines: string[]) {
    this.lines = lines;
  }

  totalCount(): number {
    return this.lines.length;
  }

  getData(index: number): string {
    return this.lines[index];
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
