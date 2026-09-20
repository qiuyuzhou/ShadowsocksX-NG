# ShadowsocksX-NG2

新实现（2.0）所在目录。仓库级约定见根目录 [`AGENTS.md`](../AGENTS.md)；工程结构、外部二进制供应链、签名基线、构建测试命令、代码风格工具安装与基线版本见 [`README.md`](README.md)，本文件不重复。

## Swift 提交门槛

- **启用钩子**（新 clone 必做一次，否则门槛不生效）：

  ```bash
  git config core.hooksPath .githooks
  ```

- 钩子只检查本目录暂存的 `.swift` 文件（其余目录含 `Legacy/` 一律跳过）：`swift format` 结果直接写进提交、工作区不动；SwiftLint error 级违规拒绝提交，warning 仅提示。
- 手动执行（在本目录内运行配置才自动加载；`swift format` 作用于目录需 `-r`）：

  ```bash
  swift format format --in-place -r App Tests Domain
  swiftlint lint
  ```

- 调规则只针对实际痛点：改 `.swift-format` / `.swiftlint.yml` 的 PR 须给出触发案例，并同步更新 README 中的基线版本。
