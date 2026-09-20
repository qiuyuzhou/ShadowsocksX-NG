# ShadowsocksX-NG2

ShadowsocksX-NG 的现代化重写版本。新工程的全部源码与构建配置放在本目录下。

依赖的二进制工具（ss-local、privoxy、kcptun、v2ray-plugin 等）不再以子模块方式在仓库内构建，而是直接复制外部项目发布好的可执行文件。

旧版工程源码位于仓库根目录的 [`Legacy/`](../Legacy) 下，仅供参考，不保证可构建。

## 工程结构

- `project.yml` — XcodeGen 工程定义，唯一事实来源。`.xcodeproj` 与 `App/Info.plist`、`*.entitlements`、`Tests/Info.plist` 都是生成物（已 gitignore），改工程结构一律改 `project.yml` 后重新生成。
- `App/` — app target 源码（SwiftUI 菜单栏 app，LSUIElement）。
- `Agent/` — 代理运行时 wrapper（独立可执行文件，装入 `Contents/MacOS/`，由 LaunchAgent 常驻）：读 `v2/sslocal-active.json` 契约、以绝对路径启动并监管 sslocal（SIGTERM 链式停止、SIGUSR1 热重载/结构重启、崩溃时非零退出交 KeepAlive 重放，spec #21 D2/D5）。
- `LaunchAgent/` — `SMAppService.agent(plistName:)` 的注册清单，装入 `Contents/Library/LaunchAgents/`；`ProgramArguments` 用 bundle 相对路径，由 launchd 按注册 app 的 bundle 位置解析。
- `Domain/` — 领域核心（配置目录树、凭据引用与持久化，spec #21 D3/D5），与 UI 无关；其中 `RuntimePaths`、`SslocalRuntimeDocument`、`RuntimeLog` 同时编入 wrapper 目标，保证跨进程契约单一来源。
- `Tests/` — 单元测试 target，随 `ShadowsocksX-NG2` scheme 运行。
- `Vendor/<name>/manifest.json` — 外部二进制的固定供应链清单（tag + 资产 URL + 归档 SHA-256 + bundle 内位置 + 签名 identifier）；二进制本体与 `.fetched.sha256` 戳是构建缓存，不入库。
- `Scripts/` — 供应链脚本（见下节）与打包门槛断言。

## 外部二进制供应链

外部二进制只用上游官方构建产物：`sslocal`（shadowsocks-rust v1.25.0，装于 `Contents/Helpers/`）与 `v2ray-plugin`（v1.3.2，装于 `Contents/Helpers/Plugins/`）。信任根是提交在库里的清单哈希；构建链如下（spec #21 D6/D10）：

1. **fetch** — `Scripts/fetch-external-binaries.sh` 下载清单固定 URL 的归档、逐字节校验归档 SHA-256、只提取清单指名的成员并确认 arm64，落盘 `Vendor/<name>/` 并记录戳。归档哈希不符 → 立即失败；本地缓存漂移或清单变更 → 自动重新下载复验。
2. **generate** — `xcodegen generate` 把两个二进制作为 Copy Files 项装入 `Contents/Helpers[/Plugins]`。注意顺序：**先 fetch 再 generate**，文件在生成时必须已存在，否则 Copy Files 阶段会被静默丢弃（generate 也会直接报缺文件）。
3. **verify on every build** — 预构建脚本阶段重跑 fetch 脚本（缓存命中时只对本地戳快速复验），哈希或清单漂移使构建即失败。
4. **sign** — `Scripts/sign-embedded-helpers.sh`（post-build 阶段）对每个二进制 Developer ID 重签：`--options runtime --timestamp --identifier <清单 signIdentifier>`（插件形如 `<bundle-id>.plugin.<name>`）；随后 Xcode 完成 app 外层签名，封存重签后的嵌套代码。
5. **gate** — 构建产物必须过 `Scripts/packaging-gate.sh <App.app>`：嵌套代码签名严格校验、主应用 DevID + Hardened Runtime 且无 App Sandbox entitlement、逐二进制清单覆盖（Helpers 下每个 Mach-O 都在清单内且 DevID 重签通过）。篡改任一二进制会因签名失效被断言发现。

## 签名与运行形态基线

- 继承 bundle id `com.qiuyuzhou.ShadowsocksX-NG`；macOS 15+ / arm64。
- Hardened Runtime + Developer ID 签名（`DEVELOPMENT_TEAM` / 证书见 `project.yml`）；不启用 App Sandbox，entitlements 为空 dict。
- 测试 target 用 Apple Development 证书签名：宿主 app 开启 Hardened Runtime 后 library validation 要求被注入的 xctest 包同 Team 签名。
- Release 配置关闭 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`，保证发布产物 entitlements 只来自项目文件。

## 构建与测试

```bash
cd ShadowsocksX-NG2
# 新 clone 或清单变更后：先取外部二进制，再生成工程（顺序不可颠倒）
Scripts/fetch-external-binaries.sh
xcodegen generate
# 构建
xcodebuild -project ShadowsocksX-NG2.xcodeproj -scheme ShadowsocksX-NG2 \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
# 运行单元测试
xcodebuild -project ShadowsocksX-NG2.xcodeproj -scheme ShadowsocksX-NG2 \
  -destination 'platform=macOS,arch=arm64' test
# 打包门槛（对构建产物；发布前必须全绿）
Scripts/packaging-gate.sh \
  .build/DerivedData/Build/Products/Debug/ShadowsocksX-NG2.app
```

## 代码风格工具

- `swift format` 随 Xcode/Swift 工具链提供，无需单独安装（基线：Apple Swift 6.4）；SwiftLint 需 `brew install swiftlint`（基线 0.65.0）。工具缺失时，含本目录 Swift 文件的提交会被 pre-commit 钩子拒绝而不是放行。
- 配置文件：`.swift-format` 是 Swift 6.4 工具链默认规则的快照（固定成文件，工具链升级不漂移）；`.swiftlint.yml` 默认规则起步，只声明排除项与个别和 format 基线冲突的关闭项（文件内有触发案例注释）。
- 提交门槛的行为约定、钩子启用与手动执行命令见 [`AGENTS.md`](AGENTS.md)。

## 依赖升级

升级任一外部二进制是显式供应链动作：人工复验新 release（下载归档、静态观测哈希/架构/签名，不执行），随后在一次 PR 中同时改 `Vendor/<name>/manifest.json` 的 release/asset/url/archiveSHA256 与对应测试锚点。不接受 `latest`，不在仓库内构建，不做应用内更新通道（升级仅随 app 发版）。
