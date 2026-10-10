/**
 * 体积/二进制分层（对应安卓版 core/FileSizePolicy.java，阈值与文案逐字对齐）。
 *
 * 任何文件的打开都走这一层判定，保证大文件/二进制永远进只读预览，
 * 界面不卡不崩（DESIGN.md §8）。数值直接沿用安卓版：
 * 可编辑 ≤5MB，只读 ≤100MB，超大只读前 10MB。
 */

/** 可编辑上限 5MB。 */
export const EDIT_LIMIT: number = 5 * 1024 * 1024;
/** 只读完整加载上限 100MB。 */
export const FULL_VIEW_LIMIT: number = 100 * 1024 * 1024;
/** 头部预览读取上限 10MB。 */
export const HEAD_LIMIT: number = 10 * 1024 * 1024;

/** editable=可编辑，readonly=只读全量，head=仅头部预览。 */
export type Tier = 'editable' | 'readonly' | 'head';

export function tierFor(sizeBytes: number, binary: boolean): Tier {
  if (binary) {
    return 'readonly';
  }
  if (sizeBytes <= EDIT_LIMIT) {
    return 'editable';
  }
  if (sizeBytes <= FULL_VIEW_LIMIT) {
    return 'readonly';
  }
  return 'head';
}

/** 该分层最多允许读多少字节。 */
export function readLimit(tier: Tier, sizeBytes: number): number {
  if (tier === 'head') {
    return Math.min(sizeBytes, HEAD_LIMIT);
  }
  if (tier === 'readonly') {
    return Math.min(sizeBytes, FULL_VIEW_LIMIT);
  }
  return sizeBytes;
}

/** 该分层是否允许保存回原文件。 */
export function allowsSave(tier: Tier): boolean {
  return tier === 'editable';
}

/** 禁用保存时横幅里给用户看的原因；可保存时返回 null。 */
export function readOnlyReason(tier: Tier, binary: boolean): string | null {
  if (binary) {
    return '检测到二进制内容：只读模式，保存已禁用';
  }
  if (tier === 'head') {
    return '超大文件：仅显示前 ' + HEAD_LIMIT / (1024 * 1024) + ' MB，只读，保存已禁用';
  }
  if (tier === 'readonly') {
    return '大文件：只读模式，保存已禁用';
  }
  return null;
}
