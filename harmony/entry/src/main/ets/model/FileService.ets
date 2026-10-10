import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { fileShare } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { AtomicFs } from '../core/AtomicFileOps.ets';
import type { BrowserRow, StatInfo } from './Types.ets';
import { parentOf } from '../core/SaveNames.ets';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PaperFileService';
const CHUNK: number = 64 * 1024;

/**
 * 文件服务：沙箱路径 + Picker URI 的统一读写。
 *
 * 背景（见 harmony/README.md）：鸿蒙 NEXT 没有“所有文件访问”权限，
 * 应用只能读写沙箱；用户文件走系统 Picker（select/save）拿到带临时
 * 授权的 URI。持久化授权（fileShare）尽力获取，失败不阻塞流程。
 *
 * FsAtomic 实现了 core/AtomicFileOps 的 AtomicFs 接口，
 * 因此原子写/.bak/恢复备份与安卓版走同一套逻辑。
 */
export class FileService {
  private ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /** 应用沙箱 files 目录（浏览器默认根 + 草稿/备份落点）。 */
  filesDir(): string {
    try {
      return this.ctx.filesDir;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'filesDir failed: %{public}s', String(e));
      return '';
    }
  }

  atomic(): AtomicFs {
    return new FsAtomic();
  }

  async statInfo(path: string): Promise<StatInfo | null> {
    try {
      const st = await fs.stat(path);
      const isDir: boolean = st.isDirectory();
      const isF: boolean = st.isFile();
      return {
        size: st.size,
        mtimeMs: normalizeMtime(st.mtime),
        isDirectory: isDir,
        isFile: isF,
        canWrite: isDir || isF // 沙箱内存在即认为可写；见 canWriteDir
      };
    } catch (e) {
      return null;
    }
  }

  async isFile(path: string): Promise<boolean> {
    const st: StatInfo | null = await this.statInfo(path);
    return st !== null && st.isFile;
  }

  async isDirectory(path: string): Promise<boolean> {
    const st: StatInfo | null = await this.statInfo(path);
    return st !== null && st.isDirectory;
  }

  /** 目录是否可用作保存目标（存在且为目录；沙箱内即视为可写）。 */
  async canWriteDir(path: string): Promise<boolean> {
    return await this.isDirectory(path);
  }

  /** 列举一层目录（不递归），每项带 size/mtime；单项失败时降级展示。 */
  async listDir(dir: string): Promise<BrowserRow[]> {
    const rows: BrowserRow[] = [];
    let names: string[];
    try {
      names = await fs.listFile(dir);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listFile failed: %{public}s', String(e));
      return rows;
    }
    for (const name of names) {
      const full: string = joinPath(dir, name);
      try {
        const st = await fs.stat(full);
        rows.push({
          name: name,
          isDir: st.isDirectory(),
          size: st.isDirectory() ? 0 : st.size,
          mtimeMs: normalizeMtime(st.mtime)
        });
      } catch (e) {
        rows.push({ name: name, isDir: false, size: 0, mtimeMs: 0 });
      }
    }
    return rows;
  }

  /** 读整个文件；大于 maxBytes 抛错（调用方先用 FileSizePolicy 限流）。 */
  async readBytes(path: string, maxBytes: number): Promise<Uint8Array> {
    const st = await fs.stat(path);
    if (st.size > maxBytes) {
      throw new Error('File too large: ' + st.size + ' > ' + maxBytes);
    }
    return await this.readRange(path, 0, st.size);
  }

  /** 只读 [offset, offset+length)（头部预览/嗅探用）。 */
  async readRange(path: string, offset: number, length: number): Promise<Uint8Array> {
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const chunks: Uint8Array[] = [];
      let pos: number = offset;
      let remaining: number = length;
      while (remaining > 0) {
        const n: number = Math.min(remaining, CHUNK);
        const ab: ArrayBuffer = new ArrayBuffer(n);
        const got: number = await fs.read(file.fd, ab, { offset: pos, length: n });
        if (got <= 0) {
          break;
        }
        chunks.push(new Uint8Array(ab, 0, got));
        pos += got;
        remaining -= got;
      }
      return concatBytes(chunks);
    } finally {
      try {
        await fs.close(file.fd);
      } catch (e) {
        // ignore
      }
    }
  }

  /** 打开系统文件选择器（任意文件，不限后缀，对应安卓“打开”）。 */
  async pickOpen(): Promise<string[]> {
    const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.ctx);
    return await p.select({ maxSelectNumber: 1 });
  }

  /** 打开系统保存面板，返回用户确认的 URI（对应安卓“保存/另存为”选目录）。 */
  async pickSave(suggestName: string): Promise<string[]> {
    const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.ctx);
    return await p.save({ newFileNames: [suggestName] });
  }

  /** 沙箱内重命名（.bak 联动改名；目标已存在时抛错，由调用方先判重名）。 */
  async renameFile(src: string, dst: string): Promise<void> {
    await fs.rename(src, dst);
    try {
      await fs.rename(src + '.bak', dst + '.bak');
    } catch (e) {
      // 无备份时忽略
    }
  }

  /** 尽力为 Picker URI 申请持久化授权（记住上次打开的文件用），失败返回 false。 */
  async persistPermission(uri: string): Promise<boolean> {
    try {
      await fileShare.persistPermission([
        { uri: uri, operationMode: fileShare.OperationMode.READ_MODE }
      ]);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persistPermission failed: %{public}s', String(e));
      return false;
    }
  }

  /** 写字节到 Picker 返回的 URI（覆盖；TRUNC 防止新内容比旧内容短时留下尾部残字节）。 */
  async writeUri(uri: string, data: Uint8Array): Promise<void> {
    const file = await fs.open(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let off: number = 0;
      while (off < data.length) {
        const ab: ArrayBuffer = copyToBuffer(data, off, Math.min(off + CHUNK, data.length));
        const w: number = await fs.write(file.fd, ab);
        if (w <= 0) {
          throw new Error('write returned 0');
        }
        off += w;
      }
      try {
        await fs.fsync(file.fd);
      } catch (e) {
        // 部分 URI 不支持 fsync，忽略
      }
    } finally {
      try {
        await fs.close(file.fd);
      } catch (e) {
        // ignore
      }
    }
  }
}

/** core.AtomicFs 的 fs 实现（沙箱路径用；Picker URI 走 writeUri）。 */
class FsAtomic implements AtomicFs {
  async ensureParentDir(path: string): Promise<void> {
    await mkdirRecursive(parentOf(path));
  }

  async writeFile(path: string, data: Uint8Array): Promise<void> {
    try {
      await fs.unlink(path);
    } catch (e) {
      // 不存在则无需删除
    }
    const file = await fs.open(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE);
    try {
      let off: number = 0;
      while (off < data.length) {
        const ab: ArrayBuffer = copyToBuffer(data, off, Math.min(off + CHUNK, data.length));
        const w: number = await fs.write(file.fd, ab);
        if (w <= 0) {
          throw new Error('write returned 0');
        }
        off += w;
      }
      try {
        await fs.fsync(file.fd);
      } catch (e) {
        // fsync 不可用时忽略（与安卓 getFD().sync() 尽力语义一致）
      }
    } finally {
      await fs.close(file.fd);
    }
  }

  async readFile(path: string, maxBytes: number): Promise<Uint8Array> {
    const st = await fs.stat(path);
    if (st.size > maxBytes) {
      throw new Error('File too large: ' + st.size + ' > ' + maxBytes);
    }
    return await readRangeFd(path, 0, st.size);
  }

  async readHead(path: string, maxBytes: number): Promise<Uint8Array> {
    const st = await fs.stat(path);
    return await readRangeFd(path, 0, Math.min(st.size, maxBytes));
  }

  async copyFile(src: string, dst: string): Promise<void> {
    try {
      await fs.unlink(dst);
    } catch (e) {
      // ignore
    }
    await fs.copyFile(src, dst);
  }

  async rename(src: string, dst: string): Promise<void> {
    // 同分区 rename 原子；若目标已存在导致失败，上层回退到复制+删除。
    await fs.rename(src, dst);
  }

  async remove(path: string): Promise<void> {
    try {
      await fs.unlink(path);
    } catch (e) {
      // 不存在视为成功
    }
  }

  async isFile(path: string): Promise<boolean> {
    try {
      return (await fs.stat(path)).isFile();
    } catch (e) {
      return false;
    }
  }
}

async function readRangeFd(path: string, offset: number, length: number): Promise<Uint8Array> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const chunks: Uint8Array[] = [];
    let pos: number = offset;
    let remaining: number = length;
    while (remaining > 0) {
      const n: number = Math.min(remaining, CHUNK);
      const ab: ArrayBuffer = new ArrayBuffer(n);
      const got: number = await fs.read(file.fd, ab, { offset: pos, length: n });
      if (got <= 0) {
        break;
      }
      chunks.push(new Uint8Array(ab, 0, got));
      pos += got;
      remaining -= got;
    }
    return concatBytes(chunks);
  } finally {
    try {
      await fs.close(file.fd);
    } catch (e) {
      // ignore
    }
  }
}

/** 递归建目录（新版 mkdir 只有单参，逐级建，存在即跳过）。 */
async function mkdirRecursive(dir: string): Promise<void> {
  if (dir === '' || dir === '/') {
    return;
  }
  const parts: string[] = dir.split('/');
  const absolute: boolean = dir.startsWith('/');
  let cur: string = '';
  for (const part of parts) {
    if (part === '') {
      continue;
    }
    cur = cur === '' ? (absolute ? '/' + part : part) : cur + '/' + part;
    try {
      await fs.mkdir(cur);
    } catch (e) {
      // 已存在或并发创建，忽略
    }
  }
}

/** 把 data[begin, end) 拷进一块新的 ArrayBuffer（fs.write 只要纯 ArrayBuffer）。 */
function copyToBuffer(data: Uint8Array, begin: number, end: number): ArrayBuffer {
  const ab: ArrayBuffer = new ArrayBuffer(end - begin);
  new Uint8Array(ab).set(data.slice(begin, end));
  return ab;
}

function concatBytes(chunks: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (const c of chunks) {
    total += c.length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let pos: number = 0;
  for (const c of chunks) {
    out.set(c, pos);
    pos += c.length;
  }
  return out;
}

/** fs.stat 的 mtime 可能是秒也可能是毫秒，统一成毫秒。 */
function normalizeMtime(mtime: number): number {
  return mtime < 100000000000 ? mtime * 1000 : mtime;
}

function joinPath(dir: string, name: string): string {
  if (dir === '') {
    return name;
  }
  return dir.charAt(dir.length - 1) === '/' ? dir + name : dir + '/' + name;
}
