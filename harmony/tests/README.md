# 鸿蒙版 core 单测

```bash
cd harmony/tests
node run_core_tests.mjs
```

- 零第三方依赖，只用 Node 22 自带能力（类型剥离 + `node:fs`）。
- `run_core_tests.mjs` 把 `entry/.../ets/core/*.ets` 拷为 `.tmp_core/*.ts`
  后执行 `main.ts`；`.ets` 文件只用可擦除的 TypeScript 语法、
  零 `@kit.*` 导入，所以这一步能跑。
- 用例与安卓版 `app/src/test` 一一对应（SearchEngine / EncodingDetector /
  FileSizePolicy / SaveNames / StartupDecision / AtomicFileWriter）。
- 唯一有意的覆盖差异：GBK/GB18030/Big5 的**编码**需要平台编码器
  （鸿蒙真机 `util.TextEncoder`，见 `model/TextCodecs.ets`），Mac 版 Node
  没有 GBK 编码器；Node 侧覆盖这三者的解码/检测/工具函数，
  并断言“无 codecs 时 encode 直接抛错”（防静默存错编码），
  编码正确性由真机测试覆盖。
