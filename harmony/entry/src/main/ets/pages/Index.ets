import { router } from '@kit.ArkUI';

/**
 * 编辑器页骨架。完整实现见后续提交（编辑/保存/查找/编码/自动保存/启动路由），
 * 此骨架保证工程可 Sync、可预览、可路由跳转。
 */
@Entry
@Component
struct Index {
  @State title: string = '白纸';

  build(): void {
    Column() {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48, bottom: 16 });
      Text('鸿蒙版编辑器加载中…')
        .fontSize(14)
        .fontColor($r('app.color.gutter_text'));
      Row({ space: 12 }) {
        Button($r('app.string.menu_open'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/Browser' });
          });
        Button($r('app.string.menu_settings'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/Settings' });
          });
      }.margin({ top: 24 });
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center);
  }
}
