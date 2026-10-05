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

启用后，`pre-commit` 只检查暂存区中 `ShadowsocksX-NG2/` 下的 `.swift` 文件：`swift format` 的结果写回暂存区、不修改工作区；SwiftLint 的 error 级违规拒绝提交，warning 仅提示。`Legacy/` 和其他文件跳过；没有 NG2 Swift 文件时直接放行。含有 NG2 Swift 文件但缺少工具时，提交检查失败。两关都把「工具没能执行」与「查出问题」分开报告：看到「执行失败」应查工具与配置环境，而不是去改代码。工具安装与版本见 [`ShadowsocksX-NG2/README.md`](ShadowsocksX-NG2/README.md)。

## 领域文档语言

本项目的 [术语表](GLOSSARY.md) 和新建 [架构决策记录（ADR）](docs/adr/) 使用简体中文，代码标识符与必要的英文术语保留原文；已有 ADR 保留原文，不作语言迁移。

AI 生成大量文档后，人与机器之间的沟通成为协作瓶颈：人的阅读、理解和审阅速度决定了文档能否有效推动开发。使用简体中文可以降低维护者的认知负荷，提高沟通与审阅效率。
