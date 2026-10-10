import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fitMiddle, textWidthVp } from '../model/UiText.ets';
import { Prefs } from '../model/Prefs.ets';
import { FileService } from '../model/FileService.ets';
import type { BrowserRow, SortField } from '../model/Types.ets';

/**
 * 目录浏览器页（对应安卓版 BrowserActivity）。
 *
 * 两种模式（由 Index 页经 AppStorage 传入）：
 * - open：点文件 → 回编辑器打开；另有“新建空文件”“任意文件…”入口
 * - pickDir：为保存对话框选择目录 → “选择当前目录”按钮返回
 *
 * 复刻：目录常在前、按名称/大小/时间/类型排序（升/降）、当前目录内
 * 搜索（子串/正则，不递归）、目录一次列举后搜索排序只走内存、
 * 超大目录的“正在读取…”占位。
 *
 * 平台差异：只能列举沙箱内目录；“任意文件…”走系统 Picker
 * （与安卓“显示全部文件任意后缀”等价：Picker 不限后缀）。
 * 另一处有意的改进：pickDir 模式下文件行不可点（安卓版会误把文件
 * 当目录返回，这里直接禁用）。
 */

interface DisplayRow {
  kind: number; // 0=条目，1=空占位，2=搜索脚注
  name: string;
  isDir: boolean;
  size: number;
  mtimeMs: number;
  text: string;
}

function entryRow(r: BrowserRow): DisplayRow {
  return { kind: KIND_ENTRY, name: r.name, isDir: r.isDir, size: r.size, mtimeMs: r.mtimeMs, text: '' };
}

const KIND_ENTRY: number = 0;
const KIND_EMPTY: number = 1;
const KIND_FOOTER: number = 2;

@Entry
@Component
struct Browser {
  @State currentDir: string = '';
  @State rows: DisplayRow[] = [];
  @State query: string = '';
  @State regexMode: boolean = false;
  @State sortField: SortField = 'name';
  @State sortDesc: boolean = false;
  @State pickMode: boolean = false;
  @State loading: boolean = false;
  @State listWidth: number = 0;
  private loadHintTimer: number = -1;

  private prefs: Prefs | null = null;
  private files: FileService | null = null;
  private allRows: BrowserRow[] = [];

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.prefs = new Prefs(ctx);
    this.files = new FileService(ctx);
    this.sortField = (this.prefs.browserSort() as SortField) ?? 'name';
    if (this.sortField !== 'name' && this.sortField !== 'size' &&
      this.sortField !== 'date' && this.sortField !== 'type') {
      this.sortField = 'name';
    }
    this.sortDesc = this.prefs.browserSortDesc();
    try {
      this.pickMode = (AppStorage.get<string>('paperBrowserMode') ?? 'open') === 'pickDir';
      const start: string = AppStorage.get<string>('paperBrowserStart') ?? '';
      this.currentDir = start !== '' ? start : this.files.filesDir();
    } catch (e) {
      this.currentDir = this.files !== null ? this.files.filesDir() : '';
    }
    this.reload();
  }

  private async reload(): Promise<void> {
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    // 目录不存在时向上回退（与安卓版 while 非目录取父级一致）
    let dir: string = this.currentDir;
    for (let guard: number = 0; guard < 32; guard++) {
      if (dir === '' || (await f.isDirectory(dir))) {
        break;
      }
      const i: number = dir.lastIndexOf('/');
      dir = i > 0 ? dir.substring(0, i) : '';
    }
    if (dir === '') {
      dir = f.filesDir();
    }
    this.currentDir = dir;
    this.showLoadingHint();
    try {
      this.allRows = await f.listDir(dir);
    } finally {
      this.cancelLoadingHint();
    }
    this.applySort();
  }

  /** 与安卓 LOADING_HINT_MS 一致：读目录超过 150ms 才显示占位行，快速目录不闪。 */
  private showLoadingHint(): void {
    this.cancelLoadingHint();
    this.loadHintTimer = setTimeout((): void => {
      this.loadHintTimer = -1;
      this.loading = true;
    }, 150);
  }

  private cancelLoadingHint(): void {
    if (this.loadHintTimer >= 0) {
      clearTimeout(this.loadHintTimer);
      this.loadHintTimer = -1;
    }
    this.loading = false;
  }

  /** 行右侧 meta 文本（与安卓 RowAdapter 一致）。 */
  private rowMetaText(dr: DisplayRow): string {
    return (dr.isDir ? '文件夹' : formatSize(dr.size)) + ' · ' + formatDate(dr.mtimeMs);
  }

  /** 行名（安卓 rowName 用 TruncateAt.MIDDLE）：按可用宽度做中间省略。 */
  private rowNameText(dr: DisplayRow, meta: string): string {
    const raw: string = (dr.isDir ? '📁 ' : '') + dr.name;
    if (this.listWidth <= 0 || raw.length <= 12) {
      return raw;
    }
    const avail: number = this.listWidth - 24 - 8 - textWidthVp(meta, 11);
    return fitMiddle(raw, avail, 15);
  }

  private applySort(): void {
    const dirs: BrowserRow[] = [];
    const files: BrowserRow[] = [];
    for (const r of this.allRows) {
      if (r.isDir) {
        dirs.push(r);
      } else {
        files.push(r);
      }
    }
    const cmp: (a: BrowserRow, b: BrowserRow) => number = this.comparator();
    dirs.sort(cmp);
    files.sort(cmp);
    this.allRows = [...dirs, ...files];
    this.applyFilter();
  }

  private comparator(): (a: BrowserRow, b: BrowserRow) => number {
    const field: SortField = this.sortField;
    const desc: boolean = this.sortDesc;
    const base: (a: BrowserRow, b: BrowserRow) => number = (a: BrowserRow, b: BrowserRow): number => {
      let r: number = 0;
      if (field === 'size') {
        r = a.size - b.size;
      } else if (field === 'date') {
        r = a.mtimeMs - b.mtimeMs;
      } else if (field === 'type') {
        r = compareStr(extensionOf(a.name), extensionOf(b.name));
      } else {
        r = compareStr(a.name.toLowerCase(), b.name.toLowerCase());
      }
      if (r === 0) {
        r = compareStr(a.name.toLowerCase(), b.name.toLowerCase());
      }
      return desc ? -r : r;
    };
    return base;
  }

  private applyFilter(): void {
    const q: string = this.query.trim();
    const searching: boolean = q !== '';
    let badRegex: boolean = false;
    let pat: RegExp | null = null;
    if (searching && this.regexMode) {
      try {
        pat = new RegExp(q);
      } catch (e) {
        badRegex = true;
      }
    }
    const out: DisplayRow[] = [];
    if (!searching || badRegex) {
      for (const r of this.allRows) {
        out.push(entryRow(r));
      }
    } else {
      const needle: string = q.toLowerCase();
      for (const r of this.allRows) {
        const hit: boolean = pat !== null ? pat.test(r.name) : r.name.toLowerCase().indexOf(needle) >= 0;
        if (hit) {
          out.push(entryRow(r));
        }
      }
    }
    if (out.length === 0) {
      out.push({
        kind: KIND_EMPTY,
        name: '',
        isDir: false,
        size: 0,
        mtimeMs: 0,
        text: searching ? '没有匹配「' + q + '」的项目' : '此目录为空'
      });
    } else if (searching && !badRegex) {
      out.push({
        kind: KIND_FOOTER,
        name: '',
        isDir: false,
        size: 0,
        mtimeMs: 0,
        text: '— 正在搜索「' + q + '」（仅当前目录）—'
      });
    }
    this.rows = out;
  }

  private pathBarText(): string {
    const q: string = this.query.trim();
    if (q !== '') {
      if (this.regexMode) {
        try {
          new RegExp(q);
        } catch (e) {
          return '正则表达式无效 · ' + this.currentDir;
        }
      }
      return '搜索：' + q + ' · ' + this.currentDir;
    }
    return this.currentDir;
  }

  private onRowClick(dr: DisplayRow): void {
    if (dr.kind !== KIND_ENTRY) {
      return;
    }
    const full: string = joinPath(this.currentDir, dr.name);
    if (dr.isDir) {
      this.currentDir = full;
      this.query = '';
      this.reload();
      return;
    }
    if (this.pickMode) {
      return; // pickDir 模式文件行禁用（见文件头注释）
    }
    this.prefs?.recordDirectory(this.currentDir);
    AppStorage.setOrCreate('paperOpenPath', full);
    router.back();
  }

  private async pickArbitrary(): Promise<void> {
    const f: FileService | null = this.files;
    if (f === null) {
      return;
    }
    try {
      const uris: string[] = await f.pickOpen();
      if (uris.length > 0) {
        AppStorage.setOrCreate('paperOpenPath', uris[0]);
        router.back();
      }
    } catch (e) {
      try {
        promptAction.showToast({ message: '未选择文件', duration: 1500 });
      } catch (e2) {
        // ignore
      }
    }
  }

  /**
   * 排序弹出菜单。安卓实测：PopupMenu 带 6 项（名称/大小/时间/类型 + 升序/降序），
   * 行高 48dp、文字 16sp，方向项与字段项同在一个菜单里（箭头按钮仍可一键切换）。
   */
  private sortMenuItems(): MenuElement[] {
    return [
      { value: '名称', action: (): void => { this.setSortField('name'); } },
      { value: '大小', action: (): void => { this.setSortField('size'); } },
      { value: '时间', action: (): void => { this.setSortField('date'); } },
      { value: '类型', action: (): void => { this.setSortField('type'); } },
      { value: '升序', action: (): void => { this.setSortDesc(false); } },
      { value: '降序', action: (): void => { this.setSortDesc(true); } }
    ];
  }

  private setSortField(field: SortField): void {
    this.sortField = field;
    this.prefs?.setBrowserSort(field);
    this.applySort();
  }

  private setSortDesc(desc: boolean): void {
    this.sortDesc = desc;
    this.prefs?.setBrowserSortDesc(desc);
    this.applySort();
  }

  private sortLabel(): string {
    if (this.sortField === 'size') {
      return '大小';
    }
    if (this.sortField === 'date') {
      return '时间';
    }
    if (this.sortField === 'type') {
      return '类型';
    }
    return '名称';
  }

  build() {
    Column({ space: 0 }) {
      // 顶栏（对齐安卓 DarkActionBar：home 图标格 56×56dp（=actionBarSize，图标居中）、
      // 标题 20sp 且左缩到 72dp（=home 56 + 内缩 16）、菜单项 48×48dp；
      // 选择目录模式没有“新建空文件”。）
      Row({ space: 0 }) {
        Column() {
          Image($r('app.media.ic_arrow_back_w')).width(24).height(24);
        }
        .width(56)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .id('browserBack')
        .onClick((): void => {
          router.back();
        });
        Text('选择文件')
          .fontSize(20)
          .fontColor($r('app.color.white'))
          .margin({ left: 16 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id('browserTitle');
        if (!this.pickMode) {
          Column() {
            Image($r('app.media.ic_add_w')).width(24).height(24);
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .id('browserNewFile')
          .onClick((): void => {
            this.prefs?.recordDirectory(this.currentDir);
            AppStorage.setOrCreate('paperNewFile', true);
            router.back();
          });
        }
      }
      .backgroundColor($r('app.color.action_bar'))
      .width('100%')
      .height(56);

      // 路径条（搜索时变琥珀色，同安卓 pathView：13sp、8dp 内边距、不限行数可换行）
      Text(this.pathBarText())
        .fontSize(13)
        .fontColor(this.query.trim() !== '' ? $r('app.color.browser_search_text') : $r('app.color.browser_path_text'))
        .width('100%')
        .padding(8)
        .backgroundColor(this.query.trim() !== '' ? $r('app.color.browser_search_bg') : $r('app.color.browser_path_bg'));

      // 工具栏（对齐 activity_browser.xml 的单行顺序：上级/排序/方向/选目录/正则/搜索/清空）
      // 实测安卓：整行 40dp 高、左/右内缩 2dp、控件间零间距；上级与方向钮 40×40dp、
      // 正则开关 36×36dp（14sp）、搜索框 40dp 高、清空钮 40×40dp（仅有内容时出现）。
      Row({ space: 0 }) {
        Column() {
          Image($r('app.media.ic_arrow_upward_b')).width(24).height(24);
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .id('browserUp')
        .onClick((): void => {
          const i: number = this.currentDir.lastIndexOf('/');
          if (i > 0) {
            this.currentDir = this.currentDir.substring(0, i);
            this.query = '';
            this.reload();
          }
        });
        // 排序字段按钮：安卓是 buttonBarButtonStyle 的 40dp 文字按钮（文字色 = accent
        // #2196F3、左右 8dp 内边距、minWidth 0），点开 48dp 行高的弹出菜单。
        Button(this.sortLabel())
          .type(ButtonType.Normal)
          .borderRadius(2)
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .backgroundColor('#00000000')
          .height(40)
          .padding({ left: 8, right: 8 })
          .id('browserSort')
          .bindMenu(this.sortMenuItems());
        Column() {
          Image(this.sortDesc ? $r('app.media.ic_chevron_down_b') : $r('app.media.ic_chevron_up_b'))
            .width(24)
            .height(24);
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .id('browserSortDir')
        .onClick((): void => {
          this.setSortDesc(!this.sortDesc);
        });
        if (this.pickMode) {
          Column() {
            Image($r('app.media.ic_check_b')).width(24).height(24);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .id('browserPickDir')
          .onClick((): void => {
            this.prefs?.recordDirectory(this.currentDir);
            AppStorage.setOrCreate('paperPickDir', this.currentDir);
            router.back();
          });
        }
        Button('.*', { type: ButtonType.Normal, stateEffect: true })
          .width(36)
          .height(36)
          .padding(0)
          .borderRadius(0)
          .fontSize(14)
          .fontColor(this.regexMode ? $r('app.color.find_toggle_on') : $r('app.color.find_toggle_off'))
          .backgroundColor('#00000000')
          .id('browserRegex')
          .onClick((): void => {
            this.regexMode = !this.regexMode;
            this.applyFilter();
          });
        TextInput({ placeholder: '搜索当前目录…', text: this.query })
          .layoutWeight(1)
          .constraintSize({ minWidth: 48 })
          .height(40)
          .fontSize(14)
          .borderRadius(0)
          .backgroundColor('#00000000')
          .padding({ left: 4, right: 4 })
          .id('browserSearch')
          .onChange((v: string): void => {
            this.query = v;
            this.applyFilter();
          });
        if (this.query.trim() !== '') {
          Column() {
            Image($r('app.media.ic_close_b')).width(24).height(24);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .id('browserClear')
          .onClick((): void => {
            this.query = '';
            this.applyFilter();
          });
        }
      }
      .width('100%')
      .height(40)
      .padding({ left: 2, right: 2 });

      if (this.loading) {
        // 安卓：目录读取超过 150ms 才显示“正在读取…”，且它就是一个普通列表行
        Row() {
          Text('正在读取…')
            .fontSize(15)
            .fontColor($r('app.color.row_name'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Start);
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .id('browserLoading');
      } else {
        List() {
          ForEach(this.rows, (dr: DisplayRow, index: number) => {
            ListItem() {
              if (dr.kind === KIND_ENTRY) {
                // 对齐 browser_row.xml：minHeight 44dp、左右 12dp 内缩、名称 15sp 且中省略、
                // 右侧 11sp 灰色 meta（文件夹“文件夹 · 时间”，文件“大小 · 时间”）
                Row({ space: 8 }) {
                  Text(this.rowNameText(dr, this.rowMetaText(dr)))
                    .fontSize(15)
                    .fontColor($r('app.color.row_name'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
                    .opacity(this.pickMode && !dr.isDir ? 0.4 : 1);
                  Text(this.rowMetaText(dr))
                    .fontSize(11)
                    .fontColor($r('app.color.row_meta'))
                    .maxLines(1);
                }
                .width('100%')
                .constraintSize({ minHeight: 44 })
                .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                .onClick((): void => {
                  this.onRowClick(dr);
                });
              } else {
                // 空目录/搜索占位/搜索脚注：安卓复用同一个 rowName 文本（15sp #212121、
                // 左缩 12dp，脚注单行），不是居中的灰色提示
                Row() {
                  Text(dr.text)
                    .fontSize(15)
                    .fontColor($r('app.color.row_name'))
                    .maxLines(dr.kind === KIND_FOOTER ? 1 : 20)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start);
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .constraintSize({ minHeight: 44 })
                .padding({ left: 12, right: 12, top: 12, bottom: 12 });
              }
            }
          }, (dr: DisplayRow): string => {
            // 键必须包含内容：否则搜索过滤后同一位置的旧行不会刷新
            return dr.kind + '|' + (dr.kind === KIND_ENTRY ? dr.name : dr.text);
          });
        }
        .layoutWeight(1)
        .width('100%')
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          const w: number = Number(newArea.width);
          if (Math.abs(w - this.listWidth) > 0.5) {
            this.listWidth = w;
          }
        })
        .divider({ strokeWidth: 1, color: '#11000000' });
      }

      // “任意文件…”兑底入口（安卓版直接在真目录里点任意后缀，没这个入口；
      // 鸿蒙只能列举沙箱目录，所以多给一行走系统 Picker。选择目录模式无此入口，
      // 与安卓 pickDir 模式只有“选择当前目录”一致。样式对齐安卓列表脚注行。）
      if (!this.pickMode) {
        Row() {
          Text('任意文件…')
            .fontSize(15)
            .fontColor($r('app.color.brand'))
            .maxLines(1)
            .layoutWeight(1)
            .textAlign(TextAlign.Start);
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .id('browserArbitrary')
        .onClick((): void => {
          this.pickArbitrary();
        });
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_bg'));
  }
}

function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
}

function compareStr(a: string, b: string): number {
  if (a === b) {
    return 0;
  }
  return a < b ? -1 : 1;
}

function joinPath(dir: string, name: string): string {
  if (dir === '') {
    return name;
  }
  return dir.charAt(dir.length - 1) === '/' ? dir + name : dir + '/' + name;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return bytes + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb.toFixed(1) + ' KB';
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return mb.toFixed(1) + ' MB';
  }
  return (mb / 1024).toFixed(1) + ' GB';
}

function formatDate(ms: number): string {
  if (ms <= 0) {
    return '--';
  }
  const d: Date = new Date(ms);
  const pad: (n: number) => string = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function sortIndex(field: SortField): number {
  if (field === 'size') {
    return 1;
  }
  if (field === 'date') {
    return 2;
  }
  if (field === 'type') {
    return 3;
  }
  return 0;
}
