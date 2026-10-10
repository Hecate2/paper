import { util } from '@kit.ArkTS';
import type { TextCodecs } from '../core/EncodingDetector.ets';

/**
 * 平台编解码器：给 core/EncodingDetector 注入的 TextCodecs 实现。
 * 基于 @kit.ArkTS 的 util.TextDecoder / util.TextEncoder，
 * 覆盖 UTF-8 / GBK / GB18030(→GBK 回退) / Big5 / UTF-16LE-BE / Latin-1。
 *
 * 两个方法都永不抛异常（失败时按 UTF-8 兜底，行为与安卓 REPLACE 同），
 * 因此 core.encode 在鸿蒙真机上也不会走到抛错分支。
 */
export class UtilTextCodecs implements TextCodecs {
  decode(bytes: Uint8Array, charsetName: string): string {
    const labels: string[] = decoderLabels(charsetName);
    for (const label of labels) {
      try {
        const decoder = util.TextDecoder.create(label, { fatal: false, ignoreBOM: true });
        return decoder.decodeToString(bytes);
      } catch (e) {
        // 换下一个候选
      }
    }
    try {
      const fallback = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
      return fallback.decodeToString(bytes);
    } catch (e) {
      return '';
    }
  }

  encode(text: string, charsetName: string): Uint8Array {
    if (charsetName === 'UTF-16') {
      // 与 core.encode("UTF-16") 一致：BOM(FE FF) + 大端
      const be: Uint8Array = util.TextEncoder.create('utf-16be').encode(text);
      const out: Uint8Array = new Uint8Array(be.length + 2);
      out[0] = 0xfe;
      out[1] = 0xff;
      out.set(be, 2);
      return out;
    }
    const labels: string[] = encoderLabels(charsetName);
    for (const label of labels) {
      try {
        const encoder = util.TextEncoder.create(label);
        return encoder.encode(text);
      } catch (e) {
        // 换下一个候选
      }
    }
    // 最后兜底：UTF-8（写不坏，只是编码声明不符时由调用方提示）
    return util.TextEncoder.create('utf-8').encode(text);
  }
}

function decoderLabels(charsetName: string): string[] {
  if (charsetName === 'GB18030') {
    return ['gb18030', 'gbk'];
  }
  if (charsetName === 'GBK') {
    return ['gbk'];
  }
  if (charsetName === 'Big5') {
    return ['big5'];
  }
  if (charsetName === 'UTF-16LE') {
    return ['utf-16le'];
  }
  if (charsetName === 'UTF-16BE') {
    return ['utf-16be'];
  }
  if (charsetName === 'ISO-8859-1') {
    return ['windows-1252', 'iso-8859-1'];
  }
  return ['utf-8'];
}

function encoderLabels(charsetName: string): string[] {
  if (charsetName === 'GB18030') {
    return ['gb18030', 'gbk', 'utf-8'];
  }
  if (charsetName === 'GBK') {
    return ['gbk', 'utf-8'];
  }
  if (charsetName === 'Big5') {
    return ['big5', 'utf-8'];
  }
  if (charsetName === 'UTF-16LE') {
    return ['utf-16le', 'utf-8'];
  }
  if (charsetName === 'UTF-16BE') {
    return ['utf-16be', 'utf-8'];
  }
  if (charsetName === 'ISO-8859-1') {
    return ['windows-1252', 'utf-8'];
  }
  return ['utf-8'];
}
