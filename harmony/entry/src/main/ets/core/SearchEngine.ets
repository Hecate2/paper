/**
 * 高性能查找/替换（对应安卓版 core/SearchEngine.java）。
 *
 * 与 ArkUI 无关的纯逻辑，可在 Node 侧单测（见 harmony/tests/）。
 * 结果为扁平 int 对 [start0, end0, start1, end1, ...]，避免海量小对象。
 * 扫描本身是同步的；调用方（Index 页）在后台任务里跑它，UI 只收结果区间。
 *
 * 与 Java 版行为对齐（含中文/全词/正则），两处有意的差异见函数注释：
 * 1. `\w` 按 UNICODE_CHARACTER_CLASS 语义转写为 `[\p{L}\p{N}_]`
 *    （JS 的 `\w` 只认 ASCII，直接用会找不到中文；见 tryCompile）。
 * 2. 替换串里无法识别的 `$` 序列按字面保留（Java 版会抛异常导致闪退，
 *    这里做了防崩加固；见 expandReplacement）。
 */

export const MAX_RESULTS: number = 200000;

/** 协作式取消标记（对应 Java 版的 boolean[] cancel，查到一半可中断）。 */
export interface CancelFlag {
  cancelled: boolean;
}

/**
 * 在 text 中找出 query 的全部非重叠命中。
 * @param query 纯文本（regex=false）或正则（regex=true）
 * @param wholeWord 为 true 时命中两侧不能紧贴“词内字符”（字母/数字/下划线，Unicode 感知）
 */
export function findAll(
  text: string,
  query: string,
  caseSensitive: boolean,
  regex: boolean,
  wholeWord: boolean = false,
  cancel?: CancelFlag | null
): number[] {
  if (text == null || query == null || query.length === 0) {
    return [];
  }
  if (regex) {
    return findAllRegex(text, query, caseSensitive, wholeWord, cancel);
  }
  return findAllPlain(text, query, caseSensitive, wholeWord, cancel);
}

/** “词内字符”判定，对应 Java 版 isWordChar（Character.isLetterOrDigit + '_'）。 */
const WORD_CHAR_RE: RegExp = /[\p{L}\p{N}_]/u;

export function isWordCharUnit(ch: string): boolean {
  return WORD_CHAR_RE.test(ch);
}

function boundaryOk(text: string, start: number, end: number, wholeWord: boolean): boolean {
  if (!wholeWord) {
    return true;
  }
  if (start > 0 && isWordCharUnit(text.charAt(start - 1))) {
    return false;
  }
  return end >= text.length || !isWordCharUnit(text.charAt(end));
}

function findAllPlain(
  text: string,
  query: string,
  caseSensitive: boolean,
  wholeWord: boolean,
  cancel?: CancelFlag | null
): number[] {
  const starts: number[] = [];
  if (caseSensitive) {
    let idx: number = text.indexOf(query);
    while (idx >= 0) {
      if ((starts.length & 1023) === 0 && isCancelled(cancel)) {
        break;
      }
      const end: number = idx + query.length;
      if (boundaryOk(text, idx, end, wholeWord)) {
        starts.push(idx);
        if (starts.length >= MAX_RESULTS) {
          break;
        }
      }
      idx = text.indexOf(query, end);
    }
  } else {
    // 大小写不敏感：对小写副本扫描，再到原文上验证（与 Java 版同策略）。
    const lowerText: string = text.toLowerCase();
    const lowerQuery: string = query.toLowerCase();
    const step: number = Math.max(1, lowerQuery.length);
    let idx: number = lowerText.indexOf(lowerQuery);
    while (idx >= 0) {
      if ((starts.length & 1023) === 0 && isCancelled(cancel)) {
        break;
      }
      const end: number = idx + query.length;
      if (
        boundaryOk(text, idx, end, wholeWord) &&
        text.slice(idx, end).toLowerCase() === lowerQuery
      ) {
        starts.push(idx);
        if (starts.length >= MAX_RESULTS) {
          break;
        }
      }
      idx = lowerText.indexOf(lowerQuery, idx + step);
    }
  }
  const out: number[] = new Array<number>(starts.length * 2);
  for (let i: number = 0; i < starts.length; i++) {
    out[i * 2] = starts[i];
    out[i * 2 + 1] = starts[i] + query.length;
  }
  return out;
}

interface CompiledQuery {
  re: RegExp;
}

/**
 * 把用户正则转成“Unicode 语义”：
 * - 类外的 `\w` / `\W` 转写为 `[\p{L}\p{N}_]` / 取反（JS 的 \w 只认 ASCII，
 *   否则搜不到中文；对应 Java 的 UNICODE_CHARACTER_CLASS）。
 * - 类外的 `\b` 转写为 Unicode 感知的零宽断言（同上原因）。
 * 类内的 `[\b]`（退格）保持不动，与 Java/JS 语义一致。
 */
function translateCharClasses(src: string): string {
  let out: string = '';
  let inClass: boolean = false;
  let i: number = 0;
  while (i < src.length) {
    const c: string = src[i];
    if (c === '\\' && i + 1 < src.length) {
      const n: string = src[i + 1];
      if (!inClass && n === 'w') {
        out += '[\\p{L}\\p{N}_]';
      } else if (!inClass && n === 'W') {
        out += '[^\\p{L}\\p{N}_]';
      } else if (!inClass && n === 'b') {
        out += '(?:(?<![\\p{L}\\p{N}_])(?=[\\p{L}\\p{N}_])|(?<=[\\p{L}\\p{N}_])(?![\\p{L}\\p{N}_]))';
      } else {
        out += c + n;
      }
      i += 2;
      continue;
    }
    if (c === '[') {
      inClass = true;
    } else if (c === ']') {
      inClass = false;
    }
    out += c;
    i += 1;
  }
  return out;
}

function tryCompile(query: string, caseSensitive: boolean, wholeWord: boolean): RegExp | null {
  const translated: string = translateCharClasses(query);
  const wrapped: string = wholeWord
    // 全词 = Unicode 感知的环视包裹；非捕获分组保证 $1..$9 编号不变（与 Java 版同理）。
    ? '(?<![\\p{L}\\p{N}_])(?:' + translated + ')(?![\\p{L}\\p{N}_])'
    : translated;
  const flags: string = 'gsu' + (caseSensitive ? '' : 'i'); // s≈DOTALL，u≈UNICODE_CHARACTER_CLASS
  try {
    return new RegExp(wrapped, flags);
  } catch (e1) {
    // 极少数 Java 合法但 'u' 模式下非法的写法（如 \a）：退回按原文编译，
    // 仍失败才视为非法正则（返回空结果，绝不抛异常）。
    try {
      return new RegExp(query, 'gs' + (caseSensitive ? '' : 'i'));
    } catch (e2) {
      return null;
    }
  }
}

function findAllRegex(
  text: string,
  query: string,
  caseSensitive: boolean,
  wholeWord: boolean,
  cancel?: CancelFlag | null
): number[] {
  const re: RegExp | null = tryCompile(query, caseSensitive, wholeWord);
  if (re === null) {
    return [];
  }
  const starts: number[] = [];
  const ends: number[] = [];
  let regionStart: number = 0;
  let lastEnd: number = -1;
  while (starts.length < MAX_RESULTS) {
    if ((starts.length & 1023) === 0 && isCancelled(cancel)) {
      break;
    }
    re.lastIndex = regionStart;
    const m: RegExpExecArray | null = re.exec(text);
    if (m === null) {
      break;
    }
    const s: number = m.index;
    const e: number = s + m[0].length;
    if (s === e) {
      // 零宽匹配：手动前进一步，避免死循环（与 Java 版同策略）。
      if (e >= text.length) {
        break;
      }
      regionStart = e + 1;
      continue;
    }
    if (s < lastEnd) {
      regionStart = e;
      continue;
    }
    starts.push(s);
    ends.push(e);
    lastEnd = e;
    regionStart = e;
    if (regionStart > text.length) {
      break;
    }
  }
  const out: number[] = new Array<number>(starts.length * 2);
  for (let i: number = 0; i < starts.length; i++) {
    out[i * 2] = starts[i];
    out[i * 2 + 1] = ends[i];
  }
  return out;
}

/** 把全部 findAll 命中按字面替换（单个替换走 replaceRange / replaceCurrentRegex）。 */
export function replaceAllLiteral(
  text: string,
  matches: number[] | null,
  replacement: string | null
): string {
  if (matches == null || matches.length === 0) {
    return text;
  }
  const rep: string = replacement == null ? '' : replacement;
  let out: string = '';
  let cursor: number = 0;
  for (let i: number = 0; i + 1 < matches.length; i += 2) {
    const s: number = matches[i];
    const e: number = matches[i + 1];
    if (s < cursor) {
      continue;
    }
    out += text.slice(cursor, s) + rep;
    cursor = e;
  }
  out += text.slice(cursor);
  return out;
}

/**
 * 展开替换串里的组引用。支持 $$ $& $` $' $1..$99 ${n} $<name>，
 * 无法识别的 $ 序列按字面保留（Java 版会直接抛异常导致闪退，见文件头注释）。
 */
function expandReplacement(rep: string, m: RegExpExecArray, fullText: string): string {
  const s: number = m.index;
  const e: number = s + m[0].length;
  let out: string = '';
  let i: number = 0;
  while (i < rep.length) {
    const dollar: number = rep.indexOf('$', i);
    if (dollar < 0) {
      out += rep.slice(i);
      break;
    }
    out += rep.slice(i, dollar);
    const n: string = rep[dollar + 1];
    if (n === undefined) {
      out += '$';
      i = dollar + 1;
      continue;
    }
    if (n === '$') {
      out += '$';
      i = dollar + 2;
    } else if (n === '&') {
      out += m[0];
      i = dollar + 2;
    } else if (n === '`') {
      out += fullText.slice(0, s);
      i = dollar + 2;
    } else if (n === "'") {
      out += fullText.slice(e);
      i = dollar + 2;
    } else if (n >= '0' && n <= '9') {
      let j: number = dollar + 1;
      while (j < rep.length && j < dollar + 3 && rep[j] >= '0' && rep[j] <= '9') {
        j++;
      }
      const num: number = parseInt(rep.slice(dollar + 1, j), 10);
      if (num < m.length) {
        out += m[num] ?? '';
      } else {
        out += '$' + rep.slice(dollar + 1, j);
      }
      i = j;
    } else if (n === '{' || n === '<') {
      const close: string = n === '{' ? '}' : '>';
      const end: number = rep.indexOf(close, dollar + 2);
      if (end < 0) {
        out += '$' + n;
        i = dollar + 2;
      } else {
        const name: string = rep.slice(dollar + 2, end);
        const groups: Record<string, string | undefined> | undefined =
          (m as RegExpExecArray & { groups?: Record<string, string | undefined> }).groups;
        const v: string | undefined = groups?.[name];
        out += v ?? '';
        i = end + 1;
      }
    } else {
      out += '$' + n;
      i = dollar + 2;
    }
  }
  return out;
}

/** 正则全部替换，替换串支持 $1..$9 组引用。 */
export function replaceAllRegex(
  text: string,
  query: string,
  replacement: string | null,
  caseSensitive: boolean,
  wholeWord: boolean
): string {
  if (text == null || query == null || query.length === 0) {
    return text;
  }
  const re: RegExp | null = tryCompile(query, caseSensitive, wholeWord);
  if (re === null) {
    return text;
  }
  const rep: string = replacement == null ? '' : replacement;
  let out: string = '';
  let cursor: number = 0;
  let count: number = 0;
  let lastEnd: number = -1;
  let regionStart: number = 0;
  while (count < MAX_RESULTS) {
    re.lastIndex = regionStart;
    const m: RegExpExecArray | null = re.exec(text);
    if (m === null) {
      break;
    }
    const s: number = m.index;
    const e: number = s + m[0].length;
    if (s === e) {
      if (e >= text.length) {
        break;
      }
      regionStart = e + 1;
      continue;
    }
    if (s < lastEnd) {
      regionStart = e;
      continue;
    }
    out += text.slice(cursor, s) + expandReplacement(rep, m, text);
    cursor = e;
    count++;
    lastEnd = e;
    regionStart = e;
    if (regionStart > text.length) {
      break;
    }
  }
  out += text.slice(cursor);
  return out;
}

/** 字面替换单个区间（“替换当前”在纯文本模式下用它）。 */
export function replaceRange(
  text: string,
  start: number,
  end: number,
  replacement: string | null
): string {
  return text.slice(0, start) + (replacement == null ? '' : replacement) + text.slice(end);
}

/**
 * 展开组引用后替换 [start, end) 这一处；当该区间不是正则的精确命中时
 * 回退为字面替换（与 Java 版 replaceCurrentRegex 同语义）。
 */
export function replaceCurrentRegex(
  text: string,
  query: string,
  start: number,
  end: number,
  replacement: string | null,
  caseSensitive: boolean,
  wholeWord: boolean
): string {
  const re: RegExp | null = tryCompile(query, caseSensitive, wholeWord);
  if (re !== null) {
    let regionStart: number = 0;
    let lastEnd: number = -1;
    for (let guard: number = 0; guard <= MAX_RESULTS; guard++) {
      re.lastIndex = regionStart;
      const m: RegExpExecArray | null = re.exec(text);
      if (m === null) {
        break;
      }
      const s: number = m.index;
      const e: number = s + m[0].length;
      if (s === e) {
        if (e >= text.length) {
          break;
        }
        regionStart = e + 1;
        continue;
      }
      if (s < lastEnd) {
        regionStart = e;
        continue;
      }
      if (s === start && e === end) {
        const expanded: string = expandReplacement(replacement == null ? '' : replacement, m, text);
        return text.slice(0, start) + expanded + text.slice(end);
      }
      if (s > start) {
        break;
      }
      lastEnd = e;
      regionStart = e;
    }
  }
  return replaceRange(text, start, end, replacement);
}

function isCancelled(cancel?: CancelFlag | null): boolean {
  return cancel != null && cancel.cancelled;
}
