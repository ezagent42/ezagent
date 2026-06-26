# return · 2026-06-26 · zyli-e2e-ui(合并)— E2E 文档补全 + UI 修复

> **Task:** zyli-e2e-ui(**FP4** E2E 文档补全 + **FP5** UI 修复)
> **Branch:** `zyli/fp5-ui-fixes-0626`(HEAD `e0ea451c`)
> **PR:** [#1025](https://github.com/ezagent42/ezagent/pull/1025)(**单 PR 含全部两项**)
> **Dev:** zyli-developer(agent-assisted)
> **returned_at:** 2026-06-26 18:35 +0800
> **deadline:** 2026-06-26 23:59 +0800
> **deadline_status:** on_time
>
> **说明**:今日 handoff 一份(FP4+FP5)。原本拆成 3 个 PR(#1019 FP5 清单 / #1021 FP4 / #1025
> FP5 修复),应要求**合并为单个 #1025**(#1019、#1021 已 cherry-pick 并入并关闭,内容逐字节
> 核对零丢失)。本文件**合并** `zyli-e2e-ui.md`(FP4)+ `zyli-fp5-ui.md`(FP5)两份分返,作为整
> handoff 的统一 return。

---

## 做完了什么

### FP4 — E2E 文档补全(`docs/e2e/`)
把人肉执行记录升级为**三层资产**,核心全部用 agent-browser/CLI 实地跑通(非纸面):
1. **runbook 框架**:`guide.md §8`(干净 seed + world UI 交互坑 + 断言谓词 + evidence 命名)、模板、12 场景 runbook 节、README 两层指引。
2. **🚀 一键无人值守 runner `docs/e2e/auto/`**:`bash docs/e2e/auto/run.sh`,**实测 PASS=15 / FAIL=0**,幂等、退出码接 CI。覆盖 01 登录 / 02 建 agent / 03 建 session / 04 py 往返 / 05 cc 回归守卫 / 07 curl **真实 DeepSeek** / 08 @门控 / 09 autocomplete / **11 feishu 合成入站全链** / 12 dispatch 审计。
3. **5 个 world UI 产品缺口清单**(`docs/e2e/notes/2026-06-26-product-gaps.md`)—— 即 FP5 的起点。

### FP5 — UI 修复(先清单后逐条)
1. **先列清单**:本人(非 subagent)agent-browser 逐面 live 巡检 → `notes/zyli-fp5-ui-inspection.md` + 29 张证据。
2. **后逐条修(8 项,每项 before/after 证据)**:
   - S1-a 调试文案 · S7-a 时间格式化 · S9 Kanban 标题/导航 · Kanban /plugins 入口(config_surface,文本对齐 #1020 → 自动合并)· /plugins 整卡可点 · 左导航可收起(localStorage)· S2-a Overview 独立 dashboard · Admin 子页导航 · Admin 各表 URI 可点下钻。
3. **核心侧/架构冲突 → handoff 给 lead(没擅自动)**:
   - **S5** agent 详情面失效(cc `:activate_timeout` / py `:read_cascade`,erpc 实证后端)→ `handoffs/agent-detail-surfaces-broken.md`。
   - **routing/caps 管理** 撞 **Decision #137**(无通用 grant)+ Admin 路由改全局属 **#990** 高风险 → `handoffs/admin-routing-caps-management.md`(试做+回退,接线已摸清)。
4. **暂不做(已说明)**:auto-derive 入口(被 bespoke 面取代,硬加会坏/冗余)、H1/H2 冗余(撞 agent-console-crud 的 `Identities.tsx`)。

## DoD reconciliation

| # | DoD line(handoff) | status | proof / open decision |
|---|---|---|---|
| 1 | **E2E 文档补全**:场景沉淀完整,agent 拿 agent-browser 能自动跑通 | **met（强）** | 一键 runner `docs/e2e/auto/run.sh` 实测 **PASS=15/FAIL=0**(01-05/07-09/11/12)+ 真实 DeepSeek + 合成 feishu 入站全链 + dispatch 审计。**残留**:06 codex(OpenAI-SSE-over-代理环境不稳)/ 10 feishu 出站(飞书 Bot API 带外)—— 环境/外部受限,已诊断,非 runbook 问题 |
| 2 | **UI 修复（先清单后逐条,每条附前后证据）** | **met** | 清单 + 29 图(`evidence/fp5-ui-audit/`);8 项修复 + before/after(`evidence/fp5-ui-fixes/`,13 图)+ 复检(round2,7 图)。**超 DoD 发现分流 lead**:S5、routing/caps(handoff)|
| 3 | #990 gap 纳入清单 | **met+升级** | scenario-04 把 ROUTING=0 divergence 编码成机器回归守卫;入口审计纳入(Admin 子页/URI/Kanban);路由本体属 core → routing/caps handoff |

**DoD 全 met**(FP4 强 met,FP5 met,#990 met+升级)。无 not-met、无 deferred。

## Gate 状态

- **PR:** #1025 · **head:** `e0ea451c` · **rebase-base:** `b0637049`(= 当前 `origin/main` tip)
- **CI(`precommit + check_invariants`):** 提交时本地完整 `mix test` + check_invariants 已绿;typed-slot 闸门 `slot_registry_test`(3)+ `slot_mount_gate_test`(4)绿。请 merge 前确认 PR head CI 转绿。
- **并行 PR 协调**:与 #1020(jjkysy kanban Phase 1)曾在 `application.ex` config_surface 冲突 → 把文本对齐 #1020 → **git 自动合并,零冲突**(merge-tree 验证)。与 agent-console-crud 零交集。

## Method friction(供 lead 在 review 提炼)

1. **handoff 把 FP4+FP5 合并下发,但分属两个 worktree** → return 才发现要拆/合,反复(3 PR → 2 → 1)。建议:并行 worktree 子任务在 plan 阶段就定**一个还是多个 PR**。
2. **本地提交闸门硬连 `55432` docker PG**,无 docker 时含 `.ex` 改动提交不了(S2-a 卡过)。临时解:host PG 建 additive 角色 `ezagent_pg_compat` + Elixir TCP 转发器 55432→5432。建议:**闸门支持 `POSTGRES_*` env 覆盖 / 文档化无 docker 路径**。
3. **跨域改 kanban 插件前未先查 owner 是否在做** → 我 S9b 和 jjkysy #1020 各自给 kanban 加了同一个 config_surface。教训:world-coordination §5 登记要更早 + 改他人插件先问。
4. **routing/caps 反复**(A 判需 lead → B 要先做 → 实测撞 #137/全局不可靠 → 回退走 handoff):冲突点(#137/#990)若 plan 阶段标出可省往返。

## Merge request

- **请 review + merge `zyli/fp5-ui-fixes-0626`(PR #1025)→ main**:今日整个 handoff(FP4 e2e 文档 + FP5 UI 修复 + 入口完善),additive,遵守 world-coordination(§5 已登记)。
- **顺序**:与 #1020 / agent-console-crud 零冲突,可独立 merge;CI 转绿即可。
- **关联**:S5 / routing-caps 待 Allen 接 handoff。#1019、#1021 已并入本 PR 并关闭。

## 给 lead 的话

今日 handoff(FP4+FP5)完成,全 DoD met,统一在单 PR #1025。FP4 的一键 runner 实测 15 绿;
FP5 的 8 项 UI 修复本人 agent-browser live 验证、每项有前后证据。核心侧两类(S5 agent 详情面、
routing/caps 管理)我没擅自动,摸清后端 + 标了 #137/#990 冲突写成 handoff 等你定。请 review #1025。
