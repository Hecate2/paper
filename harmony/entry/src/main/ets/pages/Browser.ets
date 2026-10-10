import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
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
    this.loading = true;
    try {
      this.allRows = await f.listDir(dir);
    } finally {
      this.loading = false;
    }
    this.applySort();
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
      // 路径条（搜索时高亮色调，对应安卓 pathBar）
      Text(this.pathBarText())
        .fontSize(13)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding(8)
        .backgroundColor(this.query.trim() !== '' ? $r('app.color.browser_search_bg') : '#FFF0F0F0');

      // 工具栏（对齐安卓：先导航/排序，再搜索；横向可滚避免窄屏挤压）
      Scroll() {
        Row({ space: 8 }) {
          Button('‹ 返回').fontSize(13).onClick((): void => {
            router.back();
          });
          Button('⬆ 上级').fontSize(13).onClick((): void => {
            const i: number = this.currentDir.lastIndexOf('/');
            if (i > 0) {
              this.currentDir = this.currentDir.substring(0, i);
              this.query = '';
              this.reload();
            }
          });
          Select([{ value: '名称' }, { value: '大小' }, { value: '时间' }, { value: '类型' }])
            .selected(sortIndex(this.sortField))
            .onSelect((index: number): void => {
              const fields: SortField[] = ['name', 'size', 'date', 'type'];
              this.sortField = fields[index];
              this.prefs?.setBrowserSort(fields[index]);
              this.applySort();
            });
          Button(this.sortDesc ? '⬇ 降序' : '⬆ 升序').fontSize(13).onClick((): void => {
            this.sortDesc = !this.sortDesc;
            this.prefs?.setBrowserSortDesc(this.sortDesc);
            this.applySort();
          });
          if (this.pickMode) {
            Button('选择当前目录').fontSize(13).onClick((): void => {
              this.prefs?.recordDirectory(this.currentDir);
              AppStorage.setOrCreate('paperPickDir', this.currentDir);
              router.back();
            });
          } else {
            Button('新建空文件').fontSize(13).onClick((): void => {
              this.prefs?.recordDirectory(this.currentDir);
              AppStorage.setOrCreate('paperNewFile', true);
              router.back();
            });
            Button('任意文件…').fontSize(13).onClick((): void => {
              this.pickArbitrary();
            });
          }
        }.padding({ left: 8, right: 8, top: 6, bottom: 6 });
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%');

      // 搜索行：.* 开关在左（同安卓），输入框占满，有内容时才显示清空
      Row({ space: 6 }) {
        Button('.*').fontSize(13).backgroundColor('#00000000')
          .fontColor(this.regexMode ? '#2196F3' : '#9E9E9E')
          .onClick((): void => {
            this.regexMode = !this.regexMode;
            this.applyFilter();
          });
        TextInput({ placeholder: '搜索当前目录…', text: this.query })
          .layoutWeight(1)
          .fontSize(14)
          .onChange((v: string): void => {
            this.query = v;
            this.applyFilter();
          });
        if (this.query.trim() !== '') {
          Button('✕').fontSize(13).backgroundColor('#00000000')
            .fontColor('#666666').onClick((): void => {
            this.query = '';
            this.applyFilter();
          });
        }
      }.padding({ left: 8, right: 8, bottom: 6 });

      if (this.loading) {
        LoadingProgress().width(36).height(36).margin({ top: 24 });
      } else {
        List() {
          ForEach(this.rows, (dr: DisplayRow, index: number) => {
            ListItem() {
              if (dr.kind === KIND_ENTRY) {
                // 单行：名称在左，大小/时间在右（同安卓 browser_row.xml）
                Row({ space: 8 }) {
                  Text((dr.isDir ? '📁 ' : '') + dr.name)
                    .fontSize(15)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
                    .opacity(this.pickMode && !dr.isDir ? 0.4 : 1);
                  Text((dr.isDir ? '文件夹' : formatSize(dr.size)) + ' · ' + formatDate(dr.mtimeMs))
                    .fontSize(11)
                    .fontColor('#FF9E9E9E')
                    .maxLines(1);
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                .onClick((): void => {
                  this.onRowClick(dr);
                });
              } else {
                Text(dr.text)
                  .fontSize(14)
                  .fontColor('#888888')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(24);
              }
            }
          }, (dr: DisplayRow): string => {
            // 键必须包含内容：否则搜索过滤后同一位置的旧行不会刷新
            return dr.kind + '|' + (dr.kind === KIND_ENTRY ? dr.name : dr.text);
          });
        }
        .layoutWeight(1)
        .width('100%');
      }
    }.width('100%').height('100%');
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
