# 白纸 / paper

<img src="icon.png" alt="白纸图标" width="160" height="160" />

轻量安卓文本编辑器：**快速打开、编辑、保存手机内任意文本文件**。

零第三方运行时依赖，纯 Java + 框架控件；release APK 约 **64 KiB**。

---

## 特点

**编辑**
- 打开/编辑/保存任意真实路径的文本文件，不限制后缀
- 一键新建空草稿、一键保存、一键关闭；点击标题即可重命名
- 另存为、恢复 `.bak` 备份
- 查找替换：区分大小写、全词匹配、正则表达式，支持替换单个 / 全部
- 编码自动识别，也可手动选择常见编码
- 自动保存（**默认关闭**，可自行设置任意秒数）
- 字号 8–96sp、行号开关、自动换行开关、光标所在行高亮

**启动**
- 三种启动方式：新建空文件 / 上次打开的文件 / 上次使用的目录
- 选择"上次打开的文件"时，可另外记住并**直接跳回上次编辑的行号**

**目录浏览**
- 真实路径浏览，显示文件大小与修改时间
- 按名称 / 大小 / 时间 / 类型排序，支持升序与降序
- 在当前目录内搜索（不递归），支持正则表达式，搜索状态有明显色调提示
- 数万文件的目录只读取一次并后台处理，搜索与排序不再触碰磁盘

**安全**
- 保存走"临时文件 → fsync → `rename()`"原子替换，另有 `.bak` 保留上一版本
- 大文件与含 NUL 的二进制文件自动进入只读预览，禁止保存，界面不卡不崩
- 支持其他应用通过"分享 / 打开方式"把文件送到本应用

## 体积与依赖

| 项 | 值 |
|---|---|
| release APK | 66,151 字节（32 个条目，未压缩 110,527 字节） |
| `classes.dex` | 约 60 KB（占压缩后 APK 约 92%） |
| 第三方运行时依赖 | **无**（无 AndroidX / Material / Compose / 网络库） |
| 测试依赖 | JUnit 4.13.2（仅 `testImplementation`） |

## 构建

需要 JDK 17 与 Android SDK（`compileSdk 35`）。

```bash
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/android-sdk
./gradlew assembleRelease
```

产物固定在 `app/build/outputs/apk/release/`，命名为 `白纸v{versionName}.apk`。

签名：在仓库根目录放置 `keystore.properties`（`storeFile` / `storePassword` / `keyAlias` /
`keyPassword`）并提供对应 `release.jks`。二者已被 `.gitignore` 忽略；缺失时 release 仍可构建，
只是不签名。

## 测试

```bash
./gradlew testDebugUnitTest
```

99 个单元测试，覆盖与 Android 无关的纯逻辑：编码检测、查找引擎、文件体积策略、
原子写入、启动决策、保存命名。

## 环境

- `minSdk 26`（Android 8.0）/ `targetSdk 35`，Java 17
- AGP 8.11.1 + Gradle 8.13
- 无 native 库，同一份 APK 同时兼容 32 位与 64 位 arm 设备

## 权限

- `MANAGE_EXTERNAL_STORAGE`（Android 11+ 需在系统设置中手动授权）/
  `WRITE_EXTERNAL_STORAGE`（API 26–29）
- **不申请网络权限**——应用没有任何联网行为

## 代码结构

```
app/src/main/java/io/github/hecate2/paper/
  MainActivity.java       编辑器
  BrowserActivity.java    目录浏览器
  SettingsActivity.java   设置
  EditorEditText.java     带行号栏与当前行高亮的 EditText
  VirtualTextView.java    只读预览
  Prefs.java              设置持久化
  core/                   与 Android 无关的纯逻辑（可单测）
app/src/test/             单元测试
```

设计与取舍（真实路径 vs SAF、原子写入、性能边界等）见 [DESIGN.md](DESIGN.md)。

## 已知限制

- 采用真实路径方案，因此**不支持** SAF / 云端提供器中的文件
- 因使用 `MANAGE_EXTERNAL_STORAGE`，不适合上架 Google Play
