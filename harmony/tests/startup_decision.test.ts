/** StartupDecision 单测：与安卓版 StartupDecisionTest 对应（用真实临时目录建快照）。 */
import { promises as fsp } from 'node:fs';
import * as nodeOs from 'node:os';
import * as nodePath from 'node:path';
import { decide, MODE_NEW_EMPTY, MODE_LAST_FILE, MODE_LAST_DIR } from './.tmp_core/StartupDecision.ts';
import { test, equal, type Suite } from './assert.ts';

export async function run(suite: Suite): Promise<void> {
  const root: string = await fsp.mkdtemp(nodePath.join(nodeOs.tmpdir(), 'paper-startup-'));
  const file: string = nodePath.join(root, 'note.txt');
  await fsp.writeFile(file, 'hi');
  const dir: string = nodePath.join(root, 'docs');
  await fsp.mkdir(dir);

  // decide() 是同步纯函数；用“存在性快照”注入（单测内文件集稳定）。
  const files: Set<string> = new Set<string>([file]);
  const dirs: Set<string> = new Set<string>([root, dir]);
  const isFile: (p: string) => boolean = (p: string): boolean => files.has(p);
  const isDirectory: (p: string) => boolean = (p: string): boolean => dirs.has(p);

  await test(suite, 'newEmptyAlwaysStartsScratch', () => {
    equal(decide(MODE_NEW_EMPTY, file, false, dir, isFile, isDirectory), 'scratch');
  });
  await test(suite, 'lastFileOpensExistingFile', () => {
    equal(decide(MODE_LAST_FILE, file, false, dir, isFile, isDirectory), 'openFile');
  });
  await test(suite, 'lastFileScratchFallsBackToDirectory', () => {
    equal(decide(MODE_LAST_FILE, file, true, dir, isFile, isDirectory), 'browser');
  });
  await test(suite, 'lastFileScratchNeverOpensPreviousPath', () => {
    // 即使文件真实存在，草稿标记也必须压倒它
    equal(decide(MODE_LAST_FILE, file, true, dir, () => true, isDirectory), 'browser');
  });
  await test(suite, 'lastFileScratchWithoutDirectoryOpensScratch', () => {
    equal(decide(MODE_LAST_FILE, file, true, '', isFile, isDirectory), 'scratch');
  });
  await test(suite, 'missingLastFileFallsBackToDirectory', () => {
    equal(
      decide(MODE_LAST_FILE, nodePath.join(root, 'gone.txt'), false, dir, isFile, isDirectory),
      'browser'
    );
  });
  await test(suite, 'missingEverythingOpensScratch', () => {
    equal(decide(MODE_LAST_FILE, '', false, '', isFile, isDirectory), 'scratch');
  });
  await test(suite, 'lastDirOpensBrowser', () => {
    equal(decide(MODE_LAST_DIR, file, false, dir, isFile, isDirectory), 'browser');
  });
  await test(suite, 'lastDirScratchAlsoOpensBrowser', () => {
    equal(decide(MODE_LAST_DIR, '', true, dir, isFile, isDirectory), 'browser');
  });
  await test(suite, 'lastDirMissingOpensScratch', () => {
    equal(
      decide(MODE_LAST_DIR, '', false, nodePath.join(root, 'gone'), isFile, isDirectory),
      'scratch'
    );
  });
  await test(suite, 'unknownModeFallsBackToScratch', () => {
    equal(decide('NOPE', file, false, dir, isFile, isDirectory), 'scratch');
    equal(decide(null, file, false, dir, isFile, isDirectory), 'scratch');
  });
  await test(suite, 'filePathPointingToDirectoryIsNotOpened', () => {
    equal(decide(MODE_LAST_FILE, dir, false, dir, isFile, isDirectory), 'browser');
  });

  await fsp.rm(root, { recursive: true, force: true });
}

export function suiteName(): string {
  return 'StartupDecision';
}
