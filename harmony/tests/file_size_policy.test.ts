/** FileSizePolicy 单测：与安卓版 FileSizePolicyTest 对应（阈值逐字对齐）。 */
import {
  EDIT_LIMIT, FULL_VIEW_LIMIT, HEAD_LIMIT,
  tierFor, readLimit, allowsSave, readOnlyReason
} from './.tmp_core/FileSizePolicy.ts';
import { test, equal, isTrue, isFalse, type Suite } from './assert.ts';

const MB: number = 1024 * 1024;

export async function run(suite: Suite): Promise<void> {
  await test(suite, 'smallFileIsEditable', () => {
    equal(tierFor(0, false), 'editable');
    equal(tierFor(EDIT_LIMIT, false), 'editable');
    equal(tierFor(5 * MB, false), 'editable');
  });
  await test(suite, 'mediumFileIsReadonly', () => {
    equal(tierFor(5 * MB + 1, false), 'readonly');
    equal(tierFor(100 * MB, false), 'readonly');
  });
  await test(suite, 'hugeFileGetsHeadPreview', () => {
    equal(tierFor(100 * MB + 1, false), 'head');
    equal(tierFor(1024 * MB, false), 'head');
  });
  await test(suite, 'binaryAlwaysReadonly', () => {
    equal(tierFor(10, true), 'readonly');
    equal(tierFor(1024 * MB, true), 'readonly');
  });
  await test(suite, 'readLimits', () => {
    equal(readLimit('editable', 1234), 1234);
    equal(readLimit('readonly', 200 * MB), FULL_VIEW_LIMIT);
    equal(readLimit('readonly', 50 * MB), 50 * MB);
    equal(readLimit('head', 500 * MB), HEAD_LIMIT);
    equal(readLimit('head', 5 * MB), 5 * MB);
  });
  await test(suite, 'onlyEditableAllowsSave', () => {
    isTrue(allowsSave('editable'));
    isFalse(allowsSave('readonly'));
    isFalse(allowsSave('head'));
  });
  await test(suite, 'readOnlyReasons', () => {
    equal(readOnlyReason('editable', false), null);
    isTrue((readOnlyReason('readonly', false) as string).length > 0);
    isTrue((readOnlyReason('head', false) as string).indexOf('10') >= 0);
    isTrue((readOnlyReason('editable', true) as string).indexOf('二进制') >= 0);
  });
}

export function suiteName(): string {
  return 'FileSizePolicy';
}
