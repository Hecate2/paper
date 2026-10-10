import { MeasureText } from '@kit.ArkUI';

/**
 * 中间省略：安卓用 TextView 的 TruncateAt.MIDDLE（编辑器顶栏标题、浏览器行名）。
 * ArkUI 的 textOverflow 只有尾部省略，这里按实际可用宽度用 MeasureText 逐字收缩，
 * 首尾都保留、中间打点，效果与安卓一致。
 *
 * @param text 原文
 * @param availVp 可用宽度（vp）；<= 8 视为未测量到，直接返回原文
 * @param fontSize 字号（fp），与绘制时一致
 */
export function fitMiddle(text: string, availVp: number, fontSize: number): string {
  if (availVp <= 8 || text.length < 5) {
    return text;
  }
  try {
    const maxPx: number = vp2px(availVp);
    const measure: (s: string) => number = (s: string): number =>
      MeasureText.measureText({ textContent: s, fontSize: fontSize });
    if (measure(text) <= maxPx) {
      return text;
    }
    let keep: number = text.length - 1;
    while (keep > 1) {
      const left: number = Math.ceil(keep / 2);
      const cand: string = text.substring(0, left) + '…' +
        text.substring(text.length - (keep - left));
      if (measure(cand) <= maxPx) {
        return cand;
      }
      keep--;
    }
    return '…';
  } catch (e) {
    return text;
  }
}

/** 文本宽度（vp，按 fp 字号）；测量失败时返回 0（调用方按“放得下”处理）。 */
export function textWidthVp(text: string, fontSize: number): number {
  try {
    return px2vp(MeasureText.measureText({ textContent: text, fontSize: fontSize }));
  } catch (e) {
    return 0;
  }
}
