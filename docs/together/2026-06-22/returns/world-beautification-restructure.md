# Return — world UI beautification + product-structure adjustment

> **Date:** 2026-06-22 · **From (dev):** Claude · **To (lead):** Allen
> **Task:** #83 · **Branch:** `world-beautify` (16 ahead / 0 behind `origin/main` @ `a6fa6db3` — cleanly rebased, fast-forward-able; HEAD `6db6d876`)
> **Handoff:** `docs/superpowers/handoffs/2026-06-22-world-beautification-restructure-handoff.md`
> **Status:** **CLOSE-READY** — code-complete, all gates green, demonstrable (visual) DoD met by human eyeball (incl. 1 bug found+fixed during verification, `6db6d876`).

## What's done — handoff workstreams ↔ commits

| handoff § | workstream | commit(s) |
|---|---|---|
| §3.0 | typed-slot 契约 + SoT `Ezagent.World.SlotRegistry`（renderer-agnostic）+ 每路由走 registry + 删 unknown→IdentitiesSurface 兜底 | `16e5ff6c` |
| §3.2 | 两层 hard-fail layout gate（Layer-1 Elixir route-manifest + Layer-2 JS/TS mount）+ shell-chrome seed allowlist | `16e5ff6c` (L1) · `df305e9f` (L2) |
| §3.1 ① | Tailwind v4 + `@tailwindcss/vite` + shadcn slate token 基础（与 world-* 共存） | `774d765e` |
| §3.1 ② | primitive barrel 做实（live shadcn）+ Button size/primary 修 + atom 层与 `primitive_coverage_test` 同步 | `d05a8d4f` |
| §3.1 ③ | 按簇迁 surface 到 registry 后：admin / sessions / identities / workspace-plugins | `663b2612` `47429abc` `890b2789` `e7e5a004` |
| §3.1 ③ | shell chrome → token + 暗色切换（`.dark` + localStorage `world-theme`）；LayoutEditor+PtyTerminal；Conversation（1:1 忠实迁移） | `7f4e85fe` `53e89215` `b3e70ea1` |
| §3.1 ④ | 引用扫干净后删 ~1650 行 world-* 样式表 + Button token 化 + 恢复 preflight（全迁达成） | `96298e24` |
| §3.4 | 导航 IA：breadcrumbs + back-nav + workspace switcher + 合并 Identities/Users/Agents 三入口 | `7c1797a7` |
| §3.3 | admin 产品化（首批 catalog 形状 slot）：typed `Table<T>` + 6 surface 专用列 + 5-KPI dashboard + CC-orchestrator 卡 | `11f32796` |

§7 留给实现者的 4 个残留决策均已定（slot-spec 字段 / JS-TS gate 机制=签入 manifest 比对 + mount 静态检查 / seed allowlist=`SlotRegistry.shell_chrome/0` / per-route `can_manage_layout` 策略）。
handoff §4 边界遵守：本轮**不**做 `@json-render` 转换；Conversation / PTY / LayoutEditor **未**强制 catalog 化。

## DoD artifact

- **Gates (necessary part) — ALL GREEN:**
  - world plugin 套件 `mix test apps/ezagent_plugin_world/test` → **24 tests, 0 failures**
  - `vite build`（apps/ezagent_plugin_world/assets）→ **green**（world.css 31.48 kB / main.js 794 kB）
  - Layer-2 mount gate `npm run check:mounts` → **OK（8 components / 7 families）**
  - Layer-1 manifest `mix world.slots.manifest --check` → **in sync**
  - 构建产物无漂移；分支 0/0 vs origin，0 behind main
- **Demonstrable (visual) artifact — MET (2026-06-22, human eyeball on live world @ :10042).** dev WSL 无 agent-browser，改由人（Allen 侧浏览器）逐页核对。已验：Sessions/Overview、🌙 暗色模式、导航（单 Identities + 面包屑）、Conversation、**Admin dashboard**。
  - **验收中发现并修复 1 个真 bug（commit `6db6d876`）：** Admin 的 CC-orchestrator 卡仍渲染原始 `{:ok, %{...}}` dump（被 `jsonable/1` 拍成 `["ok", %{...}]` → 前端 `Object.entries` 出 `0`/`1` 列）——正是 §3.3 要消灭的反模式。修为：Elixir 端 `shape_orchestrator_status/1` 拍平成 `state + 标量字段`，前端 `OrchestratorStatus` 渲成状态徽章 + key/value。复验通过（绿 `ok` 徽章 + 干净字段）。这是静态构建绿但真界面坏的典型，靠 build/test 发现不了。

## Deferred / needs-human follow-ups (flagged with target)

1. **`@json-render` 收敛** — 显式排除在本轮之外（world→hello Phase 3 的独立工作），非本 handoff 欠债，仅记录前向形状。

## Merge request

- **合并：** `world-beautify` → `main`（lead 经 `close`）。14 ahead / 0 behind `origin/main`，**fast-forward-able**，无需 rebase。
- **顺序：** 单分支、无跨任务依赖；今天 stack 里若有其他 world 返回需与本支按 `world-coordination.md` 串行（本支已删 `styles.css`，后续 world 改动需基于本支重做样式）。
- **合并前置条件：** 已满足。可视化验收完成（含 1 个 bug 修复 `6db6d876`），代码 + 闸门 + 人眼三层都绿。**close-ready。**
