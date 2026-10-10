import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Prefs, MIN_FONT_SIZE, MAX_FONT_SIZE } from '../model/Prefs.ets';
import { MODE_NEW_EMPTY, MODE_LAST_FILE, MODE_LAST_DIR } from '../core/StartupDecision.ets';
import { USER_CHOICES, labelOf } from '../core/EncodingDetector.ets';

/**
 * 设置页（对应安卓版 SettingsActivity）。
 * 每个控件直写 Prefs，即改即记；编辑器在 onPageShow 重读应用。
 */
@Entry
@Component
struct Settings {
  @State startup: string = MODE_LAST_FILE;
  @State rememberLine: boolean = true;
  @State autosave: string = '0';
  @State fontSize: number = 16;
  @State showNumbers: boolean = true;
  @State wordWrap: boolean = true;
  @State encodingIdx: number = 0;

  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.prefs = new Prefs(ctx);
    this.startup = this.prefs.startupMode();
    this.rememberLine = this.prefs.rememberLastLine();
    this.autosave = String(this.prefs.autosaveIntervalSec());
    this.fontSize = this.prefs.fontSizeSp();
    this.showNumbers = this.prefs.showLineNumbers();
    this.wordWrap = this.prefs.wordWrap();
    const cur: string = this.prefs.defaultEncoding();
    for (let i: number = 0; i < USER_CHOICES.length; i++) {
      if (USER_CHOICES[i] === cur) {
        this.encodingIdx = i;
        break;
      }
    }
  }

  private startupIndex(): number {
    if (this.startup === MODE_NEW_EMPTY) {
      return 0;
    }
    if (this.startup === MODE_LAST_DIR) {
      return 2;
    }
    return 1;
  }

  build() {
    Column({ space: 0 }) {
      // 顶栏（对齐安卓 DarkActionBar：home 图标格 56×56dp、标题 20sp 左缩 72dp，无其他动作）
      Row({ space: 0 }) {
        Column() {
          Image($r('app.media.ic_arrow_back_w')).width(24).height(24);
        }
        .width(56)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .id('settingsBack')
        .onClick((): void => {
          router.back();
        });
        Text('设置')
          .fontSize(20)
          .fontColor($r('app.color.white'))
          .margin({ left: 16 })
          .layoutWeight(1)
          .maxLines(1)
          .id('settingsTitle');
      }
      .backgroundColor($r('app.color.action_bar'))
      .width('100%')
      .height(56);

      Scroll() {
        Column({ space: 0 }) {
          // 启动时打开（对齐 activity_settings.xml 分组与顺序）
          Text('启动时打开').fontSize(15).fontWeight(FontWeight.Bold).width('100%');
          Row({ space: 12 }) {
            Radio({ value: 'new', group: 'startup' })
              .checked(this.startupIndex() === 0)
              .onChange((on: boolean): void => {
                if (on) {
                  this.startup = MODE_NEW_EMPTY;
                  this.prefs?.setStartupMode(MODE_NEW_EMPTY);
                }
              });
            Text('新的空文件').fontSize(15);
          }.margin({ top: 4 });
          Row({ space: 12 }) {
            Radio({ value: 'file', group: 'startup' })
              .checked(this.startupIndex() === 1)
              .onChange((on: boolean): void => {
                if (on) {
                  this.startup = MODE_LAST_FILE;
                  this.prefs?.setStartupMode(MODE_LAST_FILE);
                }
              });
            Text('上次打开的文件').fontSize(15);
          }
          Row({ space: 12 }) {
            Radio({ value: 'dir', group: 'startup' })
              .checked(this.startupIndex() === 2)
              .onChange((on: boolean): void => {
                if (on) {
                  this.startup = MODE_LAST_DIR;
                  this.prefs?.setStartupMode(MODE_LAST_DIR);
                }
              });
            Text('上次使用的目录').fontSize(15);
          }
          Row({ space: 12 }) {
            Checkbox()
              .select(this.rememberLine)
              .enabled(this.startup === MODE_LAST_FILE)
              .id('rememberLineCheck')
              .onChange((on: boolean): void => {
                this.rememberLine = on;
                this.prefs?.setRememberLastLine(on);
              });
            Text('记住上次编辑的行号').fontSize(14)
              .opacity(this.startup === MODE_LAST_FILE ? 1 : 0.4);
          }.margin({ left: 12 });

          Text('自动保存间隔').fontSize(15).fontWeight(FontWeight.Bold).width('100%')
            .margin({ top: 16 });
          Row({ space: 6 }) {
            TextInput({ placeholder: '0', text: this.autosave })
              .inputFilter('[0-9]', (): void => {})
              .width(72)
              .fontSize(15)
              .id('autosaveInput')
              .onChange((v: string): void => {
                this.autosave = v;
                const n: number = parseInt(v.trim(), 10);
                if (!isNaN(n)) {
                  this.prefs?.setAutosaveIntervalSec(n);
                }
              });
            Text('s').fontSize(15);
            Text('0 = 关闭').fontSize(12).fontColor('#FF888888').margin({ left: 8 });
          }.margin({ top: 4 });

          Text('文字大小：' + this.fontSize + 'sp').fontSize(15).fontWeight(FontWeight.Bold)
            .width('100%')
            .margin({ top: 16 });
          Slider({ value: this.fontSize, min: MIN_FONT_SIZE, max: MAX_FONT_SIZE, step: 1 })
            .width('100%')
            .id('fontSlider')
            .onChange((v: number): void => {
              this.fontSize = Math.round(v);
              this.prefs?.setFontSizeSp(Math.round(v));
            });

          Row({ space: 12 }) {
            Checkbox()
              .select(this.showNumbers)
              .id('lineNumbersCheck')
              .onChange((on: boolean): void => {
                this.showNumbers = on;
                this.prefs?.setShowLineNumbers(on);
              });
            Text('显示行号').fontSize(15);
          }.margin({ top: 12 });
          Row({ space: 12 }) {
            Checkbox()
              .select(this.wordWrap)
              .id('wordWrapCheck')
              .onChange((on: boolean): void => {
                this.wordWrap = on;
                this.prefs?.setWordWrap(on);
              });
            Text('自动换行').fontSize(15);
          }

          Text('默认编码').fontSize(15).fontWeight(FontWeight.Bold).width('100%')
            .margin({ top: 16 });
          Select(USER_CHOICES.map((c: string): SelectOption => {
            return { value: labelOf(c) };
          }))
            .selected(this.encodingIdx)
            .width('100%')
            .id('encodingSelect')
            .onSelect((index: number): void => {
              this.encodingIdx = index;
              this.prefs?.setDefaultEncoding(USER_CHOICES[index]);
            });
        }
        .width('100%')
        .padding(16);
      }
      .layoutWeight(1)
      .width('100%');
    }.width('100%').height('100%').backgroundColor($r('app.color.page_bg'));
  }
}
