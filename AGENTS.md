# ShadowsocksX-NG

macOS Shadowsocks 客户端。`Legacy/` 是已冻结的旧版实现,仅作只读参考(见 Legacy/AGENTS.md);新实现位于 `ShadowsocksX-NG2/`。

## NG2 提交门槛

`ShadowsocksX-NG2/` 的 Swift 代码提交前必须过 `swift format` 格式化与 SwiftLint 检查,由 pre-commit 钩子强制;新 clone 先启用钩子。约定与启用步骤见 `ShadowsocksX-NG2/AGENTS.md`,工具安装与基线版本见其 `README.md`。

## Agent skills

### Issue tracker

Issue 跟踪在本仓库的 GitHub Issues(qiuyuzhou/ShadowsocksX-NG),统一用 `gh` CLI 操作。见 `docs/agents/issue-tracker.md`。

### Triage labels

triage 标签使用五个默认角色名作为标签字符串(needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix)。见 `docs/agents/triage-labels.md`。

### Domain docs

single-context:根目录一个 `CONTEXT.md` + `docs/adr/`,按需惰性创建。见 `docs/agents/domain.md`。
