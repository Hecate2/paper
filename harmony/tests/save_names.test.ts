/** SaveNames 单测：与安卓版 SaveNamesTest 对应。 */
import {
  DEFAULT_EXT, defaultFileName, sanitize, isValid, exists,
  ensureTxtExtension, isWritableDir, joinPath, parentOf
} from './.tmp_core/SaveNames.ts';
import { test, equal, isTrue, isFalse, matches, type Suite } from './assert.ts';

export async function run(suite: Suite): Promise<void> {
  await test(suite, 'defaultNameHasTxtExtensionAndTimestamp', () => {
    const name: string = defaultFileName(1700000000000);
    matches(name, /^未命名_\d{8}_\d{6}\.txt$/);
    equal(DEFAULT_EXT, '.txt');
  });
  await test(suite, 'sanitizeStripsPathSeparators', () => {
    equal(sanitize('a/b\\c'), 'abc');
  });
  await test(suite, 'sanitizeRemovesControlChars', () => {
    equal(sanitize('ab'), 'ab');
    equal(sanitize('  name.txt  '), 'name.txt');
  });
  await test(suite, 'sanitizeHandlesEdgeCases', () => {
    equal(sanitize(null), '');
    equal(sanitize(''), '');
    equal(sanitize('.'), '');
    equal(sanitize('..'), '');
    equal(sanitize('   '), '');
  });
  await test(suite, 'isValidMirrorsSanitize', () => {
    isTrue(isValid('note.txt'));
    isFalse(isValid(null));
    isFalse(isValid('..'));
    isFalse(isValid('  '));
  });
  await test(suite, 'ensureTxtExtensionAddsWhenMissing', () => {
    equal(ensureTxtExtension('note'), 'note.txt');
    equal(ensureTxtExtension('note.md'), 'note.md');
    equal(ensureTxtExtension(''), '');
    equal(ensureTxtExtension(null), '');
  });
  await test(suite, 'existsChecksDirectory', () => {
    const files: string[] = ['/d/a.txt'];
    const isFile: (p: string) => boolean = (p: string): boolean => files.indexOf(p) >= 0;
    isTrue(exists('/d', 'a.txt', isFile));
    isFalse(exists('/d', 'b.txt', isFile));
  });
  await test(suite, 'writableChecks', () => {
    isTrue(isWritableDir(true, true));
    isFalse(isWritableDir(false, true));
    isFalse(isWritableDir(true, false));
    isFalse(isWritableDir(false, false));
  });
  await test(suite, 'pathHelpers', () => {
    equal(joinPath('/a/b', 'c.txt'), '/a/b/c.txt');
    equal(joinPath('', 'c.txt'), 'c.txt');
    equal(parentOf('/a/b/c.txt'), '/a/b');
    equal(parentOf('c.txt'), '');
    equal(parentOf(null), '');
  });
}

export function suiteName(): string {
  return 'SaveNames';
}
