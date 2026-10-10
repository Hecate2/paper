/**
 * 冷启动路由决策（对应安卓版 core/StartupDecision.java，规则见 DESIGN.md §3.2）。
 *
 * - NEW_EMPTY → 空草稿
 * - LAST_FILE → 上次文件（非草稿且存在）否则回退浏览器（目录存在）否则空草稿
 * - LAST_DIR → 上次目录（存在则进浏览器）否则空草稿
 * - 草稿退出即弃：上次是未保存草稿永远回到空编辑器
 *
 * 是否存在以回调注入（安卓用 java.io.File，鸿蒙侧用 fs/stat 包装），
 * 保持纯函数可单测。
 */

export const MODE_NEW_EMPTY: string = 'NEW_EMPTY';
export const MODE_LAST_FILE: string = 'LAST_FILE';
export const MODE_LAST_DIR: string = 'LAST_DIR';

/** scratch=空草稿，openFile=打开上次文件，browser=进目录浏览器。 */
export type Target = 'scratch' | 'openFile' | 'browser';

export function decide(
  startupMode: string | null,
  lastFilePath: string | null,
  lastIsScratch: boolean,
  lastDirectory: string | null,
  isFile: (path: string) => boolean,
  isDirectory: (path: string) => boolean
): Target {
  if (MODE_LAST_FILE === startupMode) {
    if (
      !lastIsScratch &&
      lastFilePath != null &&
      lastFilePath.length > 0 &&
      isFile(lastFilePath)
    ) {
      return 'openFile';
    }
    if (lastDirectory != null && lastDirectory.length > 0 && isDirectory(lastDirectory)) {
      return 'browser';
    }
    return 'scratch';
  }
  if (MODE_LAST_DIR === startupMode) {
    if (lastDirectory != null && lastDirectory.length > 0 && isDirectory(lastDirectory)) {
      return 'browser';
    }
    return 'scratch';
  }
  // NEW_EMPTY 与一切未知取值
  return 'scratch';
}
