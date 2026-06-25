# Handoff: full-flow human validation — for @李震宇

> **Date:** 2026-06-24 · **From:** lead (@林懿伦) · **To:** @李震宇 (zyli)
> **Tracking:** goal ① 本周度量 — "ezagent 团队内跑起来" · **Base:** `origin/main` @ `78d70e21`
> **Status:** confirmed — VALIDATION ONLY (你不改 core，不改任何插件代码)

## 0. Mission
在你**自己的主机**上（disposable stack 本周停用，看别人的运行成果走内网 tailnet 地址），端到端**人肉**走通一遍 ezagent 全流程，按腿（L1–L7）留证据。你的产出是「证据 + blocker 清单」，**不是代码**：每发现一个 bug，开一个 `fix/<症状>` 分支占位并路由给对应 owner，你自己不动 core / 不动插件实现。

## 1. Task — 七条腿，逐腿留证据
- **L1 注册 → 邮箱密码登录 → world UI** — 新用户注册、用邮箱+密码登录、进入 world 首页。
- **L2 建 workspace + agent** — 走 #905 创建页建一个 workspace 和一个 agent。
- **L3 绑 Feishu 群 + inbound 到达** — 把 agent 绑到一个 Feishu 群，确认 inbound 消息真的到达节点（看日志行 / UI）。
- **L4 cc agent @提及往返** — 在 Feishu 群 @ 一个 cc flavor agent，确认**在 Feishu 里看到回复**（真回复，不是 ACK）。
- **L5 codex / curl flavor + protocol-api `/v1`** — 跑一个 codex 或 curl flavor agent；用 protocol-api 的 `/v1` 端点打一条消息并拿到回复。
- **L6 多 agent 接力（scenario-34）** — 触发一次多 agent 接力链路，确认 baton 按 sender 路由规则传递、链路跑完。
- **L7 world 页面渲染 + customer 公开视图** — 打开 world 渲染页面，并确认 customer 公开视图（未登录可见的对外视图）渲染正常。

每条腿都必须能在你的 tailnet 地址上被别人复看（这是本周的「看运行成果」方式）。

## 2. Branch / output model
- 你**不开 task 分支、不改 core、不改插件实现**。
- 每个 blocker → 开一个 `fix/<症状>` **占位分支**（描述症状 + 复现步骤 + 指向证据文件），路由给 owner：
  - core/domain session/resolver 类 → **@林懿伦**
  - cc-headless / agent-config 后端类 → **@黄佳佳**
  - agent console 前端 / #84 类 → **@戴明**
  - 官网 / world 渲染呈现类 → **@张宁**
- 你只验证 + 路由，绝不自己改 core（快照竞争是 @林懿伦 自己复现+修，**不再耦合给你** —— 你今天**不负责**那一条）。

## 3. Owned surfaces（你这条 track 只动这一处）
- `docs/together/2026-06-24/evidence/` —— 你的证据落盘目录（截图 / 日志行 / 请求-响应）。
- 各 `fix/<症状>` 占位分支的分支描述（不含实现 diff）。
- **不动**任何 `apps/**` 代码、不动其他人的 handoff。

## 4. Required reading（动手前）
1. 你自己的 `docs/together/2026-06-23/returns/world-deploy-e2e-pg.md` §7（上次跑到哪、踩了什么坑）。
2. `docs/guide/world-e2e-seed.md`（seed / 起站步骤）。
3. `docs/together/2026-06-24/handoffs/2026-06-24-all-devs-handoff.md`（看全员今天各跑什么，方便路由 blocker）。
4. `dev-together` skill —— 流程 + handoff 标准（DoD = 可演示证据）。

## 5. Definition of Done（可演示 artifact，不是「跑通了」口头）
- [ ] **每条腿（L1–L7）一份证据**落在 `docs/together/2026-06-24/evidence/`：
  - L1/L2/L7 → agent-browser 截图（登录页 / 创建页 / world 渲染页 + customer 公开视图）。
  - L3/L4/L5/L6 → 真渠道证据：Feishu 回复截图、protocol-api 请求-响应、接力链路日志行（关键 `:from` 路由行）。
- [ ] 每个 blocker 都有一个 `fix/<症状>` 占位分支 + 一行路由（症状 → owner）记进 evidence 目录的 `blockers.md`。
- [ ] 证据可在你的 tailnet 地址被团队复看。
- 你不写实现代码，**不要求** arch.scan/test 等代码门禁（那是 owner 修 bug 时的事）。

## 6. Discuss-first vs Deferred
**Discuss-first（早会）：** 无 —— 这是纯验证任务，没有需要先拍板的设计选项。
**Deferred：** blocker 的**修复**全部 defer 给各 owner（你只开占位分支 + 路由，不在本 track 修）。
**Never deferred here：** 每条腿的证据、blocker 的路由（当天发现当天路由，不攒着）。

## 7. Conflict-avoidance
你只写 `docs/together/2026-06-24/evidence/`，不碰任何 `apps/**` 或别人的 handoff，天然零冲突。占位 `fix/<症状>` 分支只放描述、不放 diff，owner 接手后在该分支或自己的分支上实现。

## 8. Merge model
你本 track 无代码 PR；evidence 直接落在 docs。各 `fix/<症状>` 分支由对应 owner 接手、按各自 handoff 的 merge model 合入。

## 讨论项（早会 standup — 谁需要在场）
- **本周度量口径 + tailnet 复看方式。** 参与：**@李震宇**（仅你）—— 确认本周「跑起来」的度量就是这七条腿的证据齐全，以及别人怎么走你的 tailnet 地址复看。
  - 注：快照竞争（snapshot race）**不在你的讨论项里** —— 那是 @林懿伦 独立复现+修的 core bug，本 track 与它**解耦**，你不必参与那条的拍板。
