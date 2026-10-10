/** 页面/服务间共享的轻量类型（对应安卓版各 Activity 内的状态定义）。 */

/** 编辑器模式：scratch=无路径草稿，file=真实文件/持久 URI，uri=分享进来的临时内容。 */
export type EditorMode = 'scratch' | 'file' | 'uri';

/** 浏览器排序字段：名称 / 大小 / 时间 / 类型（与安卓版 browserSort 键一致）。 */
export type SortField = 'name' | 'size' | 'date' | 'type';

/** 浏览器一行：目录常排在文件前面，组内再按字段/方向排（见 Browser 页）。 */
export interface BrowserRow {
  name: string;
  isDir: boolean;
  size: number;
  mtimeMs: number;
}

/** 文件 stat 结果（含可写性近似判定，见 FileService 注释）。 */
export interface StatInfo {
  size: number;
  mtimeMs: number;
  isDirectory: boolean;
  isFile: boolean;
  canWrite: boolean;
}
