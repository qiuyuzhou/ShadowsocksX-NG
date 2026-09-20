# ShadowsocksX-NG2

新实现（2.0）所在目录。仓库级约定见根目录 [`AGENTS.md`](../AGENTS.md)；工程结构、签名基线、构建与测试命令见 [`README.md`](README.md)，本文件不重复这两部分。

## 代码风格与提交门槛

提交任何 Swift 改动前，先用 `swift format` 格式化、再通过 SwiftLint 检查。pre-commit 钩子强制执行：格式化结果直接进入提交（工作区不动），SwiftLint error 级违规拒绝提交，warning 仅提示。

- **启用钩子**（新 clone 必做一次，否则门槛不生效）：

  ```bash
  git config core.hooksPath .githooks
  ```

- **手动执行**（在 `ShadowsocksX-NG2/` 目录内运行，配置自动加载；`swift format` 对目录操作需 `-r`）：

  ```bash
  swift format format --in-place -r App Tests
  swiftlint lint
  ```

- **配置**：
  - `.swift-format` — `swift format` 配置，Apple Swift 6.4 工具链默认规则的快照（固定成文件，工具链升级不漂移）。
  - `.swiftlint.yml` — SwiftLint 配置，默认规则起步，只声明排除项。
  - `../.githooks/pre-commit` — 提交门槛钩子；只处理本目录下暂存的 `.swift` 文件，`Legacy/` 与其他目录一律不 format / lint。

- **工具版本**：
  - `swift format` — 随 Xcode/Swift 工具链提供，无需单独安装（基线：Apple Swift 6.4）。
  - SwiftLint — `brew install swiftlint`（基线 0.65.0）。
  - 两个工具缺失且提交含本目录 Swift 文件时，钩子拒绝提交而不是放行；装好再提交即可。

- **调规则**：遇到实际痛点再改 `.swift-format` / `.swiftlint.yml`，不预先堆规则；改动需在 PR 说明里给出触发调整的具体案例，并同步更新上方的基线版本。
