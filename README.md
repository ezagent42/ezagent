# Ezagent — Session Router

Elixir/OTP-native **message router runtime**: multi-channel → multi-agent 编排。
不是 typical Phoenix CRUD app —— 见 `ARCHITECTURE.md` §1.2 的两条核心差异。

> **当前状态**: Phase 0 complete(项目骨架 + 工具链就位)。下一步 Phase 1。

## 怎么读这个仓库

按顺序读(也是 `CLAUDE.md` 的「必读」清单):

1. **`ARCHITECTURE.md`** — v0.4,设计权威(Decision Log #1-83)。**不要改这份文档** —— Allen 维护。
2. **`GLOSSARY.md`** — 术语表 + 易混淆词消歧 + Decision Log 速查。
3. **`IMPLEMENTATION_ROADMAP.md`** — 6 phase 划分 + 4 条贯穿 track。
4. **`CLAUDE.md`** — Ezagent 特有约定(补充 phx.new 生成的 `AGENTS.md`)。
5. **`docs/phase-specs/<current-phase>/`** — 当前 phase 的 SPEC / VERIFICATION / PLAN / DECISIONS。
6. `ARCHITECTURE_GRILL_v0.3.md` — dev review 历史记录(可追溯)。

## 结构

Mix umbrella:

```
apps/ezagent_core/   — 纯 OTP,不依赖 :phoenix 框架(可用 :phoenix_pubsub / :ecto)
apps/ezagent_web/    — Phoenix transport 层(Endpoint / Socket / Plug / LiveView)
                   (apps/esr_plugin_* 从 Phase 1 起逐个加)
```

## 关键 commands

```bash
mix setup                      # 各 app deps + assets
mix phx.server                 # 起 dev server(绑 0.0.0.0:4000,tailnet 可达)
iex -S mix phx.server          # 带 REPL

mix test                       # 全部测试
mix format --check-formatted   # 格式检查(sub-step gate 用)
mix ezagent.check_invariants       # 8 条硬不变式自查(Phase 0:skeleton no-op)

mix ecto.create / ecto.migrate # SQLite
```

## 实施工作流

每个 phase:`/brainstorm` 出 `docs/phase-specs/phaseN/` 4 文件 → 实施(sub-step e2e gate)
→ Allen review → `git tag phaseN`。详见 `IMPLEMENTATION_ROADMAP.md` §0。
