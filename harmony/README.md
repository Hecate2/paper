# 白纸 / paper · 鸿蒙版（HarmonyOS NEXT）

安卓版见仓库根目录（`app/` + Gradle）；本目录 `harmony/` 是鸿蒙复刻版，
Stage 模型 + ArkTS + ArkUI，与安卓版同仓库、分目录存放。

## 功能对照（与安卓版 `README.md` / `DESIGN.md` 一致）

- 编辑：打开/编辑/保存任意文本文件；一键新建空草稿；一键保存/关闭；
  点击标题重命名；另存为；恢复 `.bak` 备份
- 查找替换：区分大小写、全词匹配、正则，替换单个 / 全部（`core/SearchEngine.ets`）
- 编码自动识别 + 手动切换（`core/EncodingDetector.ets`，`util.TextDecoder/TextEncoder`）
- 自动保存（默认关闭，任意秒数）、字号 8–96sp、行号开关、自动换行开关、
  光标所在行高亮
- 启动：新建空文件 / 上次打开的文件 / 上次使用的目录，可跳回上次编辑行号
  （`core/StartupDecision.ets`）
- 目录浏览：大小/修改时间、按名称/大小/时间/类型排序（升/降序）、
  当前目录内搜索（支持正则）、后台一次性列举（`pages/Browser.ets`）
- 安全：临时文件 → 落盘 → `.bak` → 原子重命名；大文件/二进制只读预览
  （`model/FileService.ets` + `core/FileSizePolicy.ets`）
- 分享：其他应用分享文本/文件可进入本应用（`EntryAbility` + Share Kit）

## 与安卓版必然不同的地方（平台限制，如实说明）

1. **没有“所有文件访问”权限。** 鸿蒙 NEXT 应用只能读写自己的沙箱，
   访问用户文件必须走系统选择器（`picker.DocumentViewPicker` 的
   `select()` / `save()`），拿到的是带临时授权的 URI。
   因此“真实路径浏览任意目录”复刻为：
   - 浏览器默认展示应用沙箱目录（`filesDir`）内的文件，排序/搜索行为不变；
   - “打开任意文件”“保存/另存为到任意位置”走系统 Picker；
   - 拿到持久化授权（`fileShare.persistPermission`）的 URI 会被记住，
     下次启动可直接 reopen（对应“记住上次打开的文件”）。
2. **行号栏与当前行高亮**：安卓版是 `EditText` 自绘；ArkUI 的 `TextArea`
   不支持自绘，可编辑区改用底部状态条“共 N 行 · 第 K 行”（K 由
   `onTextSelectionChange` 实时跟随光标），行号开关控制其显隐；
   超大文本的只读预览用 `List` + 懒加载实现虚拟化，左侧仍是行号列，
   查找命中按行底色标出（当前命中绿、其余黄，见 `refreshViewerMarks`），
   对应安卓 `VirtualTextView` 的区间底色（Text 不支持区间背景，按行近似）。
3. **查找高亮**：可编辑区（TextArea）不支持区间底色，只显示计数并
   用 `setTextSelection` 选中当前命中；只读预览有按行高亮（上一项）。
4. **自动换行**：ArkUI 的 `TextArea` 恒为软换行（没有横向滚动开关），
   因此「自动换行」设置只作用于只读预览的列表；设置页标签也写明了
   “（只读预览）”。
5. **编码**：`util.TextDecoder/TextEncoder` 支持 UTF-8 / GBK / Big5 /
   UTF-16LE-BE / Latin-1 等；`GB18030` 映射到 `gb18030`，运行环境不支持时
   回退 GBK（见 `core/EncodingDetector.ets`）。
6. **不申请网络权限**：与安卓版一致，`module.json5` 里没有任何网络权限。

## 目录结构

```
harmony/
  AppScope/                 应用全局配置（bundleName/图标/全局字符串颜色）
  entry/                    主模块（编译出 HAP）
    src/main/ets/
      entryability/EntryAbility.ets   应用入口 + 分享 Want 接收
      pages/Index.ets                 编辑器
      pages/Browser.ets               目录浏览器
      pages/Settings.ets              设置页
      core/                           与 ArkUI 无关的纯逻辑（可单测）
        SearchEngine.ets  EncodingDetector.ets  FileSizePolicy.ets
        SaveNames.ets  StartupDecision.ets
      model/                          平台相关：Prefs / FileService / Types
    src/main/module.json5   模块配置（abilities/skills/权限）
    src/main/resources/...  字符串/颜色/路由表
  hvigor/  build-profile.json5  hvigorfile.ts  oh-package.json5
  tests/                    Node 可直接运行的 core 单测（见 tests/README.md）
```

## 构建与运行（需要 DevEco Studio + 鸿蒙 SDK）

已在 Mac + DevEco 26.0.0（内嵌 SDK HarmonyOS 26.0.0 / API 26）上验证通过。
前置：JDK 17（`JAVA_HOME`）、Node（DevEco 自带 `tools/node` 即可）、
`~/.npmrc` 配好 `@ohos` 私服（见下）。

```bash
cd harmony
# 1. 环境变量（实测必须，local.properties 在此工具链下不生效）
export JAVA_HOME=/Users/xinghao/.local/share/temurin-17.jdk/Contents/Home
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_BASE_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk

# 2. 私服（~/.npmrc，用户级，只需配一次；hvigor 拉 @ohos/hvigor-ohos-plugin 用）
# registry=https://registry.npmjs.org/
# @ohos:registry=https://repo.harmonyos.com/npm/

# 3. 构建（--mode 指执行范围 module/project；debug 为默认 buildMode）
hvigorw assembleHap --mode module                 # debug：带 sourceMap，约 549KB
hvigorw assembleHap --mode module -p buildMode=release  # release：约 236KB，交付用这个
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`
（hvigor 只出未签名包，签名由下面的 `tools/sign-release.sh` 补做；
debug/release 同名，后一次构建会覆盖）。

## 安装包体积分析（2026-10-11 实测，release 未签名 HAP 236,187 B）

解包构成（未压缩即此数，HAP 内文件均为 stored）：

| 内容 | 大小 | 占比 | 说明 |
|---|---|---|---|
| `ets/modules.abc` | 195,376 B | 83% | Ark 字节码，零第三方依赖，全是本应用代码 |
| `resources/base/media/app_icon.png` | 27,737 B | 12% | 192px 图标，已用 `tools/optpng.py` 无损压过（39KB→27KB） |
| 20 个 SVG 图标 | 约 3.5KB | 1.5% | 平均 200B/个 |
| `resources.index` / `module.json` / `pack.info` 等 | 约 6KB | 2.5% | 打包必需元数据 |

结论：无冗余。`sourceMaps.map`（173KB）只出现在 debug 包；AppScope 与
entry 的图标在包内只存一份；无 `oh_modules`、无构建中间物。
和安卓（R8 后 APK 64KB）的差距主要来自 Ark 字节码本身更 verbose，
鸿蒙侧没有 R8 可用，这已是实用下限（再压只能降图标分辨率，得不偿失）。
debug 包 548,895 B（`modules.abc` 335KB + `sourceMaps.map` 173KB），
仅用于调试，不交付。

```bash
# 4. 签名（首次运行会自建签名材料，之后只做签名）
bash tools/sign-release.sh

# 5. 安装到模拟器/真机（hdc 在 SDK toolchains 目录下）
hdc list targets
hdc install entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b io.github.hecate2.paper
```

签名产物 `entry-default-signed.hap`（284,077 B，比未签名包大 47,890 B，
即签名块本身）。debug 包也能签，只是文件名同样叫 `entry-default-signed.hap`，
后一次构建会覆盖，所以交付前跑一次 release 构建再签。

## 签名（为什么安卓那把钥匙不能用）

鸿蒙只接受 ECDSA 签名。安卓的 `release.jks` 是 RSA-4096，官方签名工具直接拒绝：

```
$ java -jar hap-sign-tool.jar sign-app ... -signAlg SHA256withRSA ...
ERROR: 11011002 {SignAlg} param is incorrect
Error Message: signature algorithms include SHA256withECDSA,SHA384withECDSA
```

`generate-app-cert` 与 `generate-profile-cert` 同样只收 ECDSA。
hvigor 的 `build-profile.json5` schema 里 `signAlg` 的 enum 也只有
`SHA256withECDSA` 一个值。所以这把钥匙在鸿蒙侧没有任何可用路径，
只能另建一套。

`tools/sign-release.sh` 建的是三级链，跟 OpenHarmony 官方工具的默认结构一致：

| 角色 | 算法 | 用途 |
|---|---|---|
| `root-ca` | RSA-4096 / SHA384withRSA | 自签根 |
| `sub-app-ca` | RSA-4096 / SHA384withRSA | 应用签名中间 CA |
| `sub-profile-ca` | RSA-4096 / SHA384withRSA | profile 签名中间 CA |
| `app` | **ECC P-256 / SHA256withECDSA** | 应用签名密钥 |
| `profile` | **ECC P-384 / SHA384withECDSA** | profile 签名密钥 |

脚本还负责把应用证书和 `bundleName` 写进 profile 并签成 `.p7b`
（hvigor 的 `signingConfigs` 也强制要求这个字段），
最后自动跑一遍 `verify-app` 确认签名有效。
`bundleName` 与 `compatibleVersion` 都从 `AppScope/app.json5`
和 `build-profile.json5` 读，不写死在脚本里。

材料落在 `harmony/signing/`，含私钥，已在 `.gitignore` 中。
换机器或材料丢失时删掉该目录重跑脚本即可，会生成新的一套。

需要上架 AppGallery 时，这套自签材料不能用，得换成华为开发者账号下发的
正式签名材料（`.cer` + `.p7b`），脚本里替换 `app-release.cer`
与 `profile.p7b` 两个文件即可。

## 纯逻辑单测（不需要 SDK，本机可跑）

```bash
cd harmony/tests
node run_core_tests.mjs
```

原理：`core/*.ets` 只用可擦除的 TypeScript 语法（无 ArkUI 导入），
测试脚本把它们拷为 `.ts` 后用 Node 22 的类型剥离直接执行断言。
用例与安卓版 `app/src/test` 的 99 个测试一一对应。

## Mac 安装 DevEco / SDK / 模拟器

> 以下步骤是标准流程；本仓库的鸿蒙工程就是按此流程可构建、可装机验证的。
> 模拟器镜像、SDK 都需要**华为开发者账号登录**后下载（约 2–4 GB + 模拟器数 GB），
> 且首次启动要在 IDE 里同意许可协议——这几步需要人工在图形界面完成，
> 无法只用命令行静默装完。

1. 到 [HarmonyOS 应用开发者官网](https://developer.huawei.com/consumer/cn/)
   下载 **DevEco Studio** Mac 版（支持 Apple Silicon），拖进 `/Applications`。
2. 首次启动：同意协议 → 选主题 → 向导自动引导下载 **HarmonyOS SDK**。
   本工程用 DevEco 自带的 HarmonyOS 26.0.0 SDK 编译，
   `compatibleSdkVersion` 写 `5.0.1(13)`，因此**无需额外下载旧版 SDK**。
3. 如需命令行：下载中心的 **Command Line Tools** 解压后把
   `command-line-tools/bin` 加进 `PATH`，即得 `hvigorw` / `ohpm` / `hdc`。
4. 模拟器：`Tools > Device Manager > New Emulator` 创建 Phone 镜像，
   启动后 `hdc list targets` 能看到 `emulator-...` 即成功。
5. 用 DevEco 打开本仓库的 `harmony/` 目录（以它为工程根），Sync 后点运行；
   或按上一节的命令行方式构建安装。

## 版本

- versionName `1.0.0` / versionCode `1000000`，bundleName
  `io.github.hecate2.paper`（与安卓 `applicationId` 相同）。
- 用 DevEco 自带 SDK（HarmonyOS 26.0.0 / API 26）编译，
  `compatibleSdkVersion` 为 `5.0.1(13)`：HAP 的 `minAPIVersion=50001013`，
  可直接安装到 HarmonyOS 5.0.1（API 13）模拟器。
- `targetSdkVersion` 仍为 26.0.0（只影响目标行为，不影响安装）。

## 模拟器实测记录（HarmonyOS 5.0.1 / API 13，hdc + uitest 驱动）

已验证：

- 构建、安装（`hdc install -r`）、冷启动后按设置恢复上次文件
- 编辑后标题出现“ •”；状态条行号随光标/输入实时更新
- 查找：查找栏开关/聚焦、计数（如 `1/1`）、命中跳转与选中
- 系统返回键：先关查找栏；有未保存修改时弹「保存并关闭/不保存/取消」
- “打开方式”/分享进来（`aa start -A ohos.want.action.viewData -U file://docs/…`）：
  应用运行中收到 Want 经 `eventHub` 立即打开该 URI 文件
- 只读预览：二进制文件进入只读模式，保存/重命名禁用，横幅提示正确，
  行号列 + 查找命中行高亮（当前命中 `#554CAF50`）
- 目录浏览器：单行名称+大小/时间、当前目录搜索（含 `.*` 正则开关）、
  过滤底栏提示、清空按钮显示逻辑
- 设置页：三个启动选项、记住行号、自动保存秒数、字号滑块、行号/换行开关、
  默认编码下拉
- 保存全链路（字节级校验）：首次保存落盘内容正确；二次保存产生 `.bak`
  且内容为上一版；同名保存弹覆盖确认，确认后文件/`.bak` 双双正确；
  覆盖/关闭/恢复备份等确认框的按钮均可点、均可关
- 异常路径（`tools/robust.py` A–J，一部分需可写沙箱，见下）：
  已在真机逻辑 + 单测覆盖：退出删文件/删目录的回退（`StartupDecision`
  99 项单测对应用例）、外部删除后保存重建、重命名冲突不覆盖、
  二进制只读、无备份恢复提示、空文件名/非法字符拒绝

大文件（2026-10-11）：`core` 单测里 2MB 查找约 2ms、20 万命中替换约
17ms；5MB/100MB/10MB 三档分层阈值与安卓逐字一致；
单行显示上限 20000 字（`MAX_LINE_SPAN`，与安卓 `VirtualTextView` 同值），
超限只截显示、永不写回。真机 MB 级端到端压测脚本在
`tests/e2e/growth.sh`（替换放大构造大文件），待模拟器空闲时跑。

仍需真机/交互式验证（命令行无法覆盖）：

- 系统 Picker 的 select/save 全流程与持久化授权（`persistPermission`）
- 非 UTF-8（GBK/Big5 等）文件的读写往返（解码侧已单测，真机编码侧待验）
- 其他应用主动分享（`sendData`）的真机弹窗与参数形态
- 向沙箱注入超大文件的端到端（shell 写受限镜像上放不进去；
  当前用 `growth.sh` 在应用内构造 MB 级内容测同链路）
