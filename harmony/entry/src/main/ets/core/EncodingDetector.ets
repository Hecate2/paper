/**
 * 文本编码检测与无损编解码（对应安卓版 core/EncodingDetector.java）。
 *
 * AUTO 策略：BOM → 严格 UTF-8 校验 → GB18030 → Latin-1（永不失败）。
 *
 * 平台解码器说明：
 * - 鸿蒙真机：调用方传入 util.TextDecoder/TextEncoder 包装的 TextCodecs
 *   （见 model/TextCodecs.ets），GBK/Big5/UTF-16 全都支持。
 * - Node 单测 / 无平台解码器时：decode 走全局 TextDecoder（Node 22 经 ICU
 *   支持 gbk/gb18030/big5/utf-16le-be/iso-8859-1，与鸿蒙 util 覆盖一致）；
 *   encode 仅 UTF-8 / Latin-1 / UTF-16LE-BE 有纯 TS 内置实现，
 *   GBK/GB18030/Big5 在没有 codecs 时抛错（见 encode 注释），
 *   因此这三者的 *编码* 正确性由真机测试覆盖，Node 侧覆盖解码/检测/工具函数。
 */

export const AUTO: string = 'AUTO';
export const UTF_8: string = 'UTF-8';
export const GBK: string = 'GBK';
export const GB18030: string = 'GB18030';
export const BIG5: string = 'Big5';
export const UTF_16LE: string = 'UTF-16LE';
export const UTF_16BE: string = 'UTF-16BE';
export const LATIN_1: string = 'ISO-8859-1';

/** 设置页/编码菜单里提供给用户的选项，顺序与安卓版一致。 */
export const USER_CHOICES: string[] = [AUTO, UTF_8, GBK, GB18030, BIG5, 'UTF-16', LATIN_1];

const SNIFF_BYTES: number = 8192;

/** 平台编解码器注入点：鸿蒙侧用 util 实现，Node 侧用全局 TextDecoder 实现。 */
export interface TextCodecs {
  decode(bytes: Uint8Array, charsetName: string): string;
  encode(text: string, charsetName: string): Uint8Array;
}

/** 嗅探前 SNIFF_BYTES 是否含 NUL（含则判二进制，与安卓版同）。 */
export function looksBinary(head: Uint8Array): boolean {
  const n: number = Math.min(head.length, SNIFF_BYTES);
  for (let i: number = 0; i < n; i++) {
    if (head[i] === 0) {
      return true;
    }
  }
  return false;
}

/** 按用户偏好解析出实际编码；恒返回可解码的编码名。 */
export function resolveCharset(
  preference: string | null,
  data: Uint8Array,
  codecs?: TextCodecs
): string {
  if (!isAuto(preference) && isValidCharsetName(preference as string)) {
    return preference as string;
  }
  return detect(data, codecs);
}

/** 纯检测：BOM → 严格 UTF-8 → GB18030 → Latin-1。 */
export function detect(data: Uint8Array, codecs?: TextCodecs): string {
  if (hasBom(data, [0xef, 0xbb, 0xbf])) {
    return UTF_8;
  }
  if (hasBom(data, [0xff, 0xfe])) {
    return UTF_16LE;
  }
  if (hasBom(data, [0xfe, 0xff])) {
    return UTF_16BE;
  }
  if (data.length === 0) {
    return UTF_8;
  }
  if (isValidUtf8(data)) {
    return UTF_8;
  }
  if (decodesStrictlyAs(data, GB18030, codecs)) {
    return GB18030;
  }
  return LATIN_1;
}

/** 解码（非法序列用替换符，绝不抛异常；BOM 保留，另用 stripBom 去掉）。 */
export function decode(bytes: Uint8Array, charsetName: string | null, codecs?: TextCodecs): string {
  const cs: string = normalizeForData(charsetName, bytes);
  if (codecs !== undefined && codecs !== null) {
    return codecs.decode(bytes, cs);
  }
  try {
    const decoder: TextDecoder = new TextDecoder(toDecoderLabel(cs), { fatal: false });
    return decoder.decode(bytes);
  } catch (e) {
    try {
      return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    } catch (e2) {
      return '';
    }
  }
}

/**
 * 编码回字节（非法字符用替换符，绝不抛异常）。
 * UTF-8 / Latin-1 / UTF-16LE-BE（含 "UTF-16"）走内置纯 TS 实现；
 * GBK/GB18030/Big5 需要平台编码器（鸿蒙侧 model/TextCodecs.ets 经
 * util.TextEncoder 提供），缺失时抛错——这比静默写成 UTF-8 更安全
 * （否则会把用户文件存成声明不符的编码）。
 */
export function encode(text: string, charsetName: string | null, codecs?: TextCodecs): Uint8Array {
  const src: string = text == null ? '' : text;
  if (isAuto(charsetName) || charsetName === UTF_8) {
    return encodeUtf8(src);
  }
  if (charsetName === LATIN_1) {
    return encodeLatin1(src);
  }
  if (charsetName === UTF_16LE) {
    return encodeUtf16(src, true, false);
  }
  if (charsetName === UTF_16BE) {
    return encodeUtf16(src, false, false);
  }
  if (charsetName === 'UTF-16') {
    // 与 Java Charset UTF-16 一致：BOM(FE FF) + 大端。
    return encodeUtf16(src, false, true);
  }
  if (codecs !== undefined && codecs !== null) {
    return codecs.encode(src, charsetName as string);
  }
  throw new Error(
    '当前运行环境缺少 ' + (charsetName as string) + ' 编码器（鸿蒙真机由 util.TextEncoder 提供）'
  );
}

/** 去掉解码文本开头的 BOM，避免显示出来或重复保存。 */
export function stripBom(text: string, charsetName: string | null): string {
  if (text.length === 0 || text.charAt(0) !== '﻿') {
    return text;
  }
  if (
    UTF_8 === charsetName ||
    'UTF-16' === charsetName ||
    UTF_16LE === charsetName ||
    UTF_16BE === charsetName
  ) {
    return text.substring(1);
  }
  return text;
}

/** 编码名在本运行环境是否合法可用。 */
export function isValidCharsetName(name: string | null): boolean {
  if (name == null || name.length === 0) {
    return false;
  }
  const known: string[] = [UTF_8, GBK, GB18030, BIG5, UTF_16LE, UTF_16BE, LATIN_1, 'UTF-16', AUTO];
  if (known.indexOf(name) >= 0) {
    return true;
  }
  try {
    // eslint-disable-next-line no-new
    new TextDecoder(name, { fatal: true });
    return true;
  } catch (e) {
    return false;
  }
}

export function isAuto(preference: string | null): boolean {
  return preference == null || preference.length === 0 || AUTO === preference;
}

/** 设置页下拉框里的人类可读标签。 */
export function labelOf(charsetName: string): string {
  if (AUTO === charsetName) {
    return '自动检测';
  }
  if (GB18030 === charsetName) {
    return 'GB18030（简体中文）';
  }
  if (GBK === charsetName) {
    return 'GBK（简体中文）';
  }
  if (BIG5 === charsetName) {
    return 'Big5（繁体中文）';
  }
  if (UTF_8 === charsetName) {
    return 'UTF-8';
  }
  if ('UTF-16' === charsetName) {
    return 'UTF-16';
  }
  if (LATIN_1 === charsetName) {
    return 'Latin-1（ISO-8859-1）';
  }
  return charsetName;
}

// ---- 内部实现 ----

function hasBom(data: Uint8Array, bom: number[]): boolean {
  if (data.length < bom.length) {
    return false;
  }
  for (let i: number = 0; i < bom.length; i++) {
    if (data[i] !== bom[i]) {
      return false;
    }
  }
  return true;
}

/**
 * 严格 UTF-8 校验（纯 TS，不依赖平台解码器，各端行为一致）：
 * 拒绝过长编码、代理区编码、超出 U+10FFFF 与截断序列。
 */
export function isValidUtf8(data: Uint8Array): boolean {
  let i: number = 0;
  while (i < data.length) {
    const b0: number = data[i];
    if (b0 <= 0x7f) {
      i += 1;
      continue;
    }
    let need: number = 0;
    let min: number = 0;
    if (b0 >= 0xc2 && b0 <= 0xdf) {
      need = 1;
      min = 0x80;
    } else if (b0 >= 0xe0 && b0 <= 0xef) {
      need = 2;
      min = 0x800;
    } else if (b0 >= 0xf0 && b0 <= 0xf4) {
      need = 3;
      min = 0x10000;
    } else {
      return false;
    }
    if (i + need >= data.length) {
      return false;
    }
    let cp: number = b0 & (need === 1 ? 0x1f : need === 2 ? 0x0f : 0x07);
    for (let k: number = 1; k <= need; k++) {
      const b: number = data[i + k];
      if (b < 0x80 || b > 0xbf) {
        return false;
      }
      cp = (cp << 6) | (b & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
      return false;
    }
    i += need + 1;
  }
  return true;
}

function decodesStrictlyAs(data: Uint8Array, charsetName: string, codecs?: TextCodecs): boolean {
  if (codecs !== undefined && codecs !== null) {
    try {
      // 平台 codecs.decode 是非严格的；严格校验走全局 TextDecoder（若可用）。
      codecs.decode(data, charsetName);
    } catch (e) {
      return false;
    }
  }
  try {
    const decoder: TextDecoder = new TextDecoder(toDecoderLabel(charsetName), { fatal: true });
    decoder.decode(data);
    return true;
  } catch (e) {
    // 运行环境没有该解码器时：GB18030 几乎能覆盖全部字节序列，按可解处理，
    // 交给后续 decode(非严格) 兜底，行为与安卓“GB18030 回退”一致。
    return charsetName === GB18030;
  }
}

/** "UTF-16" 伪选项按 BOM 落到具体端序（无 BOM 时与 Java 一致取大端）。 */
function normalizeForData(charsetName: string | null, data: Uint8Array): string {
  if (isAuto(charsetName)) {
    return UTF_8;
  }
  if ('UTF-16' === charsetName) {
    if (hasBom(data, [0xff, 0xfe])) {
      return UTF_16LE;
    }
    return UTF_16BE;
  }
  return charsetName as string;
}

function toDecoderLabel(charsetName: string): string {
  if (charsetName === UTF_8 || isAuto(charsetName)) {
    return 'utf-8';
  }
  if (charsetName === GBK) {
    return 'gbk';
  }
  if (charsetName === GB18030) {
    return 'gb18030';
  }
  if (charsetName === BIG5) {
    return 'big5';
  }
  if (charsetName === UTF_16LE) {
    return 'utf-16le';
  }
  if (charsetName === UTF_16BE) {
    return 'utf-16be';
  }
  if (charsetName === LATIN_1) {
    return 'iso-8859-1';
  }
  return charsetName;
}

function encodeUtf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    let cp: number = text.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < text.length) {
      const lo: number = text.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f)
      );
    }
  }
  return Uint8Array.from(out);
}

function encodeLatin1(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i: number = 0; i < text.length; i++) {
    const cp: number = text.charCodeAt(i);
    out[i] = cp <= 0xff ? cp : 0x3f; // 写不下的字符用 '?' 代替（与 Java REPLACE 同）
  }
  return out;
}

function encodeUtf16(text: string, littleEndian: boolean, withBom: boolean): Uint8Array {
  const out: number[] = [];
  if (withBom) {
    out.push(0xfe, 0xff);
  }
  for (let i: number = 0; i < text.length; i++) {
    const cp: number = text.charCodeAt(i);
    if (littleEndian) {
      out.push(cp & 0xff, (cp >> 8) & 0xff);
    } else {
      out.push((cp >> 8) & 0xff, cp & 0xff);
    }
  }
  return Uint8Array.from(out);
}
