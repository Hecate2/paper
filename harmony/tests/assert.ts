/** 极简断言/注册框架（零依赖，供各 .test.ts 使用）。 */

export interface Suite {
  total: number;
  passed: number;
  failed: number;
  failures: string[];
}

export function createSuite(): Suite {
  return { total: 0, passed: 0, failed: 0, failures: [] };
}

export async function test(
  suite: Suite,
  name: string,
  fn: () => void | Promise<void>
): Promise<void> {
  suite.total++;
  try {
    await fn();
    suite.passed++;
  } catch (e) {
    suite.failed++;
    const msg: string = e instanceof Error ? e.message : String(e);
    suite.failures.push(name + ' :: ' + msg);
    console.error('FAIL ' + name + ' :: ' + msg);
  }
}

function fmt(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch (e) {
    return String(v);
  }
}

export function equal(actual: unknown, expected: unknown, hint: string = ''): void {
  if (actual !== expected) {
    throw new Error(
      'expected ' + fmt(expected) + ' but got ' + fmt(actual) + (hint === '' ? '' : ' (' + hint + ')')
    );
  }
}

export function arrayEqual(actual: ArrayLike<number>, expected: ArrayLike<number>): void {
  if (actual.length !== expected.length) {
    throw new Error(
      'array length ' + actual.length + ' !== ' + expected.length +
      ' actual=' + fmt(Array.from(actual as unknown as number[])) +
      ' expected=' + fmt(Array.from(expected as unknown as number[]))
    );
  }
  for (let i: number = 0; i < actual.length; i++) {
    if (actual[i] !== expected[i]) {
      throw new Error(
        'array[' + i + '] ' + actual[i] + ' !== ' + expected[i] +
        ' actual=' + fmt(Array.from(actual as unknown as number[])) +
        ' expected=' + fmt(Array.from(expected as unknown as number[]))
      );
    }
  }
}

export function isTrue(v: boolean, hint: string = ''): void {
  if (v !== true) {
    throw new Error('expected true' + (hint === '' ? '' : ' (' + hint + ')'));
  }
}

export function isFalse(v: boolean, hint: string = ''): void {
  if (v !== false) {
    throw new Error('expected false' + (hint === '' ? '' : ' (' + hint + ')'));
  }
}

export function throwsFn(fn: () => unknown, hint: string = ''): void {
  try {
    fn();
  } catch (e) {
    return;
  }
  throw new Error('expected function to throw' + (hint === '' ? '' : ' (' + hint + ')'));
}

export function matches(v: string, re: RegExp, hint: string = ''): void {
  if (!re.test(v)) {
    throw new Error(
      'expected ' + fmt(v) + ' to match ' + String(re) + (hint === '' ? '' : ' (' + hint + ')')
    );
  }
}

export function bytesEqual(actual: Uint8Array, expected: number[] | Uint8Array): void {
  const exp: ArrayLike<number> = expected;
  arrayEqual(actual, exp);
}

export function utf8bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}
