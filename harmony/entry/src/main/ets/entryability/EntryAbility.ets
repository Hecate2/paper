import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PaperEntryAbility';

/**
 * 应用入口。职责：
 * 1. 创建窗口并加载编辑器页（pages/Index）；
 * 2. 接收其他应用的分享 Want（skills 里声明了 ohos.want.action.sendData），
 *    把携带的文本/URI 存入 AppStorage，编辑器页在 aboutToAppear 中消费。
 *
 * 对应安卓版 MainActivity.handleShareIntent() / consumeShare()。
 * 各家分享方塞参数的键不完全一致，这里把 Want 参数全量转存，
 * 由 Index 页做多键兼容解析（见 Index.ets consumeShare），
 * 解析不到就忽略并正常进编辑器，绝不崩。
 */
export default class EntryAbility extends UIAbility {
  private windowStage?: window.WindowStage;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.rememberShareWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    this.rememberShareWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    windowStage.loadContent('pages/Index', (err): void => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
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
   * 只记录“这次启动是否携带了可分享的内容”+ 全量参数快照。
   * 真正的解析在 Index 页做，避免阻塞 ability 启动。
   */
  private rememberShareWant(want: Want | null | undefined): void {
    try {
      if (want === null || want === undefined) {
        return;
      }
      const action: string = (want.action as string) ?? '';
      if (action !== 'ohos.want.action.sendData' && action !== 'ohos.want.action.viewData') {
        return;
      }
      const params = want.parameters ?? {};
      AppStorage.setOrCreate('paperHasShare', true);
      AppStorage.setOrCreate('paperShareAction', action);
      AppStorage.setOrCreate('paperShareParams', JSON.stringify(params));
      hilog.info(DOMAIN, TAG, 'share want remembered');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'rememberShareWant failed: %{public}s', String(e));
    }
  }
}
