/**
 * 防崩溃原子写入（对应安卓版 core/AtomicFileWriter.java）。
 *
 * 流程：写 path.tmp → 落盘 → 已有文件则复制为 path.bak → rename(tmp → path)。
 * 任何时刻崩溃，磁盘上都是“完整旧文件”或“完整新文件”之一，
 * .bak 恒为上一版本（等效“始终有 2 份”）。
 *
 * 文件系统操作以 AtomicFs 接口注入：
 * - 鸿蒙侧由 model/FileService.ets 用 @kit.CoreFileKit 的 fs 实现；
 * - Node 单测用 node:fs 实现（见 harmony/tests/），覆盖与安卓版
 *   AtomicFileWriterTest 相同的行为（含写失败不损坏原文件）。
 *
 * 全部异步（Promise），因为鸿蒙 fs 只有异步 API。
 */

export const TMP_SUFFIX: string = '.tmp';
export const BAK_SUFFIX: string = '.bak';

export interface AtomicFs {
  /** 确保 path 的父目录存在（不存在则递归创建）。 */
  ensureParentDir(path: string): Promise<void>;
  /** 原子地写一个新文件（覆盖已有同名文件）。 */
  writeFile(path: string, data: Uint8Array): Promise<void>;
  /** 读整个文件；文件大于 maxBytes 时抛错（调用方先用分层策略限流）。 */
  readFile(path: string, maxBytes: number): Promise<Uint8Array>;
  /** 只读文件前 maxBytes 字节（头部预览/嗅探用）。 */
  readHead(path: string, maxBytes: number): Promise<Uint8Array>;
  /** 复制文件（覆盖目标）。 */
  copyFile(src: string, dst: string): Promise<void>;
  /** 重命名/移动（允许抛错，调用方会回退到复制+删除）。 */
  rename(src: string, dst: string): Promise<void>;
  /** 删除单个文件；不存在时视为成功。 */
  remove(path: string): Promise<void>;
  /** 路径是否是一个已存在的*文件*。 */
  isFile(path: string): Promise<boolean>;
}

export function tmpFor(target: string): string {
  return target + TMP_SUFFIX;
}

export function bakFor(target: string): string {
  return target + BAK_SUFFIX;
}

/** 原子写入：保留上一版为 .bak；失败时清理 .tmp 并原样抛错。 */
export async function write(fs: AtomicFs, target: string, data: Uint8Array): Promise<void> {
  await fs.ensureParentDir(target);
  const tmp: string = tmpFor(target);
  try {
    await fs.writeFile(tmp, data);
    if (await fs.isFile(target)) {
      await fs.copyFile(target, bakFor(target));
    }
    try {
      await fs.rename(tmp, target);
    } catch (renameErr) {
      // 非原子回退：复制覆盖后再删 tmp，.bak 仍在。
      await fs.copyFile(tmp, target);
      await fs.remove(tmp);
    }
  } catch (e) {
    try {
      await fs.remove(tmp);
    } catch (ignored) {
      // 清理失败不掩盖原始错误
    }
    throw e;
  }
}

/** 用 .bak 恢复目标文件；无备份返回 false。 */
export async function restoreFromBackup(fs: AtomicFs, target: string): Promise<boolean> {
  if (!(await fs.isFile(bakFor(target)))) {
    return false;
  }
  await fs.copyFile(bakFor(target), target);
  return true;
}

/** .bak 是否存在。 */
export async function backupExists(fs: AtomicFs, target: string): Promise<boolean> {
  return await fs.isFile(bakFor(target));
}
