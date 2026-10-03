# ShadowsocksX-NG2

新实现（2.0）所在目录。仓库级约定见根目录 [`AGENTS.md`](../AGENTS.md)；工程结构、外部二进制供应链、签名基线、构建测试命令、代码风格工具安装与基线版本见 [`README.md`](README.md)，本文件不重复。

## Unit tests（hostless）

单测不以 app 为宿主（ADR-0021）。两条约定：

- 测试需要 app 产物（嵌入二进制、打包面 Info.plist 断言）时，一律经 `Tests/AppArtifact.swift` 定位。
- 生产代码读取 app bundle 内打包资源（规则快照、LaunchDaemon 清单等）时，走注入缝——控制器的 `appBundle` 参数（生产默认 `Bundle.main`），测试夹具注入 `AppArtifact.bundle`。

背景与三处资源缝的由来见 [ADR-0021](../docs/adr/0021-hostless-unit-tests.md)。

## Test framework

- 新增测试默认用 Swift Testing（`import Testing`）；UI 测试与性能测试依赖 XCTest 专属 API（`XCUIApplication`、`measure` 计时），继续用 XCTest；存量 XCTest 用例不回迁。
- 单测多 runner 并行执行：新夹具只占用进程私有资源——运行时分配端口、临时目录、UUID 后缀命名空间，不写共享路径与固定名。
