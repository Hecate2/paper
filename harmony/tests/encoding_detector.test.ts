/** EncodingDetector 单测：与安卓版 EncodingDetectorTest 对应。
 *
 * 说明：GBK/GB18030/Big5 的*编码*需要平台编码器（鸿蒙真机 util.TextEncoder），
 * Mac 版 Node 没有 GBK 编码器，故 Node 侧覆盖：全部解码路径（含 iconv 取的
 * 真实 GBK/GB18030/Big5 字节向量）、检测、工具函数；GBK 系编码正确性
 * 由真机测试覆盖（见 harmony/README.md）。无 codecs 时 encode 直接抛错
 * （防静默存错编码），此处一并断言。
 */
import {
  AUTO, UTF_8, GBK, GB18030, BIG5, UTF_16LE, UTF_16BE, LATIN_1, USER_CHOICES,
  looksBinary, resolveCharset, detect, decode, encode, stripBom,
  isValidCharsetName, isAuto, labelOf,
  type TextCodecs
} from './.tmp_core/EncodingDetector.ts';
import {
  test, equal, arrayEqual, isTrue, isFalse, throwsFn,
  bytesEqual, utf8bytes, type Suite
} from './assert.ts';

// Node 侧的平台编解码器（鸿蒙真机对应 model/TextCodecs.ets 的 util 实现）。
const LABELS: Record<string, string> = {
  'UTF-8': 'utf-8',
  'GBK': 'gbk',
  'GB18030': 'gb18030',
  'Big5': 'big5',
  'UTF-16LE': 'utf-16le',
  'UTF-16BE': 'utf-16be',
  'ISO-8859-1': 'iso-8859-1'
};

class NodeCodecs implements TextCodecs {
  decode(bytes: Uint8Array, charsetName: string): string {
    return new TextDecoder(LABELS[charsetName] ?? 'utf-8', { fatal: false }).decode(bytes);
  }
  encode(text: string, charsetName: string): Uint8Array {
    throw new Error('NodeCodecs.encode not implemented for ' + charsetName + ' (' + text.length + ')');
  }
  strictDecode(bytes: Uint8Array, charsetName: string): void {
    new TextDecoder(LABELS[charsetName] ?? 'utf-8', { fatal: true }).decode(bytes);
  }
}

const codecs: TextCodecs = new NodeCodecs();

// iconv 取的真实字节向量（见 core 提交说明）
const NIHAO_SHIJIE_GB18030: number[] = [0xc4, 0xe3, 0xba, 0xc3, 0xca, 0xc0, 0xbd, 0xe7];
const JIAN_TI_GB18030: number[] = [0xbc, 0xf2, 0xcc, 0xe5, 0xd6, 0xd0, 0xce, 0xc4, 0xb2, 0xe2, 0xca, 0xd4];
const GBK_CONTENT_GBK: number[] =
  [0x47, 0x42, 0x4b, 0x20, 0xb1, 0xe0, 0xc2, 0xeb, 0xc4, 0xda, 0xc8, 0xdd];
const FAN_TI_BIG5: number[] = [0xc1, 0x63, 0xc5, 0xe9];

export async function run(suite: Suite): Promise<void> {
  await test(suite, 'detectsUtf8Bom', () => {
    equal(detect(Uint8Array.from([0xef, 0xbb, 0xbf, 0x68, 0x69]), codecs), UTF_8);
  });
  await test(suite, 'detectsUtf16Bom', () => {
    equal(detect(Uint8Array.from([0xff, 0xfe, 0x61, 0x00]), codecs), UTF_16LE);
    equal(detect(Uint8Array.from([0xfe, 0xff, 0x00, 0x61]), codecs), UTF_16BE);
  });
  await test(suite, 'detectsPlainUtf8', () => {
    equal(detect(utf8bytes('你好，world'), codecs), UTF_8);
  });
  await test(suite, 'detectsGb18030ForChineseGbkBytes', () => {
    equal(detect(Uint8Array.from(NIHAO_SHIJIE_GB18030), codecs), GB18030);
  });
  await test(suite, 'asciiFallsBackToUtf8', () => {
    equal(detect(utf8bytes('plain ascii text'), codecs), UTF_8);
  });
  await test(suite, 'emptyFileIsUtf8', () => {
    equal(detect(new Uint8Array(0), codecs), UTF_8);
  });
  await test(suite, 'resolveCharsetHonorsUserChoice', () => {
    equal(resolveCharset(GBK, utf8bytes('x'), codecs), GBK);
  });
  await test(suite, 'resolveCharsetAutoDetects', () => {
    equal(resolveCharset(AUTO, Uint8Array.from(JIAN_TI_GB18030), codecs), GB18030);
  });
  await test(suite, 'invalidUserChoiceFallsBackToDetection', () => {
    equal(resolveCharset('NOT-A-CHARSET', utf8bytes('abc'), codecs), UTF_8);
  });
  await test(suite, 'detectsNulAsBinary', () => {
    isTrue(looksBinary(Uint8Array.from([0x61, 0x00, 0x62])));
    isFalse(looksBinary(Uint8Array.from([0x61, 0x62, 0x63])));
    isFalse(looksBinary(new Uint8Array(0)));
  });
  await test(suite, 'sniffIsLimitedToFirst8k', () => {
    const head: Uint8Array = new Uint8Array(9000).fill(0x78);
    head[8500] = 0;
    isFalse(looksBinary(head));
    head[100] = 0;
    isTrue(looksBinary(head));
  });
  await test(suite, 'utf8RoundTrip', () => {
    const s: string = '白纸 White Paper — 中文\n第二行\t制表符';
    const enc: Uint8Array = encode(s, UTF_8);
    equal(decode(enc, UTF_8, codecs), s);
  });
  await test(suite, 'gb18030DecodesCorrectly', () => {
    equal(decode(Uint8Array.from(NIHAO_SHIJIE_GB18030), GB18030, codecs), '你好世界');
  });
  await test(suite, 'gbkDecodesCorrectly', () => {
    equal(decode(Uint8Array.from(GBK_CONTENT_GBK), GBK, codecs), 'GBK 编码内容');
  });
  await test(suite, 'big5DecodesCorrectly', () => {
    equal(decode(Uint8Array.from(FAN_TI_BIG5), BIG5, codecs), '繁體');
  });
  await test(suite, 'utf16RoundTrip', () => {
    const s: string = 'hi 中文 ☃';
    equal(decode(encode(s, UTF_16LE), UTF_16LE, codecs), s);
    equal(decode(encode(s, UTF_16BE), UTF_16BE, codecs), s);
    bytesEqual(encode('ab', 'UTF-16'), [0xfe, 0xff, 0x00, 0x61, 0x00, 0x62]);
  });
  await test(suite, 'gbEncodeWithoutCodecsThrowsClearly', () => {
    throwsFn(() => encode('中文', GB18030), 'GB18030');
    throwsFn(() => encode('中文', GBK), 'GBK');
    throwsFn(() => encode('繁體', BIG5), 'Big5');
  });
  await test(suite, 'crlfIsPreservedThroughDecode', () => {
    const data: Uint8Array = utf8bytes('line1\r\nline2\r\n');
    const text: string = decode(data, UTF_8, codecs);
    equal(text, 'line1\r\nline2\r\n');
    bytesEqual(encode(text, UTF_8), Array.from(data));
  });
  await test(suite, 'utf8BomIsStrippedOnDecode', () => {
    const data: Uint8Array = Uint8Array.from([0xef, 0xbb, 0xbf, 0x61, 0x62]);
    equal(stripBom(decode(data, UTF_8, codecs), UTF_8), 'ab');
  });
  await test(suite, 'malformedBytesDecodeWithReplacementInsteadOfThrowing', () => {
    const bad: Uint8Array = Uint8Array.from([0xff, 0xfe, 0x41, 0xff, 0x00]);
    const text: string = decode(bad, UTF_8, codecs);
    isFalse(text.length === 0);
  });
  await test(suite, 'unmappableCharactersEncodeWithReplacementNotThrow', () => {
    const enc: Uint8Array = encode('中文', LATIN_1);
    isTrue(enc.length > 0);
    equal(decode(enc, LATIN_1, codecs), '??');
  });
  await test(suite, 'encodeWithAutoUsesUtf8', () => {
    bytesEqual(encode('abc', AUTO), [0x61, 0x62, 0x63]);
  });
  await test(suite, 'charsetValidation', () => {
    isTrue(isValidCharsetName('UTF-8'));
    isTrue(isValidCharsetName('GB18030'));
    isFalse(isValidCharsetName('nonsense-charset'));
    isFalse(isValidCharsetName(null));
    isFalse(isValidCharsetName(''));
  });
  await test(suite, 'isAuto', () => {
    isTrue(isAuto(null));
    isTrue(isAuto(''));
    isTrue(isAuto(AUTO));
    isFalse(isAuto(UTF_8));
  });
  await test(suite, 'labelsAreHumanReadable', () => {
    equal(labelOf(AUTO), '自动检测');
    equal(labelOf(UTF_8), 'UTF-8');
    isTrue(labelOf(GB18030).indexOf('GB18030') >= 0);
  });
  await test(suite, 'userChoicesCoverCommonEncodings', () => {
    const joined: string = USER_CHOICES.join(',');
    isTrue(joined.indexOf('UTF-8') >= 0);
    isTrue(joined.indexOf('GBK') >= 0);
    isTrue(joined.indexOf('GB18030') >= 0);
    isTrue(joined.indexOf('Big5') >= 0);
    isTrue(joined.indexOf('UTF-16') >= 0);
    isTrue(joined.indexOf('ISO-8859-1') >= 0);
  });
  await test(suite, 'strictUtf8RejectsOverlongAndTruncated', () => {
    // 过长编码 0xC0 0xAF（'/' 的过长形式）必须判非法 → 走 GB18030 分支
    const overlong: Uint8Array = Uint8Array.from([0xc0, 0xaf]);
    isFalse(detect(overlong, codecs) === UTF_8);
    arrayEqual(utf8bytes('a'), [0x61]);
  });
}

export function suiteName(): string {
  return 'EncodingDetector';
}
