import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { MODE_NEW_EMPTY, MODE_LAST_FILE, MODE_LAST_DIR } from '../core/StartupDecision.ets';
import { AUTO } from '../core/EncodingDetector.ets';

/**
 * 设置与最近状态持久化（对应安卓版 Prefs.java，键名/默认值逐项对齐）。
 * 底层用 @kit.ArkData 的 Preferences（应用沙箱内 Key-Value 文件），
 * 每次写入后 flush，保证杀进程不丢。
 */
const STORE_NAME: string = 'paper_prefs';

const KEY_LAST_FILE: string = 'lastFilePath';
const KEY_LAST_DIR: string = 'lastDirectory';
const KEY_LAST_IS_SCRATCH: string = 'lastIsScratch';
const KEY_STARTUP_MODE: string = 'startupMode';
const KEY_AUTOSAVE_SEC: string = 'autosaveIntervalSec';
const KEY_REMEMBER_LINE: string = 'rememberLastLine';
const KEY_LAST_LINE: string = 'lastLine';
const KEY_LAST_LINE_PATH: string = 'lastLinePath';
const KEY_FONT_SIZE: string = 'fontSizeSp';
const KEY_SHOW_LINE_NUMBERS: string = 'showLineNumbers';
const KEY_WORD_WRAP: string = 'wordWrap';
const KEY_DEFAULT_ENCODING: string = 'defaultEncoding';
const KEY_BROWSER_SORT: string = 'browserSort';
const KEY_BROWSER_SORT_DESC: string = 'browserSortDesc';

export const DEFAULT_FONT_SIZE: number = 16;
export const MIN_FONT_SIZE: number = 8;
export const MAX_FONT_SIZE: number = 96;
/** 自动保存默认关闭（与安卓版一致）。 */
export const DEFAULT_AUTOSAVE_SEC: number = 0;
const MAX_AUTOSAVE_SEC: number = 3600;

export class Prefs {
  private ctx: common.UIAbilityContext;
  private cached: preferences.Preferences | null = null;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  private store(): preferences.Preferences {
    if (this.cached === null) {
      this.cached = preferences.getPreferencesSync(this.ctx, { name: STORE_NAME });
    }
    return this.cached as preferences.Preferences;
  }

  private put(key: string, value: preferences.ValueType): void {
    const s: preferences.Preferences = this.store();
    s.putSync(key, value);
    try {
      s.flush((): void => {});
    } catch (e) {
      // flush 失败只影响落盘时机，内存值已生效
    }
  }

  private getStr(key: string, def: string): string {
    try {
      return this.store().getSync(key, def) as string;
    } catch (e) {
      return def;
    }
  }

  private getNum(key: string, def: number): number {
    try {
      return this.store().getSync(key, def) as number;
    } catch (e) {
      return def;
    }
  }

  private getBool(key: string, def: boolean): boolean {
    try {
      return this.store().getSync(key, def) as boolean;
    } catch (e) {
      return def;
    }
  }

  // ---- 最近状态 ----

  lastFilePath(): string {
    return this.getStr(KEY_LAST_FILE, '');
  }

  lastDirectory(): string {
    return this.getStr(KEY_LAST_DIR, '');
  }

  lastIsScratch(): boolean {
    return this.getBool(KEY_LAST_IS_SCRATCH, true);
  }

  /** 打开/保存后记录（目录取路径父级；空路径则保留旧目录）。 */
  recordOpened(path: string, isScratch: boolean): void {
    let dir: string = '';
    if (path !== null && path !== '') {
      const i: number = path.lastIndexOf('/');
      if (i > 0) {
        dir = path.substring(0, i);
      }
    }
    const s: preferences.Preferences = this.store();
    s.putSync(KEY_LAST_FILE, path === null ? '' : path);
    s.putSync(KEY_LAST_IS_SCRATCH, isScratch);
    s.putSync(KEY_LAST_DIR, dir === '' ? this.lastDirectory() : dir);
    try {
      s.flush((): void => {});
    } catch (e) {
      // ignore
    }
  }

  /** 只记录目录（浏览/选择目录时）。 */
  recordDirectory(dir: string): void {
    if (dir !== null && dir !== '') {
      this.put(KEY_LAST_DIR, dir);
    }
  }

  rememberLastLine(): boolean {
    return this.getBool(KEY_REMEMBER_LINE, true);
  }

  setRememberLastLine(remember: boolean): void {
    this.put(KEY_REMEMBER_LINE, remember);
  }

  /** 记住光标行（0-based），并与所属文件绑定。 */
  recordLine(path: string, line: number): void {
    if (path === null || path === '') {
      return;
    }
    const s: preferences.Preferences = this.store();
    s.putSync(KEY_LAST_LINE_PATH, path);
    s.putSync(KEY_LAST_LINE, Math.max(0, line));
    try {
      s.flush((): void => {});
    } catch (e) {
      // ignore
    }
  }

  /** 取 path 记住的行；无记录或属于别的文件时返回 0。 */
  lineFor(path: string): number {
    if (path === null || path !== this.getStr(KEY_LAST_LINE_PATH, '')) {
      return 0;
    }
    return Math.max(0, this.getNum(KEY_LAST_LINE, 0));
  }

  // ---- 设置 ----

  startupMode(): string {
    const m: string = this.getStr(KEY_STARTUP_MODE, MODE_LAST_FILE);
    if (m === MODE_NEW_EMPTY || m === MODE_LAST_DIR || m === MODE_LAST_FILE) {
      return m;
    }
    return MODE_LAST_FILE;
  }

  setStartupMode(mode: string): void {
    this.put(KEY_STARTUP_MODE, mode);
  }

  /** 0 = 关闭，否则为自动保存间隔秒数。 */
  autosaveIntervalSec(): number {
    return this.getNum(KEY_AUTOSAVE_SEC, DEFAULT_AUTOSAVE_SEC);
  }

  setAutosaveIntervalSec(sec: number): void {
    this.put(KEY_AUTOSAVE_SEC, Math.max(0, Math.min(MAX_AUTOSAVE_SEC, Math.floor(sec))));
  }

  fontSizeSp(): number {
    return this.getNum(KEY_FONT_SIZE, DEFAULT_FONT_SIZE);
  }

  setFontSizeSp(size: number): void {
    this.put(KEY_FONT_SIZE, Math.max(MIN_FONT_SIZE, Math.min(MAX_FONT_SIZE, Math.round(size))));
  }

  showLineNumbers(): boolean {
    return this.getBool(KEY_SHOW_LINE_NUMBERS, true);
  }

  setShowLineNumbers(show: boolean): void {
    this.put(KEY_SHOW_LINE_NUMBERS, show);
  }

  wordWrap(): boolean {
    return this.getBool(KEY_WORD_WRAP, true);
  }

  setWordWrap(wrap: boolean): void {
    this.put(KEY_WORD_WRAP, wrap);
  }

  /** EncodingDetector.USER_CHOICES 之一；AUTO 表示按文件检测。 */
  defaultEncoding(): string {
    return this.getStr(KEY_DEFAULT_ENCODING, AUTO);
  }

  setDefaultEncoding(charsetName: string): void {
    this.put(KEY_DEFAULT_ENCODING, charsetName);
  }

  // ---- 浏览器 ----

  /** "name" / "size" / "date" / "type"。 */
  browserSort(): string {
    return this.getStr(KEY_BROWSER_SORT, 'name');
  }

  setBrowserSort(field: string): void {
    this.put(KEY_BROWSER_SORT, field);
  }

  browserSortDesc(): boolean {
    return this.getBool(KEY_BROWSER_SORT_DESC, false);
  }

  setBrowserSortDesc(desc: boolean): void {
    this.put(KEY_BROWSER_SORT_DESC, desc);
  }
}
