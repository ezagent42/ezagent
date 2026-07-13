# W29（2026-07-13 – 07-19）周目标 — 实现 ezagent 自举（统一 demo 验收）

本周目标延续 W28 的**「实现 ezagent 自举」**，但从三条并列子目标**收敛为一个统一验收 demo**
（lead 确认 2026-07-13）——不再分面各自"跑通"，而是把 dev-loop、产品 dogfood、两者结合
拧成**一条端到端链**，本周至少完整跑通一次。

> **统一 demo（本周验收，至少跑通一次，不要求稳定）:** 在部署站点上 ——
> 登录官网（magic-link）→ 进 hello（入口/concierge）→ hello 连到 kanban socialware（开发任务板）
> → 在 kanban 上把一个真实 ezagent 开发任务派给一个**平台托管的开发 agent**（cc/codex）
> → 该 agent 产出真实 PR → 过 CI + review + 合并 + 部署 → kanban 上看到任务流转 → 三面绿。
> （含 socialware install/use/uninstall 生命周期。）
>
> = **dev-loop**（在 ezagent 里开发 ezagent）+ **产品 dogfood**（hello/kanban 作为真实 socialware 被用）
> + **两者结合**（用 kanban 派开发任务）。
>
> **验证顺序:** 从 agent 可被正常调用起（gaga）→ 逐环节由 jjkysy 用 kanban 看板监控 + 测试验收。

## 使能结构 — W28 三条子目标（作为本 demo 的支撑，不再单独验收）

W28 的三条子目标不废弃，它们是这条 demo 链能跑通的前置结构：

1. **socialware 全生命周期**（load/create/delete）+ 打通官网全流程 —— demo 的**产品面**
   （hello/kanban 作为真实 socialware 被 install/use/uninstall）。
2. **自举开发流程**（在 ezagent 里开发 ezagent，三面全绿）—— demo 的 **dev-loop 面**
   （平台 agent 产 PR → CI + review + 合并 + 部署）。
3. **收敛 agent 控制面边界**（session 面不再伸手进 agent 生命周期；AgentRuntime 结构线）——
   demo 的**地基**（agent 可被正常调用/托管的前提）。

## 现状

**目前这条统一 demo 一次都还没跑通**（W28 头号 canary 目标"@orchestrator 真回话"未按 plan 归档，
见 `2026-07-10/review.md` §3 事故 A；能力已由 #1332/#1333 就位，实测应可过）。**本周先跑通一次**——
不要求稳定，先证明全链可闭合，再谈去脆。

每日 track 归入本 demo 的某一环。
