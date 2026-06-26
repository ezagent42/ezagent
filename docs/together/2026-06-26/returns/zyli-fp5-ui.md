# return · 2026-06-26 · zyli-developer — FP5 world UI 修复 + 入口完善

> **Task:** zyli-e2e-ui 的 **FP5**(UI 修复:先清单后逐条,每条附前后对比证据)
> **Branch:** `zyli/fp5-ui-fixes-0626`
> **PR:** #1025(修复)· #1019(巡检清单 + 证据 + S5 handoff)
> **Dev:** zyli-developer
> **returned_at:** 2026-06-26 17:55 +0800
> **deadline:** 2026-06-26 23:59 +0800
> **deadline_status:** on_time

> **注**:本 handoff 是 FP4 + FP5 合并下发。**FP4(E2E 文档自动化 runbook)是并行
> worktree 的独立任务,已单独 return(`returns/zyli-e2e-ui.md` / PR #1021)**。本文件
> 只 return **FP5**。

## 做了什么

**先清单**:本人(非 subagent)用 agent-browser 逐面 live 巡检 world 操作员控制台,产出
巡检清单 + 证据(PR #1019)。

**后逐条修**(PR #1025,7 项,每项 before/after 证据于 `evidence/fp5-ui-fixes/`):
1. S1-a 去开发调试文案 "Rendered by React from LiveView state."
2. S7-a External Mirror / Admin 时间不再露裸 `~N[...]`(`inspect_timestamp`→可读)
3. S9 Kanban H1 错显 "Sessions" + 导航高亮错位修正
4. S9b Kanban 在 /plugins 无入口 → 补回 `config_surface/0`(K4 已 land 的预留项)
5. /plugins 整张卡可点进操作面(此前只有底部小链接)
6. 左导航可收起(localStorage 持久化)
7. S2-a Overview 独立 dashboard(KPI + 快捷入口,不再与 Sessions 雷同)
+ **入口审计**:Admin 8 个子页此前无可见入口 → 顶部子导航;Admin 各表 URI 可点下钻。

**核心侧 / 架构冲突 → 走 handoff 给 lead(没擅自动)**:
- **S5** agent 详情面失效(cc `:activate_timeout` / py `:read_cascade`)→ PR #1019 评论区 handoff(已 erpc 实证是后端)。
- **routing/caps 管理 UI** → `handoffs/admin-routing-caps-management.md`(Caps 撞 **#137**,Admin 路由改全局属 **#990** 高风险;试做+回退,接线已摸清交 Allen)。

## DoD reconciliation

| # | DoD line(handoff) | status | proof / open decision |
|---|---|---|---|
| 1 | E2E 文档补全(agent-browser 可自动跑通) | **split** | 非本 worktree;PR #1021 / `returns/zyli-e2e-ui.md` |
| 2 | UI 修复:先通盘巡检列清单(截图标注) | **met** | PR #1019:`notes/zyli-fp5-ui-inspection.md` + `evidence/fp5-ui-audit/`(28 图)|
| 3 | UI 修复:逐条修,每条 PR 附前后对比证据 | **met** | PR #1025:7 项 commit + `evidence/fp5-ui-fixes/` before/after |
| 4 | #990 gap(若属 UI/产品缺口纳入清单)| **met(纳入+升级)** | 入口审计纳入(Admin 子页/URI/Kanban 入口);路由本体属 core → routing/caps handoff |

**额外发现(超 DoD,已分流给 lead,非自行实现)**:S5(agent 详情面,核心侧)、routing/caps 管理(撞 #137/#990)。
**未做(已说明理由,非遗漏)**:auto-derive 入口(被 bespoke 面取代,硬加会坏/冗余)、H1/H2 冗余(低价值 + 撞 agent-console-crud 的 `Identities.tsx`)。

## Gate 状态

- **PR:** #1025 · **head:** `d12c6c89`
- **rebase-base:** `b0637049`(= 当前 `origin/main` tip,本次 rebase 后)
- **CI(`precommit + check_invariants`):** https://github.com/ezagent42/ezagent/actions/runs/28230811818 — **pending(rebase 后重跑中)**;本地提交闸门(完整 `mix test` + check_invariants)已绿,typed-slot 闸门 `slot_registry_test`(3)+ `slot_mount_gate_test`(4)绿。
  > ⚠️ 返还 gate 要求 CI 绿;请 push 前确认该 run 转绿(本地已绿,预期一致)。

## Method friction

1. **handoff 把 FP4+FP5 合并**,但 FP4 在并行 worktree、FP5 在主工作树 —— 两个独立任务共用一个
   handoff DoD,return 时才发现要拆分。建议:**并行 worktree 的子任务在 plan/handoff 阶段就拆成
   独立 DoD**,避免 return 期才拆。
2. **本地提交闸门(`mix test`)依赖 `127.0.0.1:55432` 的 docker PG**,该 PG 未起 + 我 shell 无 docker
   → 无法提交含 `.ex` 的改动(S2-a 一度卡住)。临时解:host PG 建 additive 角色 `ezagent_pg_compat`
   + Elixir TCP 转发器 55432→5432。建议:**文档化"无 docker 时如何让本地闸门连 host PG"**(或闸门
   支持 `POSTGRES_*` env 覆盖,而非硬连 55432 默认)。
3. **多个 dev server 抢 10042 端口**(我自己 6 个 phx.server 互撞 `eaddrinuse`)一度让 live 验证不可靠。
   教训:重启前先 kill 旧 server。
4. **routing/caps "做不做"反复**:我初判需 lead(A),用户要先做(B),实测才确认 caps 撞 #137、
   routing 全局不可靠 → 回退走 handoff。**冲突点(#137/#990)若在 plan 阶段就标出,可省一轮往返。**

## Merge request

- **请 merge `zyli/fp5-ui-fixes-0626`(PR #1025)→ main**:7 项 UI 修复 + 入口完善,纯 world 前端 +
  少量 world 服务端读模型,additive,遵守 world-coordination(§5 已登记),与 agent-console-crud
  零交集(未碰 `Identities.tsx` 写、`world_live.ex` 仅 additive 子句)。
- **顺序**:无强依赖;CI 转绿即可。
- **关联**:#1019(巡检+S5 handoff)保持 open 作为审计记录;routing/caps + S5 待 Allen 接 handoff。

## 给 lead 的话

FP5(UI 修复)完成并 live 验证,7 项进 PR #1025;巡检清单 + 证据在 #1019。核心侧的两类
(S5 agent 详情面、routing/caps 管理)我**没擅自动**——都摸清后端 + 标了 #137/#990 冲突,写成
handoff 等你定。auto-derive / H1/H2 按判断暂不做(理由在 return 里)。请 review #1025 + 接 handoff。
