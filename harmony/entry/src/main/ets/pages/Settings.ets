import { router } from '@kit.ArkUI';

/**
 * 设置页骨架。完整实现见后续提交（启动模式/自动保存/字号/行号/换行/编码）。
 */
@Entry
@Component
struct Settings {
  build(): void {
    Column() {
      Text($r('app.string.settings_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48, bottom: 16 });
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
