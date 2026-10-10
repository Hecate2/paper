import { router } from '@kit.ArkUI';

/**
 * 目录浏览器页骨架。完整实现见后续提交（沙箱列举/排序/搜索/Picker）。
 */
@Entry
@Component
struct Browser {
  @State path: string = '';

  build(): void {
    Column() {
      Text($r('app.string.browser_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48, bottom: 8 });
      Text(this.path === '' ? '（沙箱目录）' : this.path)
        .fontSize(12)
        .fontColor($r('app.color.gutter_text'))
        .margin({ bottom: 16 });
      Button('返回')
        .onClick(() => {
          router.back();
        });
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center);
  }
}
