import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'PaperEntryAbility';

/**
 * 应用入口。职责：
 * 1. 创建窗口并加载编辑器页（pages/Index）；
 * 2. 接收其他应用的分享 Want（action.sendData / VIEW），把携带的文本或
 *    文件 URI 存入 AppStorage，编辑器页在 aboutToAppear 中消费。
 *
 * 对应安卓版 MainActivity.handleShareIntent() / consumeShare()。
 * 鸿蒙侧分享数据用 Share Kit（systemShare.getSharedData）解析，
 * 文件走 picker URI + fileShare 持久化授权（见 model/FileService.ets）。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: unknown): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.rememberShareWant(want);
  }

  onNewWant(want: Want, launchParam: unknown): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    this.rememberShareWant(want);
    const win = this.windowStage?.getMainWindowSync();
    win?.setUiContent?.('pages/Index');
  }

  private windowStage?: window.WindowStage;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `loadContent failed: ${JSON.stringify(err)}`);
      }
    });
  }

  onWindowStageDestroy(): void {
    this.windowStage = undefined;
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }

  /**
   * 只记录“这次启动是否携带了可分享的内容”，真正的解析（读文本 / 取 URI）
   * 在 Index 页用 Share Kit 异步做，避免阻塞 ability 启动。
   * 对应安卓版 carriesContent() 的判定。
   */
  private rememberShareWant(want: Want): void {
    const action: string = (want?.action as string) ?? '';
    const hasText: boolean =
      (want?.parameters as Record<string, unknown> | undefined)?.['ohos.extra.param.key.text'] !== undefined;
    const hasUris: boolean =
      (want?.parameters as Record<string, unknown> | undefined)?.['ohos.extra.param.key.uris'] !== undefined;
    const carried: boolean =
      action === 'ohos.want.action.sendData' && (hasText || hasUris);
    try {
      // AppStorage 供 Index 页读取；读完即清零，避免重复消费。
      // @ts-ignore: AppStorage.setOrCreate 为 ArkUI 运行时 API
      (globalThis as Record<string, unknown>).__paperShareFlag = carried;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `rememberShareWant failed: ${String(e)}`);
    }
  }
}
