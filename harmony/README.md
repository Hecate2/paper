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
   不支持自绘，只能用“左侧行号列 + 右侧 TextArea”的近似实现，
   超大文本的只读预览用 `List` + 懒加载实现虚拟化（见 `pages/Index.ets` 注释）。
3. **编码**：`util.TextDecoder/TextEncoder` 支持 UTF-8 / GBK / Big5 /
   UTF-16LE-BE / Latin-1 等；`GB18030` 映射到 `gb18030`，运行环境不支持时
   回退 GBK（见 `core/EncodingDetector.ets`）。
4. **不申请网络权限**：与安卓版一致，`module.json5` 里没有任何网络权限。

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
hvigorw assembleHap --mode module    # 用 DevEco 自带的 hvigorw 全路径或 "$PATH" 里的
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`
（debug 未签名，可直接装模拟器；release 签名后同目录）。

```bash
# 4. 安装到模拟器/真机（hdc 在 SDK toolchains 目录下）
hdc list targets
hdc install entry/build/default/outputs/default/entry-default-unsigned.hap
hdc shell aa start -a EntryAbility -b io.github.hecate2.paper
```

签名：在 DevEco 里 `File > Project Structure > Signing Configs` 配好后，
`build-profile.json5` 的 `signingConfigs` 会自动填充；未签名也能出 debug 包。

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
2. 首次启动：同意协议 → 选主题 → 向导自动引导下载 **HarmonyOS SDK**
   （建议同时装 API 12 + API 13；本工程 target 为 `5.0.0(12)`）。
   macOS 默认 SDK 路径：`~/Library/HarmonyOS/Sdk`。
3. 如需命令行：下载中心的 **Command Line Tools** 解压后把
   `command-line-tools/bin` 加进 `PATH`，即得 `hvigorw` / `ohpm` / `hdc`。
4. 模拟器：`Tools > Device Manager > New Emulator` 创建 Phone 镜像，
   启动后 `hdc list targets` 能看到 `emulator-...` 即成功。
5. 用 DevEco 打开本仓库的 `harmony/` 目录（以它为工程根），Sync 后点运行；
   或按上一节的命令行方式构建安装。

## 版本

- versionName `1.0.0` / versionCode `1000000`，bundleName
  `io.github.hecate2.paper`（与安卓 `applicationId` 相同）。
- targetSdk `5.0.0(12)`，兼容到 `5.0.0(12)`。

## 首次在 DevEco 构建时的核对清单

本工程在 Mac 上已用 `tsc --strict` 校验过全部 `core/*.ets`（零错误），
用 Node 跑通 104 项单测，并已用 DevEco 26 命令行完整构建出 HAP
（`entry-default-unsigned.hap`，约 431 KiB）。剩余 57 个 warning
多为 `getContext` / `router.back`  deprecation，不影响构建，后续再迁移。
真机/模拟器上的运行时验证（分享接收、Picker 授权、GBK 编解码）待补。
