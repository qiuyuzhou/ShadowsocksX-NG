# ShadowsocksX-NG

> 🚧 重新实现进行中 —— 本仓库正在使用现代技术栈重写 ShadowsocksX-NG macOS 客户端。

新工程不再通过 git 子模块在仓库内构建依赖，而是直接复制上游项目发布好的可执行文件，以简化构建流程。

## 目录结构

```
.
├── ShadowsocksX-NG2/   # 新工程：现代化重写版本（开发中）
└── Legacy/             # 旧版工程完整源码，仅供参考，不保证可构建
```

旧版工程的功能说明与使用文档见 [Legacy/README.md](Legacy/README.md)。

## 开发钩子

新 clone 后，在仓库根目录启用 Git hooks：

```bash
git config core.hooksPath .githooks
```

启用后，`pre-commit` 只检查暂存区中 `ShadowsocksX-NG2/` 下的 `.swift` 文件：`swift format` 的结果写回暂存区、不修改工作区；SwiftLint 的 error 级违规拒绝提交，warning 仅提示。`Legacy/` 和其他文件跳过；没有 NG2 Swift 文件时直接放行。含有 NG2 Swift 文件但缺少工具时，提交检查失败。工具安装与版本见 [`ShadowsocksX-NG2/README.md`](ShadowsocksX-NG2/README.md)。
