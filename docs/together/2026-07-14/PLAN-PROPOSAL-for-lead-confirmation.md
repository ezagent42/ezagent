# 2026-07-14 per-dev 任务清单（proposal — 待 lead 确认，勿定稿 plan.md）

> 这是 dev-together `plan` 命令 step-7 的**lead-confirmation gate** 输入：每个 human-dev 一段、
> 一行 scope，续接各自 `latest_return`（见 2026-07-13 review §6 / team.md），并归入 W29 统一 demo 的某一环。
> **lead 未逐人确认前不写 `plan.md`。** lead 可增、删、改范围、重派。designer（ruihua）按约定不占 track 行。
>
> **本周验收（standing）:** 登录官网 → hello → kanban socialware 派开发任务给平台托管 agent → agent 产 PR
> → CI/review/合并/部署 → 看板流转 → 三面绿。**第一张多米诺已于 07-13 canary 实证（#1367 commit 200f91b5）**——
> 07-14 沿链往下推 + 补回被急症挤占的结构线。

## zhaomato（张宁）— 官网 hello live E2E transcript（**现已解锁**）
- 跑通「官网首程（magic-link 登录 → 进站）→ hello greeter 入口 → curl-llm **真回复**」的 live E2E transcript；
  昨日唯一阻塞（orchestrator 真回话）已由 gaga #1367 清除，现可链测。续接 `#1312`。归 demo **产品面**。

## gaga（黄佳佳）— AgentRuntime 结构线（补回）+ demo agent 凭证下发
- ① 把昨日让位于 PTY 急症的 **AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate**（W28③ 结构线，session 面不再伸手进 agent 生命周期）拉回为头号；
  ② 处理昨日诚实旗标的 **demo agent 凭证下发**（`test-zyli-cc-1` 等缺凭证）。续接 `#1367`。归 demo **地基**。

## jjkysy（姚升悦）— kanban 整体进度监控 + 测试 + 推 #1301
- kanban socialware 作为团队进度看板：demo 各环节任务卡 + 可见流转 + **至少一条可核实的跨环节验收用例**（真实数据）；
  并把 **#1301 dealscout 推到 mergeable**。续接 `kanban-rework-final (2026-07-10)`。归 demo **自举 × socialware**。（昨日无 PR/return——今日须有可核实交付。）

## zyli（李震宇）— 前端 CI 覆盖（分期，先 tsc）
- 起 #1371 登记的前端 CI 覆盖任务，**先 `tsc --noEmit` 进 CI**（每个 assets 目录 + 一个 CI step，最高性价比、直接防 #1369 xterm 类 bug），后续 ESLint→Vitest→Playwright smoke 分期。续接 `#1365`。归 demo **地基/质量闸**。

## ruihua（陈瑞华，designer — 非 track 行，设计输入）
- 把 #1372 飞轮原型的 IA/视觉方向接入真实 world/hello LiveView 面（供 zhaomato/zyli 落地参照）；设计输入走 Feishu，不改代码、不占 track 行。续接 `#1372`。归 demo **官网体验**。
