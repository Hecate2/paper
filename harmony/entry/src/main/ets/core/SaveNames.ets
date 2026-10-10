/**
 * 保存对话框的默认文件名与校验（对应安卓版 core/SaveNames.java）。
 *
 * 默认名：未命名_yyyyMMdd_HHmmss.txt（本地时区，与安卓 SimpleDateFormat 一致）。
 * 为保持纯逻辑可单测，凡涉及文件系统的判定都以回调注入
 * （鸿蒙侧由 model/FileService.ets 传入基于 fs 的实现）。
 */

export const DEFAULT_EXT: string = '.txt';

/** 默认文件名（含 .txt 后缀）。 */
export function defaultFileName(epochMillis: number): string {
  const d: Date = new Date(epochMillis);
  const pad: (n: number) => string = (n: number): string => (n < 10 ? '0' + n : '' + n);
  const stamp: string =
    d.getFullYear().toString() +
    pad(d.getMonth() + 1) +
    pad(d.getDate()) +
    '_' +
    pad(d.getHours()) +
    pad(d.getMinutes()) +
    pad(d.getSeconds());
  return '未命名_' + stamp + DEFAULT_EXT;
}

/**
 * 清洗用户输入的文件名：去掉路径分隔符与控制字符并 trim；
 * 只剩 "." / ".." 或空时返回 ""（调用方视为非法）。
 */
export function sanitize(name: string | null): string {
  if (name == null) {
    return '';
  }
  let out: string = '';
  for (let i: number = 0; i < name.length; i++) {
    const c: string = name.charAt(i);
    const code: number = name.charCodeAt(i);
    if (c === '/' || c === '\\' || code === 0 || code < 0x20) {
      continue;
    }
    out += c;
  }
  out = out.trim();
  if (out === '.' || out === '..') {
    return '';
  }
  return out;
}

/** 文件名是否可用于保存。 */
export function isValid(name: string | null): boolean {
  return sanitize(name).length > 0;
}

/** 目标文件是否已存在（存在则由 UI 提示覆盖/换名，绝不静默覆盖）。 */
export function exists(
  dirPath: string,
  name: string,
  isFile: (fullPath: string) => boolean
): boolean {
  return isFile(joinPath(dirPath, sanitize(name)));
}

/** 用户没写扩展名时补 .txt（以点开头的隐藏文件视为无扩展名，同样补）。 */
export function ensureTxtExtension(name: string | null): string {
  const s: string = sanitize(name);
  if (s.length === 0) {
    return '';
  }
  const dot: number = s.lastIndexOf('.');
  if (dot <= 0) {
    return s + DEFAULT_EXT;
  }
  return s;
}

/** 目录是否可写（保存对话框展示前校验，不可用则回退到目录选择）。 */
export function isWritableDir(isDirectory: boolean, canWrite: boolean): boolean {
  return isDirectory && canWrite;
}

/** 拼接目录与文件名（分隔符统一用 '/'）。 */
export function joinPath(dir: string, name: string): string {
  if (dir.length === 0) {
    return name;
  }
  const sep: string = dir.charAt(dir.length - 1) === '/' ? '' : '/';
  return dir + sep + name;
}

/** 取路径的父目录；无分隔符时返回 ""。 */
export function parentOf(path: string | null): string {
  if (path == null) {
    return '';
  }
  const i: number = path.lastIndexOf('/');
  return i > 0 ? path.substring(0, i) : '';
}
