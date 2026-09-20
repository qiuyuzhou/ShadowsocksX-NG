# ShadowsocksX-NG2

ShadowsocksX-NG 的现代化重写版本。新工程的全部源码与构建配置放在本目录下。

依赖的二进制工具（ss-local、privoxy、kcptun、v2ray-plugin 等）不再以子模块方式在仓库内构建，而是直接复制外部项目发布好的可执行文件。

旧版工程源码位于仓库根目录的 [`Legacy/`](../Legacy) 下，仅供参考，不保证可构建。

## 工程结构

- `project.yml` — XcodeGen 工程定义，唯一事实来源。`.xcodeproj` 与 `App/Info.plist`、`*.entitlements`、`Tests/Info.plist` 都是生成物（已 gitignore），改工程结构一律改 `project.yml` 后重新生成。
- `App/` — app target 源码（SwiftUI 菜单栏 app，LSUIElement）。
- `Tests/` — 单元测试 target，随 `ShadowsocksX-NG2` scheme 运行。

## 签名与运行形态基线

- 继承 bundle id `com.qiuyuzhou.ShadowsocksX-NG`；macOS 15+ / arm64。
- Hardened Runtime + Developer ID 签名（`DEVELOPMENT_TEAM` / 证书见 `project.yml`）；不启用 App Sandbox，entitlements 为空 dict。
- 测试 target 用 Apple Development 证书签名：宿主 app 开启 Hardened Runtime 后 library validation 要求被注入的 xctest 包同 Team 签名。
- Release 配置关闭 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`，保证发布产物 entitlements 只来自项目文件。

## 构建与测试

```bash
cd ShadowsocksX-NG2
xcodegen generate
# 构建
xcodebuild -project ShadowsocksX-NG2.xcodeproj -scheme ShadowsocksX-NG2 \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
# 运行单元测试
xcodebuild -project ShadowsocksX-NG2.xcodeproj -scheme ShadowsocksX-NG2 \
  -destination 'platform=macOS,arch=arm64' test
```
