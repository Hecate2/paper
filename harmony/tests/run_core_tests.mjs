#!/usr/bin/env node
/** core 单测入口：把 core/*.ets 拷为 .ts（Node 22 类型剥离可直接执行），再跑 main.ts。 */
import { cpSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import * as nodePath from 'node:path';
import { fileURLToPath } from 'node:url';

const here = nodePath.dirname(fileURLToPath(import.meta.url));
const coreDir = nodePath.join(here, '..', 'entry', 'src', 'main', 'ets', 'core');
const tmpDir = nodePath.join(here, '.tmp_core');

rmSync(tmpDir, { recursive: true, force: true });
mkdirSync(tmpDir, { recursive: true });
for (const f of ['SearchEngine.ets', 'EncodingDetector.ets', 'FileSizePolicy.ets',
  'SaveNames.ets', 'StartupDecision.ets', 'AtomicFileOps.ets']) {
  const src = nodePath.join(coreDir, f);
  if (!existsSync(src)) {
    console.error('missing core file: ' + src);
    process.exit(1);
  }
  cpSync(src, nodePath.join(tmpDir, f.replace(/\.ets$/, '.ts')));
}

const r = spawnSync(process.execPath, [nodePath.join(here, 'main.ts')], { stdio: 'inherit' });
rmSync(tmpDir, { recursive: true, force: true });
process.exit(r.status ?? 1);
