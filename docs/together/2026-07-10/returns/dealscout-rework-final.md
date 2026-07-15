# Return（终版）— dealscout 改版收口：全链路证据重做 + orchestrator 真脑通 + kanban 闭环搭车

> **Task:** dealscout 改版 #1301 收口（取代本目录 dealscout-rework.md 的 pending 项）
> **Branch:** `feat/sw-dealscout-rework`（org）· **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-10 · **deadline_status:** on_time · **CI:** 发本 return 前旧 tip full-suite pass；终版 tip 复跑中，绿后方为终态

## 相比首版 return 的增量
1. **证据收口**：删旧套 25 件（#1294/#1311 之前的现实），重做一套连贯 26 件（`docs/e2e/2026-07-10/dealscout-rework-final/`），基于最新 main。
2. **安装无红条**（#1294 后现实）：4.42s 同步建成，requires 递归装出 orchestrator，4 成员全绿。
3. **orchestrator 真脑通（gap⑪ 复测通过，#1311 后第一次）**：真键盘 @ → ~65s 回话，内容准确复述角色分工/信号语义（legend protocol 生效）；不 @ 无回话 = routing 规则语义（`no_match` 如实拍，非故障）。
4. **kanban 真脑闭环搭车证据**（`docs/e2e/2026-07-10/kanban-brain-closure/`，7 件，证的是 main 的 #1311 非本分支）：@assistant 真回话 + `__done__` relay 后 assistant 14s 自主反应 + 负路径零反应 + 新物化 agent 凭证文件铁证。如实边界：assistant 仅回话记账，未发生 kanban.* dispatch（该会话无 board agent）——"自主操作看板数据"仍待后续。

## 最终分层结论（确定句）
发布 ✓ / 安装 ✓（无红条）/ **orchestrator 真脑 ✓** / @discover 真爬 ✓（py 3s 真 HN 数据）/ routing 命中 ✓ / crawl 数据面 ✓（CapBAC 身份注入+slice 回读）/ 自动发布 ✓（零干预 committed）/ **匿名公开页 ✓**（零 cookie 两轮 20→40 条真数据）。
两处如实缺口（均非本分支引入、不修）：routing→native 投递死（#1201②，平台）；「线索」view 主区渲染腿（kanban 同源既有缺口，internal render 已实证数据真）。

## 合并判定
**可合。** ①目标四条全满足（功能不变/真实组合 socialware/真页面真数据/四旅程划分——PR body 有归属表）；②全套 gate 绿 + 旧 tip CI pass、终版 tip 复跑中；③两处缺口均为平台既有、有 issue/归属；④基于含 #1294/#1311 的最新 main，无未决依赖。

## 作废的旧说法
"orchestrator 摆设/会话没人应答"（gap⑪ 已被 #1294+#1311 联合修复，本套实证）；"cc 凭证每日过期"（#1309 定界+#1311 修复）；旧证据目录 dealscout-rework/（已删）。

---

## 增补：零人工中继（路由配置修正，2026-07-10 晚）

**任务**（用户拍板原话）："搜集证据然后发布 page 是 dealscout 的功能，不能转向人工去 @，
不合理，是你配置错了。" 判据：@discover 之后不再需要任何人工动作，页面就更新。

### 最终形态（本次落进 PR 的路由改法）

旧配置把 `__dealscout_update__` 信号投给 `page`（native 工具，无 bridge 投递必丢
#1201②）。改法照 kanban 先例"信号路由给操作员、操作员 dispatch 工具动作"：

1. **routing receiver → `dealscout-assistant`**（新专属入库操作员槽，cc-headless
   × kanban-assistant 模具）；`page` 槽保留但不再当 receiver（dispatch-only 工具腿，
   与 #1319 L2 receivers_can_receive 相容）。防回环：from_role discover 硬锁不变。
2. **duty 走可信 persona 渠道**：recipe `config.system_prompt`（安装者配置的常设
   上下文，随 materialize 进 cc-headless SDK 会话 system prompt）+ shipped skill
   （`priv/skills_seed/dealscout-assistant/`）作详版手册；prompt template 瘦身为
   纯触发渲染（{body}+{session}），不再消息载权。
3. **官方 CLI 工具面**：crawler `behaviors/0` 全局注册 crawl_now/search（email
   plugin 先例）→ `mix ezagent session crawl_now/search` 真实子命令；操作员以
   自身份（T7d env）执行，CapBAC 照常裁决。
4. **crawler-page 不补 `passive: true`**（交付项核查结论=不该补）：passive-join
   三闸会在 materialize 拒掉 page 成员（session.ex:788-790），直呼腿按 members
   role_name 解析它（crawler.ex page_member_uri）就此断掉；kanban 的 passive
   board 是 workspace 级 actor、不进 role 槽——形态不同。已在 manifest/recipes
   注释立字据。

### orchestrator 拒绝实证（形态演进的证据，对照件保留）

先按候选 b 走 receiver=orchestrator（唯一持 within-session delegation
`orchestrator/caps.ex` Cap #1 + T7d CLI env 的执行者），cc 真脑**三轮原则性拒绝**
（09e/09g/09h 原文入库）：r1 拒消息体裸 erpc/eval（注入形态）；r2 核实了指令
合法、shipped 脚本无害，仍拒"要它亲手 cat 集群 cookie 起节点"（集群根凭证），
点名"把正规 skill/工具 dispatch 面落地"；r3 官方 CLI 工具面就绪后仍拒——
"路由消息自证授权 ≠ 主体授权"。**三轮姿态一致且正确：消息载权是死路**，
按主 agent 裁决切专属操作员（duty 走 persona）。

### assistant 链路证据（最远达成点，09m 根因表 + 09n/09q）

每轮一处根因一处修正（r4 cwd 缺目录 / r5 prompt 不落地 / r6 skill 不加载 →
找到 `config.system_prompt` 正道 / r8 UTF-8 env 编码 / r9 REPO_ROOT+权限 /
r10 SDK 车道缺 T7d env——后三处是 cc 插件死键补全，独立 commit）。最终轮：

> @discover → discover 3s 真爬（查询词 `coding agent`，线索全对题）→ 信号
> 自动路由给 assistant → **persona duty 主动接受**（"I'll process this update
> signal per my standing ingest role"）→ 定位仓库根 → 官方 CLI
> `mix ezagent session search --session … --query "coding agent"` 以自身份跑 →
> **token 验真通过**（entity_tokens verify + last_used_at 更新）→ CLI exec 的
> `identity.list_caps` 自呼 **5s 超时**（目标 = assistant 自己的 agent Kind，
> 正被本回合 `agent.receive` :call 占用整个 claude turn）→ assistant 如实
> 报告 injected: 0，不绕过不编造（09n 原文 / 09q 截图）。

### 结论（部分达成 + 精确阻塞点 + 根因归属）

零人工链的**授权与执行意愿层已实证打通**（这正是产品争议点：不是"必须人工
@"，而是操作员形态 + 平台 wiring 缺口）；剩两个平台级阻塞（归 Allen，不在
socialware 配置层硬凑）：

1. **CLI busy-Kind reentrancy**：`EzagentCli.Exec` 解析 caller caps 时 dispatch
   `identity.list_caps` 到 caller 自己的 live Kind（:call 5s）；cc-headless agent
   回合中 Kind 被占用 → 回合内自用 CLI 必超时。候选修法：caps 从 durable
   identity snapshot 读 / receive 改 :cast+ack / CLI busy-caller 回落。
2. **role-slot caps 自 scope**（读码判定，未被 e2e 触达）：GrantRecipeCaps 授予
   `kind=:agent, instance=self`（grant_recipe_caps.ex:209-232），session 宿主动作
   needed `kind=:session, instance=会话`（runtime.ex:401-441 + match.ex:27-38）
   ——即便 1 修掉，下一层大概率 unauthorized；socialware 声明的操作员缺
   session-scoped 授权车道（orchestrator 专属钩子是唯一先例）。

照 kanban 先例口径：当时"送达真、脑死于登录"也照实写，#1311 修了才补闭环——
本层同理，平台两口修掉后同一配置即可补拍全绿闭环。

### 本节 commits
- 9ce9136b4 fix(crawler): 更新信号改路由给 orchestrator（照 kanban 操作员先例）
- 388256c0e feat(crawler): dealscout-assistant 专属入库操作员（三轮拒绝实证后切 case-2）
- f6eb5b6e2 fix(cc): cc-headless SDK 车道三处死键/编码补全
- c50e9da7e docs(e2e): 零人工中继逐轮证据（09x）+ README 分层结论
