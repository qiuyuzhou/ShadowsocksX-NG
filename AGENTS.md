# ShadowsocksX-NG

macOS Shadowsocks 客户端。`Legacy/` 是已冻结的旧版实现,仅作只读参考(见 Legacy/AGENTS.md);新实现位于 `ShadowsocksX-NG2/`。

## Agent skills

### Issue tracker

Issue 跟踪在本仓库的 GitHub Issues(qiuyuzhou/ShadowsocksX-NG),统一用 `gh` CLI 操作。见 `docs/agents/issue-tracker.md`。

### Triage labels

triage 标签使用五个默认角色名作为标签字符串(needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix)。见 `docs/agents/triage-labels.md`。

### Domain docs

single-context:根目录一个 `GLOSSARY.md` + `docs/adr/`,按需惰性创建。见 `docs/agents/domain.md`。

`GLOSSARY.md` 和新建 ADR 的正文使用简体中文，代码标识符与必要的英文术语保留原文。已有 ADR 保留原文，不作语言迁移。

现状与已定设计以当前代码、`GLOSSARY.md` 和 `docs/adr/` 为准。仅 `GLOSSARY.md` 和 `docs/adr/` 持续维护为最新状态；判断当前实现时，以当前代码为事实依据。将设计文档或研究报告作为实现依据前，应先在代码中核实相关描述。

`docs/design/` 记录对应任务执行时的需求、设计与规格，仅作为历史参考，不代表最新代码现状。

`docs/research/` 收录研究报告。各文档记录写作时点对上游能力、候选方案与结论的调研，不描述项目当前状态，也不代表相关设计已经被采纳。