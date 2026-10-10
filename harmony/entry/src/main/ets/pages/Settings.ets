import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Prefs, MIN_FONT_SIZE, MAX_FONT_SIZE } from '../model/Prefs.ets';
import { MODE_NEW_EMPTY, MODE_LAST_FILE, MODE_LAST_DIR } from '../core/StartupDecision.ets';
import { USER_CHOICES, labelOf } from '../core/EncodingDetector.ets';

/** 浅色界面正文色（安卓 textColorPrimary = #DE000000）与禁用色（#42000000）。 */
const TEXT_PRIMARY: string = '#DE000000';
const TEXT_DISABLED: string = '#42000000';

/**
 * 设置页（对应安卓版 SettingsActivity）。
 * 每个控件直写 Prefs，即改即记；编辑器在 onPageShow 重读应用。
 *
 * 尺寸照安卓 activity_settings.xml 实测（density 2.75）：页内边距 16dp、
 * 分组标题 15sp 加粗且段间距 16dp、单选项文字 16sp（行高 32dp）、复选行 32dp
 * （“记住上次编辑的行号”左缩 12dp）、复选文字 15sp/14sp、数字框 72×41dp、
 * 字号滑杆 18dp 高、编码下拉 48dp 高且右侧是下拉三角（Spinner 外观）。
 * 安卓的 RadioButton/CheckBox 点标签也会切换，这里给整行加 onClick 保持一致。
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

  private pickStartup(mode: string): void {
    this.startup = mode;
    this.prefs?.setStartupMode(mode);
  }

  /** 分组标题：15sp 加粗、段间距 16dp（首组由页内边距给出）。 */
  @Builder
  sectionLabel(text: string, top: number) {
    Text(text)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT_PRIMARY)
      .width('100%')
      .margin({ top: top });
  }

  /** 编码下拉菜单（安卓 Spinner 的下拉列表，48dp 行高、16sp）。 */
  private encodingMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (let i: number = 0; i < USER_CHOICES.length; i++) {
      const idx: number = i;
      items.push({
        value: labelOf(USER_CHOICES[idx]),
        action: (): void => {
          this.encodingIdx = idx;
          this.prefs?.setDefaultEncoding(USER_CHOICES[idx]);
        }
      });
    }
    return items;
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
          this.sectionLabel('启动时打开', 0);
          Row({ space: 0 }) {
            Radio({ value: 'new', group: 'startup' })
              .checked(this.startupIndex() === 0)
              .radioStyle({ checkedBackgroundColor: $r('app.color.brand') })
              .width(20)
              .height(20)
              .onChange((on: boolean): void => {
                if (on) {
                  this.pickStartup(MODE_NEW_EMPTY);
                }
              });
            Text('新的空文件').fontSize(16).fontColor(TEXT_PRIMARY).layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .margin({ top: 4 })
          .onClick((): void => {
            this.pickStartup(MODE_NEW_EMPTY);
          });
          Row({ space: 0 }) {
            Radio({ value: 'file', group: 'startup' })
              .checked(this.startupIndex() === 1)
              .radioStyle({ checkedBackgroundColor: $r('app.color.brand') })
              .width(20)
              .height(20)
              .onChange((on: boolean): void => {
                if (on) {
                  this.pickStartup(MODE_LAST_FILE);
                }
              });
            Text('上次打开的文件').fontSize(16).fontColor(TEXT_PRIMARY).layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .onClick((): void => {
            this.pickStartup(MODE_LAST_FILE);
          });
          Row({ space: 0 }) {
            Radio({ value: 'dir', group: 'startup' })
              .checked(this.startupIndex() === 2)
              .radioStyle({ checkedBackgroundColor: $r('app.color.brand') })
              .width(20)
              .height(20)
              .onChange((on: boolean): void => {
                if (on) {
                  this.pickStartup(MODE_LAST_DIR);
                }
              });
            Text('上次使用的目录').fontSize(16).fontColor(TEXT_PRIMARY).layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .onClick((): void => {
            this.pickStartup(MODE_LAST_DIR);
          });
          // 只在“上次打开的文件”下有意义，所以跟随该选项启用/禁用
          Row({ space: 0 }) {
            Checkbox()
              .select(this.rememberLine)
              .selectedColor($r('app.color.brand'))
              .width(20)
              .height(20)
              .enabled(this.startup === MODE_LAST_FILE)
              .id('rememberLineCheck')
              .onChange((on: boolean): void => {
                this.rememberLine = on;
                this.prefs?.setRememberLastLine(on);
              });
            Text('记住上次编辑的行号')
              .fontSize(14)
              .fontColor(this.startup === MODE_LAST_FILE ? TEXT_PRIMARY : TEXT_DISABLED)
              .layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .margin({ left: 12 })
          .onClick((): void => {
            if (this.startup !== MODE_LAST_FILE) {
              return;
            }
            this.rememberLine = !this.rememberLine;
            this.prefs?.setRememberLastLine(this.rememberLine);
          });

          this.sectionLabel('自动保存间隔', 16);
          // 任意秒数，0 = 关闭（安卓：72×41dp 数字输入框 + “s” + 灰色说明）
          Row({ space: 0 }) {
            TextInput({ placeholder: '0', text: this.autosave })
              .inputFilter('[0-9]', (): void => {})
              .maxLength(6)
              .width(72)
              .height(41)
              .fontSize(15)
              .id('autosaveInput')
              .onChange((v: string): void => {
                this.autosave = v;
                const n: number = parseInt(v.trim(), 10);
                if (!isNaN(n)) {
                  this.prefs?.setAutosaveIntervalSec(n);
                }
              });
            Text('s').fontSize(15).fontColor(TEXT_PRIMARY).margin({ left: 6 });
            Text('0 = 关闭').fontSize(12).fontColor('#FF888888').margin({ left: 8 });
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 4 });

          this.sectionLabel('文字大小: ' + this.fontSize + 'sp', 16);
          Slider({ value: this.fontSize, min: MIN_FONT_SIZE, max: MAX_FONT_SIZE, step: 1 })
            .width('100%')
            .height(20)
            .selectedColor($r('app.color.brand'))
            .id('fontSlider')
            .margin({ top: 4 })
            .onChange((v: number): void => {
              this.fontSize = Math.round(v);
              this.prefs?.setFontSizeSp(Math.round(v));
            });

          Row({ space: 0 }) {
            Checkbox()
              .select(this.showNumbers)
              .selectedColor($r('app.color.brand'))
              .width(20)
              .height(20)
              .id('lineNumbersCheck')
              .onChange((on: boolean): void => {
                this.showNumbers = on;
                this.prefs?.setShowLineNumbers(on);
              });
            Text('显示行号').fontSize(15).fontColor(TEXT_PRIMARY).layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .margin({ top: 12 })
          .onClick((): void => {
            this.showNumbers = !this.showNumbers;
            this.prefs?.setShowLineNumbers(this.showNumbers);
          });
          Row({ space: 0 }) {
            Checkbox()
              .select(this.wordWrap)
              .selectedColor($r('app.color.brand'))
              .width(20)
              .height(20)
              .id('wordWrapCheck')
              .onChange((on: boolean): void => {
                this.wordWrap = on;
                this.prefs?.setWordWrap(on);
              });
            Text('自动换行').fontSize(15).fontColor(TEXT_PRIMARY).layoutWeight(1);
          }
          .width('100%')
          .height(32)
          .onClick((): void => {
            this.wordWrap = !this.wordWrap;
            this.prefs?.setWordWrap(this.wordWrap);
          });

          this.sectionLabel('默认编码', 16);
          // 安卓 Spinner：48dp 行高、选中项 16sp 左对齐、右侧 24dp 下拉三角
          Row({ space: 0 }) {
            Text(labelOf(USER_CHOICES[this.encodingIdx]))
              .fontSize(16)
              .fontColor(TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Image($r('app.media.ic_spinner_caret_b')).width(24).height(24).margin({ right: 12 });
          }
          .width('100%')
          .height(48)
          .margin({ top: 4 })
          .id('encodingSpinner')
          .bindMenu(this.encodingMenuItems());
        }
        .width('100%')
        .padding(16);
      }
      .align(Alignment.TopStart)
      .layoutWeight(1)
      .width('100%');
    }.width('100%').height('100%').backgroundColor($r('app.color.page_bg'));
  }
}
