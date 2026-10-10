/** SearchEngine 单测：与安卓版 SearchEngineTest 逐项对应。 */
import {
  findAll,
  replaceAllLiteral,
  replaceAllRegex,
  replaceRange,
  replaceCurrentRegex,
  MAX_RESULTS
} from './.tmp_core/SearchEngine.ts';
import { createSuite, test, equal, arrayEqual, isTrue, type Suite } from './assert.ts';

function countOccurrences(text: string, needle: string): number {
  let count: number = 0;
  let idx: number = text.indexOf(needle);
  while (idx >= 0) {
    count++;
    idx = text.indexOf(needle, idx + needle.length);
  }
  return count;
}

export async function run(suite: Suite): Promise<void> {
  await test(suite, 'findsAllPlainMatches', () => {
    arrayEqual(findAll('abc abc abc', 'abc', true, false), [0, 3, 4, 7, 8, 11]);
  });
  await test(suite, 'emptyQueryYieldsNothing', () => {
    arrayEqual(findAll('abc', '', true, false), []);
    arrayEqual(findAll('abc', null as unknown as string, true, false), []);
    arrayEqual(findAll(null as unknown as string, 'a', true, false), []);
  });
  await test(suite, 'noMatchYieldsNothing', () => {
    arrayEqual(findAll('hello', 'xyz', true, false), []);
  });
  await test(suite, 'caseSensitiveSearch', () => {
    equal(findAll('Abc aBc abC', 'abc', true, false).length, 0);
    equal(findAll('abc abc', 'abc', true, false).length / 2, 2);
  });
  await test(suite, 'caseInsensitiveSearchFindsAll', () => {
    arrayEqual(findAll('Abc aBc abC ABC', 'abc', false, false), [0, 3, 4, 7, 8, 11, 12, 15]);
  });
  await test(suite, 'unicodeCaseInsensitiveSearch', () => {
    equal(findAll('Äöü ÄÖÜ', 'äöü', false, false).length / 2, 2);
  });
  await test(suite, 'overlappingQueryTakesNonOverlappingMatches', () => {
    arrayEqual(findAll('aaa', 'aa', true, false), [0, 2]);
  });
  await test(suite, 'matchesAreSortedAndContiguous', () => {
    const r: number[] = findAll('xaxbxaxbxax', 'x', true, false);
    equal(r.length / 2, 6);
    for (let i: number = 1; i < r.length; i++) {
      isTrue(r[i] >= r[i - 1]);
    }
  });
  await test(suite, 'findsRegexMatches', () => {
    arrayEqual(findAll('a1 b22 c333', '[0-9]+', true, true), [1, 2, 4, 6, 8, 11]);
  });
  await test(suite, 'invalidRegexYieldsNothingInsteadOfThrowing', () => {
    arrayEqual(findAll('abc', '[unclosed', true, true), []);
  });
  await test(suite, 'zeroWidthRegexDoesNotLoopForever', () => {
    arrayEqual(findAll('abc', 'x*', true, true), []);
  });
  await test(suite, 'regexCaseInsensitive', () => {
    equal(findAll('Hello hello HELLO', 'hello', false, true).length / 2, 3);
  });
  await test(suite, 'dotallRegexMatchesAcrossNewlines', () => {
    arrayEqual(findAll('a\nb', 'a.b', true, true), [0, 3]);
  });
  await test(suite, 'replaceAllLiteral', () => {
    const out: string = replaceAllLiteral(
      'one two one two', findAll('one two one two', 'one', true, false), '1');
    equal(out, '1 two 1 two');
  });
  await test(suite, 'replaceAllLiteralWithEmptyMatchesReturnsOriginal', () => {
    equal(replaceAllLiteral('abc', [], 'x'), 'abc');
    equal(replaceAllLiteral('abc', null, 'x'), 'abc');
  });
  await test(suite, 'replaceAllLiteralLongerReplacement', () => {
    const text: string = 'a a a';
    equal(replaceAllLiteral(text, findAll(text, 'a', true, false), '###'), '### ### ###');
  });
  await test(suite, 'replaceAllLiteralShorterReplacement', () => {
    const text: string = 'xxx';
    equal(replaceAllLiteral(text, findAll(text, 'x', true, false), ''), '');
  });
  await test(suite, 'replaceAllRegexWithGroups', () => {
    equal(replaceAllRegex('John Smith', '(\\w+) (\\w+)', '$2 $1', true, false), 'Smith John');
  });
  await test(suite, 'replaceAllRegexKeepsUnmatchedText', () => {
    equal(replaceAllRegex('a1b2c', '[0-9]', '#', true, false), 'a#b#c');
  });
  await test(suite, 'replaceAllRegexInvalidPatternReturnsOriginal', () => {
    equal(replaceAllRegex('abc', '[bad', 'x', true, false), 'abc');
  });
  await test(suite, 'replaceRangeSingle', () => {
    equal(replaceRange('hello', 2, 4, 'XX'), 'heXXo');
    equal(replaceRange('hello', 2, 2, 'X'), 'heXllo');
  });
  await test(suite, 'replaceCurrentRegexExpandsGroups', () => {
    equal(replaceCurrentRegex('John Smith', '(\\w+) (\\w+)', 0, 10, '$2 $1', true, false),
      'Smith John');
  });
  await test(suite, 'replaceCurrentRegexFallsBackToLiteralWhenRangeNotAMatch', () => {
    equal(replaceCurrentRegex('hello world', 'world', 0, 3, 'X', true, false), 'Xlo world');
  });
  await test(suite, 'plainSearchIsFastOnLargeText', () => {
    let text: string = '';
    for (let i: number = 0; i < 100000; i++) {
      text += 'line ' + i + ' filler text\n';
    }
    const t0: number = Date.now();
    const r: number[] = findAll(text, 'line 99999', true, false);
    const ms: number = Date.now() - t0;
    isTrue(r.length >= 2);
    console.log('    (plainSearch 2MB: ' + ms + 'ms)');
  });
  await test(suite, 'replaceAllIsFastOnLargeText', () => {
    let text: string = '';
    for (let i: number = 0; i < 200000; i++) {
      text += 'foo bar ';
    }
    const t0: number = Date.now();
    const m: number[] = findAll(text, 'foo', true, false);
    equal(m.length / 2, 200000);
    const out: string = replaceAllLiteral(text, m, 'qux');
    equal(countOccurrences(out, 'foo'), 0);
    equal(countOccurrences(out, 'qux'), 200000);
    console.log('    (replaceAll 200k: ' + (Date.now() - t0) + 'ms)');
  });
  await test(suite, 'respectsResultCap', () => {
    let s: string = '';
    for (let i: number = 0; i < MAX_RESULTS + 100; i++) {
      s += 'a';
    }
    equal(findAll(s, 'a', true, false).length / 2, MAX_RESULTS);
  });
  await test(suite, 'cancelFlagStopsSearch', () => {
    let s: string = '';
    for (let i: number = 0; i < 500000; i++) {
      s += 'a';
    }
    equal(findAll(s, 'a', true, false, false, { cancelled: true }).length, 0);
  });
  await test(suite, 'wholeWordSkipsEmbeddedMatches', () => {
    const r: number[] = findAll('cat category cat', 'cat', true, false, true);
    equal(r.length, 4);
    equal(r[0], 0);
    equal(r[2], 13);
  });
  await test(suite, 'wholeWordMatchesAtStringEdges', () => {
    arrayEqual(findAll('cat', 'cat', true, false, true), [0, 3]);
  });
  await test(suite, 'wholeWordTreatsUnderscoreAndDigitsAsWordChars', () => {
    equal(findAll('cat_x cat1', 'cat', true, false, true).length, 0);
    equal(findAll('cat_x cat1', 'cat', true, false, false).length, 4);
  });
  await test(suite, 'wholeWordCaseInsensitive', () => {
    const r: number[] = findAll('Cat cat CATS', 'cat', false, false, true);
    equal(r.length, 4);
    equal(r[0], 0);
    equal(r[2], 4);
  });
  await test(suite, 'wholeWordWorksForCjkText', () => {
    const r: number[] = findAll('中文 中文测试 中文', '中文', true, false, true);
    equal(r.length, 4);
    equal(r[0], 0);
    equal(r[2], 8);
  });
  await test(suite, 'wholeWordRegexUsesBoundariesButKeepsGroups', () => {
    const r: number[] = findAll('abc abcd abc', 'ab.', true, true, true);
    equal(r.length, 4);
    equal(r[0], 0);
    equal(r[2], 9);
    equal(replaceAllRegex('abc abcd abc', '(ab.)', '<$1>', true, true), '<abc> abcd <abc>');
  });
  await test(suite, 'wholeWordRegexCaseInsensitive', () => {
    const r: number[] = findAll('Foo foo FOOD', 'foo', false, true, true);
    equal(r.length, 4);
    equal(r[0], 0);
    equal(r[2], 4);
  });
  await test(suite, 'wholeWordReplaceAllLiteralOnlyTouchesWholeWords', () => {
    const m: number[] = findAll('cat category cat', 'cat', true, false, true);
    equal(replaceAllLiteral('cat category cat', m, 'dog'), 'dog category dog');
  });
  await test(suite, 'unicodeRegexClassesIncludeCjk', () => {
    arrayEqual(findAll('中文', '\\w+', true, true, false), [0, 2]);
  });
}

export function suiteName(): string {
  return 'SearchEngine';
}
