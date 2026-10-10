/** AtomicFileOps 单测：与安卓版 AtomicFileWriterTest 行为对应（node:fs 实现 AtomicFs）。 */
import { promises as fsp } from 'node:fs';
import * as nodeOs from 'node:os';
import * as nodePath from 'node:path';
import {
  TMP_SUFFIX, BAK_SUFFIX, tmpFor, bakFor,
  write, restoreFromBackup, backupExists,
  type AtomicFs
} from './.tmp_core/AtomicFileOps.ts';
import { test, equal, arrayEqual, isTrue, isFalse, type Suite } from './assert.ts';

class NodeAtomicFs implements AtomicFs {
  async ensureParentDir(path: string): Promise<void> {
    await fsp.mkdir(nodePath.dirname(path), { recursive: true });
  }
  async writeFile(path: string, data: Uint8Array): Promise<void> {
    const handle = await fsp.open(path, 'w');
    try {
      await handle.writeFile(data);
      await handle.sync(); // 对应安卓版 out.getFD().sync()
    } finally {
      await handle.close();
    }
  }
  async readFile(path: string, maxBytes: number): Promise<Uint8Array> {
    const st = await fsp.stat(path);
    if (st.size > maxBytes) {
      throw new Error('File too large: ' + st.size + ' > ' + maxBytes);
    }
    return new Uint8Array(await fsp.readFile(path));
  }
  async readHead(path: string, maxBytes: number): Promise<Uint8Array> {
    const handle = await fsp.open(path, 'r');
    try {
      const st = await handle.stat();
      const n: number = Math.min(st.size, maxBytes);
      const buf: Uint8Array = new Uint8Array(n);
      await handle.read(buf, 0, n, 0);
      return buf;
    } finally {
      await handle.close();
    }
  }
  async copyFile(src: string, dst: string): Promise<void> {
    await fsp.copyFile(src, dst);
  }
  async rename(src: string, dst: string): Promise<void> {
    await fsp.rename(src, dst);
  }
  async remove(path: string): Promise<void> {
    await fsp.rm(path, { recursive: true, force: true });
  }
  async isFile(path: string): Promise<boolean> {
    try {
      return (await fsp.stat(path)).isFile();
    } catch (e) {
      return false;
    }
  }
}

function bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

async function readText(fs: AtomicFs, f: string): Promise<string> {
  return new TextDecoder().decode(await fs.readFile(f, Number.MAX_SAFE_INTEGER));
}

export async function run(suite: Suite): Promise<void> {
  const root: string = await fsp.mkdtemp(nodePath.join(nodeOs.tmpdir(), 'paper-atomic-'));
  const fs: AtomicFs = new NodeAtomicFs();
  const target: string = nodePath.join(root, 'note.txt');

  await test(suite, 'writesNewFile', async () => {
    await write(fs, target, bytes('hello'));
    isTrue(await fs.isFile(target));
    equal(await readText(fs, target), 'hello');
    isFalse(await fs.isFile(tmpFor(target)));
    isFalse(await backupExists(fs, target));
    equal(TMP_SUFFIX, '.tmp');
    equal(BAK_SUFFIX, '.bak');
  });
  await test(suite, 'secondWriteKeepsBackupOfPreviousVersion', async () => {
    await write(fs, target, bytes('v1'));
    await write(fs, target, bytes('v2'));
    equal(await readText(fs, target), 'v2');
    isTrue(await fs.isFile(bakFor(target)));
    equal(await readText(fs, bakFor(target)), 'v1');
  });
  await test(suite, 'thirdWriteOverwritesBackup', async () => {
    await write(fs, target, bytes('v1'));
    await write(fs, target, bytes('v2'));
    await write(fs, target, bytes('v3'));
    equal(await readText(fs, target), 'v3');
    equal(await readText(fs, bakFor(target)), 'v2');
  });
  await test(suite, 'restoresFromBackup', async () => {
    await write(fs, target, bytes('good'));
    await write(fs, target, bytes('bad'));
    equal(await restoreFromBackup(fs, target), true);
    equal(await readText(fs, target), 'good');
  });
  await test(suite, 'restoreWithoutBackupReturnsFalse', async () => {
    const fresh: string = nodePath.join(root, 'fresh.txt');
    await write(fs, fresh, bytes('x'));
    await fs.remove(bakFor(fresh));
    equal(await restoreFromBackup(fs, fresh), false);
  });
  await test(suite, 'failedWriteLeavesOriginalIntact', async () => {
    await write(fs, target, bytes('original'));
    // 破坏：把 .tmp 路径建成目录，后续写 tmp 必失败（对应安卓版 sabotage.mkdirs()）
    await fsp.mkdir(tmpFor(target), { recursive: true });
    let threw: boolean = false;
    try {
      await write(fs, target, bytes('new content'));
    } catch (e) {
      threw = true;
    }
    isTrue(threw);
    equal(await readText(fs, target), 'original');
    isFalse(await fs.isFile(tmpFor(target)));
  });
  await test(suite, 'writesIntoNestedNewDirectory', async () => {
    const nested: string = nodePath.join(root, 'a', 'b', 'c', 'file.txt');
    await write(fs, nested, bytes('deep'));
    isTrue(await fs.isFile(nested));
    equal(await readText(fs, nested), 'deep');
  });
  await test(suite, 'readAtMostRefusesTooLargeFile', async () => {
    await write(fs, target, bytes('0123456789'));
    let threw: boolean = false;
    try {
      await fs.readFile(target, 5);
    } catch (e) {
      threw = true;
    }
    isTrue(threw);
  });
  await test(suite, 'readHeadTruncates', async () => {
    await write(fs, target, bytes('0123456789'));
    const head: Uint8Array = await fs.readHead(target, 4);
    arrayEqual(head, bytes('0123'));
  });
  await test(suite, 'readAtMostHandlesEmptyFile', async () => {
    const empty: string = nodePath.join(root, 'empty.txt');
    await write(fs, empty, new Uint8Array(0));
    equal((await fs.readFile(empty, 100)).length, 0);
  });
  await test(suite, 'binaryContentSurvivesRoundTrip', async () => {
    const data: Uint8Array = Uint8Array.from([0, 1, 2, 3, 255, 254, 0, 42]);
    await write(fs, target, data);
    arrayEqual(await fs.readFile(target, Number.MAX_SAFE_INTEGER), data);
  });
  await test(suite, 'sequentialWritesAlwaysExposeCompleteVersions', async () => {
    await write(fs, target, bytes('v0'));
    const versions: string[] = ['aaaa', 'bbbbbb', 'ccccccccc', 'dddddddddd'];
    for (const v of versions) {
      await write(fs, target, bytes(v));
      equal(await readText(fs, target), v);
    }
  });
  await test(suite, 'copyFileCopiesContent', async () => {
    const src: string = nodePath.join(root, 'src.bin');
    const dst: string = nodePath.join(root, 'dst.bin');
    await write(fs, src, bytes('copy me'));
    await fs.copyFile(src, dst);
    equal(await readText(fs, dst), 'copy me');
  });

  await fsp.rm(root, { recursive: true, force: true });
}

export function suiteName(): string {
  return 'AtomicFileOps';
}
