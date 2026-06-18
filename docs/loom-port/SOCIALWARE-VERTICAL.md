# Loom 作为 socialware vertical — 设计 spec

**Date:** 2026-06-18 · **Status:** design(与 Allen brainstorm 收敛)· **Branch:** `loom-socialware-vertical`(基点 `loom-on-main-pr3`)

> 决策依据:`docs/superpowers/specs/2026-06-09-socialware-substrate-design.md`(task #46)—— socialware substrate 设计要求把「AI 页面 / 顾客 app」做成 substrate 上的一个 vertical。本 spec 是 loom 对齐该设计的实现说明 + 分期进度。

---

## 1. 目标 & 非目标

**目标**:loom 不再是"自带一整套平行 Kind 栈的独立 plugin",而是 **socialware substrate 上的一个 vertical** —— 一个 `Kind.Template`,spawn 统一的 `Ezagent.Entity.Session` Kind + socialware 行为子集,页面状态/版本/投递全走 substrate(Surface/Turn/Publisher/CustomerFeed),功能(对话建站、发布、fork、接线员、导购、素材)不丢。

**非目标**:重写前端 SPA(独立仓库,本期用 shim 兼容,re-point 留 P4);改 substrate 本身(只**用**它,不改 core/domain 行为)。

## 2. 范式(样板:`EzagentPluginAdvisor.Template.AdvisorSession`)

socialware vertical 的标准形态(P5-1b collapse 之后):

- vertical = **一个 `Kind.Template`**(如 `session.advisor`),不是新 Kind。
- `instantiate`:`Kind.spawn(Entity.Session, %{uri, behaviors: Session.socialware_behaviors()})` —— 全局**一个** session Kind,差异靠 spawn 时传的**行为子集** + working-copy **配置** + 成员/角色。
- `Session.socialware_behaviors()` = `{Session, Turn, Surface, Publisher}`(Turn/Surface active,ExternalMirror 排除)。
- 配置进 working-copy:`Behavior.Session.system_set_working_copy(session_uri, %{"vertical"=>..., ...})`。
- 成员/角色:`session.join`(operator 等)。

## 3. 锁定的设计决策(brainstorm 结论)

| # | 决策 | 选择 |
|---|---|---|
| D1 | agent 团队形态 | **C(混合)**:页面状态/版本/投递走 substrate;codegen/编排保留为成员 agent |
| D2 | 编排器 | **C1**:采用 substrate 的 `Turn` 当编排器,**丢掉 `LoomOrchestrator`**;builder/workers 是 Turn 派活的成员 agent |
| D3 | 页面 | `Behavior.Surface`(版本 + `approved` 指针);`approve` = 发布 |
| D4 | 消费侧 | 全搬 socialware customer 投递(`CustomerFeed`/`CustomerChannel` + `AnonUser`/`AnonBinding`/`CustomerAuth`);loom 自管 `temp_user`/`/loom/p`/`snapshots` 退役 |
| D5 | 接线员同伴集 | operator 作为角色 join;跨会话同伴聚合**先保留为基于 lineage 的薄查询**,不进 substrate |
| D6 | fork | 用 socialware **template/snapshot** 实例化新 vertical session(带 builder),替代 saved_classes fork |
| D7 | AiSpot / 消费侧 user_schema | AiSpot ✨ 保留 loom 自己的轻量直连;消费侧 user_schema 叠加**砍掉**,"要改就 fork"(对齐 Surface 的 operator-编辑/customer-只读) |
| D8 | 前端 | **F1** 先行(`/loom/api` shim,底层驱动 substrate;customer 段委托 CustomerFeed)→ **F2**(前端 re-point)留 P4 |

## 4. 创作闭环(C1:Turn + Surface + manager + workers)

`Behavior.Turn`(`:turns` slice)是纯状态机:`open → dispatch(subtasks) → deliver → compose → settle`;subtasks **由调用方(manager)传入**,Turn 不自拆解;Turn 记一个 **manager URI** 当驱动者。`Behavior.Surface`(`:surface` slice = `%{versions, approved, version_seq}`):`put_version(turn_id, tree)` 追加不可变版本,`approve(version)` 进发布,`commit_settlement` 触发 customer 投递。

闭环:

```
用户(创作)消息
 → loom turn-manager agent(= LoomOrchestrator 瘦身版)收到
 → LLM 决定 subtasks(派哪些 worker / builder 做什么)
 → Turn.open + Turn.dispatch(subtasks)        # 经 chat.send 派给成员 agent
 → builder / theme worker 成员 agent LLM 干活 → Turn.deliver(card_ref)
 → manager 合成 → Turn.compose → Surface.put_version(tree)   # 新页面版本
 → operator → Surface.approve + commit_settlement            # 发布 + 投递
```

- **turn-manager agent**(LoomOrchestrator 瘦身):只留 LLM 拆解/合成的脑子,驱动 substrate Turn;**不再自管页面/turn 状态**。即 Turn 的 manager。
- **builder**:成员 agent,唯一的源码生成者;deliverable 即页面 `tree`。简单编辑 = 单 subtask(builder)→ compose → put_version;复杂 = fan-out theme workers + builder。
- **theme workers**:成员 agent,Turn 派活。
- 页面源码不再进 orchestrator slice,而是 Surface 的 `tree` 版本。page_update 版本史 → Surface `versions` + Publisher trunk。

## 5. 消费侧(D4 / socialware customer 投递)

`Socialware.CustomerFeed.snapshot(session_uri, token)` 返回 **approved Surface 版本 + committed customer-visible 消息**,token 门控,走 `CustomerChannel`/`customer_socket`;"customer 路由必须用 CustomerFeed"。匿名:`AnonUser` + `AnonBinding`(`socialware_anon_bindings`)+ `CustomerAuth`(session-bound feed token)。

| loom 自管消费侧 | → socialware |
|---|---|
| `/loom/p/<token>` + `temp_user` | `CustomerAuth` token + `AnonUser`/`AnonBinding` |
| 冻结 base / 已发布版 | Surface `approved` |
| 发布页 customer_visible 消息 | `CustomerFeed` + `CustomerChannel` |
| 导购 salesperson(已出 customer_visible 消息) | 留作**成员 agent**,经 CustomerFeed 投;DeepSeek 直连只是后端选择,不影响其在 session 上 |
| `consumer_session`/`snapshots`/`owned_sessions` | 退役 |

## 6. agent 落位表

| loom 现在(独立 Kind) | vertical 里 |
|---|---|
| `LoomOrchestrator` | → **turn-manager 成员 agent**(瘦身,驱动 Turn),不再是 Kind |
| `LoomWorker`(themes) | → Turn 派活的**成员 agent** |
| builder(loomv0/builder) | → **成员 agent**,deliverable = Surface tree |
| `LoomSalespersonWorker` + sub | → 消费侧**成员 agent**(customer_visible 消息) |
| `LoomMetaAgent`(@ 加/删) | → session 成员管理 |
| `Ezagent.Entity.Loom` 等独立 Kind | → 退役;统一 `Entity.Session` |

## 7. 存储/配置归位

| loom 旁路/slice | 去向 |
|---|---|
| 页面源码 + 版本史 | **Surface**(版本 + approved) |
| workers / roles / knowledge / pages / danmaku / salesperson 配置 | session **working-copy / `ConfigUpdate` slice** |
| `saved_classes`(Plan B 发布物) | socialware **template/snapshot** |
| `lineage`(谱系) | 薄 sidecar(metadata)或从 template/snapshot 派生 |
| `consumer_sessions`/`owned`/`snapshots`/`salesperson_chats`/`user_schema`/`page_init` | 退役(消费侧搬走 / 变 session 消息 / 按 D7 砍) |
| `stats` | 薄 sidecar 或进 slice(无所谓) |
| **`loom_materials/<ws>/<sid>/`** | **保持文件系统不动**(输入文件,非 session 状态) |

## 8. 前端(D8)

- **F1(本期)**:后端全上 substrate;`WebPlug` 留薄 shim,`/loom/api/*` 不变,handler 底层驱动 Turn/Surface/CustomerFeed(创作面 → session dispatch + Surface;消费面 → 委托 `CustomerFeed`)。vendored loom_ui 零改动可跑。
- **F2(P4)**:前端仓库改 SDK 桥直连 `CustomerChannel`/session 路由,退 `/loom/api`。

## 9. 实施分期(每期可测)

| 期 | 内容 | gate |
|---|---|---|
| **P0** | `LoomSession` Template:spawn `Entity.Session` + socialware 子集(+`ConfigUpdate`),working-copy 存配置;页面进 Surface | loom session 以 SocialwareSession 存在;页面经 Surface put/approve 跑通;customer 能读 approved |
| **P1** | turn-manager + builder/worker 成员 agent 上 Turn 闭环 | 对话生成页面在 substrate 上跑通 |
| **P2** | 消费侧上 socialware(CustomerAuth+anon,CustomerFeed/CustomerChannel,salesperson 成员 agent) | 发布页经 socialware customer 投递跑通 |
| **P3** | 配置归位、接线员(薄 cohort 查询)、fork(template/snapshot)、AiSpot/弹幕 | 功能对齐 |
| **P4** | F2 前端 re-point + shim 退场 + 旧数据迁移 + 退役老 store | 全量切换 |

## 10. 开放问题 / 实做时验证

1. **Turn.compose 能否表达"整页替换"**:builder 一把梭生成整页 tree → compose → put_version 的粒度,P1 实做时验证(预计单 subtask 即可)。
2. **行为子集是否要 `ConfigUpdate`**:page-app 设计列的是 `{Chat,Turn,Surface,Publisher,ConfigUpdate}`;loom 配置进 working-copy 是否够,还是需要 `ConfigUpdate` 的 self-evolve,P0 定。
3. **manager 驱动权限/caps**:turn-manager 作为 session manager 的 caps 怎么授(参考 advisor 的 `template-materialize` 主体 + Turn 的 manager URI 机制)。
4. **接线员同伴集**(D5)长期是否该进 substrate(目前薄查询),留作后续。
5. **素材库**与 builder agent 的 cwd/Read 在新成员-agent 形态下的接法(应不变,但确认)。

## 11. 明确退役 / 不做

- 退役:`LoomOrchestrator`/`LoomWorker`/`Entity.Loom` 等独立 Kind、`temp_user`/`consumer_session`/`snapshots`/`owned_sessions`/`user_schema`(消费侧)及对应旁路 JSON。
- 不做(本期):前端仓库改造(P4)、改 substrate 行为、消费侧 user_schema 叠加(D7)。

---

## 12. 实施进度

**架构核心已端到端打通并验证**(5 个测试绿):loom session = 统一 SocialwareSession → TurnManager 驱动 Turn/Surface 创作闭环 → 页面落 Surface → settlement → **CustomerFeed 把已发布页投给消费者**。即「loom 走 socialware」已证明。

| 期 | 状态 | 产物 / 测试 |
|---|---|---|
| **P0** | ✅ DONE | `Template.LoomVerticalSession`(class `session.loom_vertical`,strangler)spawn 统一 `Entity.Session` + `socialware_behaviors()`,working-copy + operator join。`test/.../loom_vertical_session_test.exs`(1)证明 Turn/Surface active + 页面经 Surface。 |
| **P1** | ✅ DONE | `PluginLoom.TurnManager.build_page/4` 用**生产 within-session cap**(非 bootstrap)驱动 open→compose→settle,页面落 approved Surface 版本。`turn_manager_test.exs`(2)。 |
| **P1b** | ✅ DONE(LLM 路径 compile + 运行期验,非 CI) | `PluginLoom.PageGen` 把 loom 现有 builder codegen(`Prompts.page_gen_system_prompt`+`LLM.chat`+`extract_files_and_summary`)包成注入的 generator。 |
| **P2** | ✅ DONE | loom deps `ezagent_domain_socialware`;消费者经 `CustomerFeed.snapshot` 读 approved 页 + customer 消息。`loom_vertical_consumer_test.exs`(2):创作 turn → 消费者读到页面 + chat;跨 ws token 被拒。 |
| **P3 web/F1** | ✅ DONE(运行期实测) | `PluginLoom.Vertical`(`ensure_session`/`seed_page`/`author`)把 loom_ui 接到 substrate:`web_plug` send→`Vertical.author`、heal_team gate、create-on-access。实测:建站→`@builder` 出页(9422 字符)→ 渲染。 |
| **团队恢复** | ✅ DONE(运行期实测,Option A) | 多智能体团队作为 vertical session **成员 agent** 恢复:`@builder` 出页(落 Surface)、`@meta` 加/删 worker(进 `WorkerConfig`,团队 modal 可见)、`@worker_<theme>`、salesperson 导购(消费侧 DeepSeek)。**不 @ = 纯发言、不出页**(编排器 mention-gated)。 |
| **P3 余项** | 进行中 | 接线员(薄 lineage 查询)、fork、配置归位、AiSpot/弹幕、多页、角色门控、素材库 —— 沿用既有实现并接进 vertical;匿名访客身份依赖 substrate `public_view`(`:pending_impl`),带 token 的消费路径已可用并实测。 |
| **P4 cutover/F2** | 进行中 | `session.loom` 已切到 vertical(`Template.LoomSession.instantiate` → `Vertical.ensure_session`);退役旧独立 Kind/store + 数据迁移、前端仓库 re-point(**源码不在本仓库**)为后续项。 |

> 这次重构最核心的部分 —— 把 loom 搬到 substrate 的 Turn/Surface/CustomerFeed,统一 SocialwareSession + 团队成员 agent + `@builder` 出页落 Surface + 消费侧 —— 已端到端跑通并实测。后续是集成广度:外围功能归位、cutover 收尾,以及在**另一个仓库**的前端 re-point。

## 13. 附录:实做补充的 grounded 契约(来自 substrate 代码 + advisor 样板)

- **spawn**:`Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri, behaviors: Ezagent.Entity.Session.socialware_behaviors()})`;`socialware_behaviors/0 = [Behavior.Session, Behavior.Turn, Behavior.Surface, Behavior.Publisher.SessionImpl]`;`:behaviors` 必传,作为 per-instance active set 持久(`requires_explicit_behavior_set? → true`)。
- **caps**:驱动 Turn/Surface 的测试主体用 `Ezagent.SystemPrincipal.caps("system://bootstrap")`;join/spawn 用 `SystemPrincipal.uri("template-materialize") |> SystemPrincipal.caps()`;working-copy 写用 `system://session-internal`(`Behavior.Session.system_set_working_copy/2` 内部已用)。**无需新增 system principal**(catalog 是 closed allowlist,改它要单独 review)。
- **Turn**(slice `:turns`):`open(%{trigger, opened_at})→%{turn_id}`;`dispatch(%{turn_id, subtasks:[%{id: atom, mention, prompt}]})` —— **worker 靠 `mention` 寻址**(发一条 `chat.send`,body.metadata.correlation = `%{turn_id, subtask_id}`);worker → `deliver(%{turn_id, subtask_id, card_ref})`;**`compose(%{turn_id, result_refs})` 可直接吃 `[%{kind: :chat, text}, %{kind: :page, tree}]`**(简单路径可跳过 dispatch/deliver,manager 直接 open→compose→settle),compose 自 dispatch `Surface.put_version`;`settle` 把 `approve`+`commit_settlement` 作 `:dispatch_after_commit` 延后(→ customer 投递)。manager = settling caller,需 `[:open,:dispatch,:compose,:settle]` + Surface `[:put_version,:approve,:commit_settlement]`。
- **Surface**(slice `:surface = %{versions, approved, version_seq}`):`put_version(%{turn_id, tree})`→version;`approve(%{version})`;`commit_settlement(%{turn_id})`→`Settlement.commit_after_pointer`。operator 读 latest,customer 读 **committed**(经 `CustomerOutbox` 的 `surface_version`,非裸 `approved`)。
- **消费侧只读**:无 customer/anon send 路径;customer-visible 消息只经 settlement 进。anon = `AnonUser.mint_for_public_session`(需 Template `public_view: true`)+ `AnonBinding` cookie + `ChatFeedAuth`,读经 `CustomerFeed.snapshot/2`(`%{messages, page}`)/`ChatFeed`。**loom P2 需让 LoomVerticalSession 声明 `public_view`,并加 `ezagent_domain_socialware` 依赖。**
- **P1 待定细节**:compose 的触发——manager 直接 open→compose→settle(简单页),还是 dispatch→workers deliver→manager compose(fan-out)。两者都可;builder 的 deliverable = `%{kind: :page, tree}`。
- **agents 不消失**:builder/workers 仍是 session 成员 agent(收 @mention → LLM → `Turn.deliver`);`LoomOrchestrator` 的脑子 → turn-manager。advisor 自己零 agent(纯 working-copy 数据角色),loom 因要 LLM codegen 必须有成员 agent。
