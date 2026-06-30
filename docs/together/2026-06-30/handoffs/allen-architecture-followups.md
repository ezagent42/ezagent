# Handoff: kanban PR #1020 架构 follow-ups（给 Allen / lead 定方向）

> **Date:** 2026-06-30 · **From:** Claude (FP5) · **To:** Allen
> **Tracking:** PR #1020 · **Status:** 不阻塞 merge——都是方向/收敛决策，留 lead 拍

本 PR 实施期识别出 4 个**架构方向问题**，按项目规矩（架构方向不在实施期顺手定）抛给你。

## 1. `config_surface` 整体重构（nav 搬走后的残留耦合）

- nav_surfaces/0 + session_tabs/0 已搬 World 层（`Ezagent.World.UISurfaceProvider` duck-type 读 plugin plain 函数）。
- **core `Ezagent.Plugin` 契约里现在只剩 `config_surface/0` 这一个 UI-surface callback。**
- 一致性问题：要不要把 `config_surface` 也搬 World，让 core 契约**彻底无 UI 概念**？
- `config_surface` 是你既有的（喂 `/plugins` 配置页），所以本 PR **留着没动**。搬不搬、怎么搬，待你定。

## 2. `SessionAgentMaterialize` 编排与 orchestrator 的合并空间

- **现状**：两个触发入口往 session 放 role-agent——
  - orchestrator 的 add-member（cc 大脑经 MCP **手动**触发，`orchestrator/mcp_server/tool_catalog.ex`）
  - kanban 的 `SessionAgentMaterialize`（插件事件 `bind_session` **自动**触发，无 agent-in-loop）
- **没有重复造引擎**：两者都 CALL 同一个 spawn primitive `Ezagent.Entity.Agent.spawn_from_template_content/5` + `GrantRecipeCaps`。
- **但编排层平行**：各自的步骤（plan per-session URI + grant caps + best-effort spawn）是分开写的。`SessionAgentMaterialize` 当初**照 `CcOrchestratorSeed` 模式写**，因为 kanban 无 operator/orchestrator-agent 入口。
- **建议**：可抽一个共享 `materialize_role_into_session/N`，让"手动 MCP 触发"和"插件自动触发"两个入口都调它（消除平行编排）。**是否合并 + 怎么合并待你定。**

## 3. 是否收敛「统一多 agent 协作 app SDK」（产品/架构方向）

- 本 PR 加的通用编排 glue（recipe 统一入口 `DefaultRecipes`/`DefaultRecipeSeed` + `SessionAgentMaterialize` + `MessageComposer` + relay-routing wiring）是"把配置好的 agent 放进 session、行动、接力"的**可复用 substrate**。
- **分层正确**：config 走 socialware `ConfigStore`（recipe = `config://` ConfigObject）、runtime 走 domain Behaviors（`Session.handle_send` / `Entity.Agent` / `Matcher`）。
- 但这坨 glue **还不是一个正式 SDK/接口**——是散落的 domain 模块。
- **方向问题**：要不要把它收敛成「统一多 agent 协作 app SDK」，让 kanban + 未来 app 从一个口子搭？待你定。

## 4. Deferred surfaces（已记 `docs/guide/kanban-development-pitfalls-and-decisions.md`，不阻塞 merge）

- **forward pm→dev @mention 规则化**：relay-back（dev→pm）已做成 sender-locked 路由规则；forward（pm→dev）还靠 admin nudge，未规则化。
- **participation send cap durability**：会话参与 send cap 当前非 durable。
- **agent 配置 UI**：pm/dev 配置现在靠代码 seed（`DefaultRecipes`）+ CLI grant，无 World 配置页。
- **materialize auto-invite**：`SessionAgentMaterialize` 不 auto-join agent 为会话成员（surface G，现手动 invite），auto-invite 留后续脚本。
- **`docs/guide/world-coordination.md:82-83` stale**：把 `session_tabs/0` 描述成 core plugin.ex 契约——是 main 的 stale（#1025，非本 PR 改），待清理（本 PR 不动避免 scope creep）。
