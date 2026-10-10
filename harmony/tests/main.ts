import { createSuite, type Suite } from './assert.ts';
import { run as runSearch } from './search_engine.test.ts';
import { run as runEncoding } from './encoding_detector.test.ts';
import { run as runPolicy } from './file_size_policy.test.ts';
import { run as runNames } from './save_names.test.ts';
import { run as runStartup } from './startup_decision.test.ts';
import { run as runAtomic } from './atomic_file_ops.test.ts';

async function main(): Promise<void> {
  const suite: Suite = createSuite();
  const t0: number = Date.now();
  await runSearch(suite);
  await runEncoding(suite);
  await runPolicy(suite);
  await runNames(suite);
  await runStartup(suite);
  await runAtomic(suite);
  const ms: number = Date.now() - t0;
  console.log('----------------------------------------');
  console.log('total=' + suite.total + ' passed=' + suite.passed + ' failed=' + suite.failed +
    ' (' + ms + 'ms)');
  if (suite.failed > 0) {
    console.log('failures:');
    for (const f of suite.failures) {
      console.log('  - ' + f);
    }
    process.exitCode = 1;
  }
}

main();
