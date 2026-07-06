# hello → 标准 socialware substrate + 框架 routing table 设计 (B')

> **Date:** 2026-07-06 · **Author:** zhangning (via Claude) · **Branch:** `feat/hello-0705`
> **Supersedes:** `2026-07-03-hello-orchestrator-router-design.md`(自建 `Router.route` 直分发的版本)
> **Decision:** 用户在 3 个岔路上选定:目标能力=全套(名正言顺+多 agent 接力+动态团队+版本化迁移);substrate 路径=**B 插件级混合**;编排器落法=**B' 插件级 role×flavor 编排器成员**。

## 目标

把 hello session 从"hello 自建的 `Router.route` 直接分发到 builder/concierge"迁到**标准 socialware substrate**:

- session = **public_view 版本化 `SessionTemplate`**,带 socialware `Definition`(`shape: [Turn, Surface, SupervisorApproval]`, `views: ["hello_render"]`)。
- builder / concierge / orchestrator = **声明式 `Definition.roles`**(每个 `%{role_name, fill: :agent, recipe, flavor}`;**注意:字段名是 `roles` 不是 `agents`**——`agents`/`members` 是被 `reject_retired_declaration_fields/1` 拒绝的退役字段),不再由 hello 代码 ad-hoc `ensure_*` + 直调 `Generator`。
- 分发走**框架 routing table**(`Definition.routing_rules` → `RoutingRegistry` → `Resolver`),而非 hello 自建的 web 层 mention + `Router.route`。
- 编排器**保留**为 hello 自己的 role×flavor 成员(自带 hello persona),**逐条消息**做 `owner? + 意图分类`决策;决策留在 Elixir,routing table 只搬运。
- 顺带修掉当前的两个缺陷:**只接受人的消息**(拒绝 agent 消息)和 **loop 隐患**(缺 `from_user?` 守卫)。

**净结论:这不是推倒重建。** hello 现有的 role×flavor 编排器成员 + `TurnDriver` 页面 chokepoint 都保留;delta 是"自建分发 → 框架 Definition + routing table + 声明式成员 + 版本化模板"。

## 为什么不是"字面框架 cc-orchestrator"(已证实的硬约束)

2026-07-06 三轮 Explore 交叉核实(read-only,file:line 见下),证实框架 cc-orchestrator 在插件层给不了 hello 要的东西:

1. **cc-orchestrator 不能画页面。** 其 MCP 工具目录(`tool_catalog.ex`)只有 12 个团队+版本工具,**无任何 Surface/Turn 工具**;其 recipe(`orchestrator_recipe.ex:71-76`)只申请 Template caps,**无 Surface/Turn cap**。socialware skill 里"customer UI 由 orchestrator 逐轮生成"是**文档愿景,代码无此路径**。每个 socialware 页面(含标准模型)实际都在 `TurnDriver` / `SurfaceSeed` 的 admin-genesis chokepoint 出生。
2. **persona 换不了(插件层)。** `orchestrator.ex:94` `ensure_orchestrator` **写死**用 `template://system/agent/cc-orchestrator`;SessionTemplate 的 `orchestrator_template_uri` 字段**被存了却从不用来选模板**。给框架 cc-orchestrator 换 hello persona = 改核心那一行(留给 Allen,见"后续")。
3. 插件层的正路(Explore 原话):"No core/domain change is required to build the app the way `ezagent_plugin_hello` already does it" —— 即**编排器做成 role×flavor 成员**(persona 走 role recipe prompt),这正是 hello 现状。

因此 B':substrate 标准化,编排器仍是 hello role×flavor 成员。"名正言顺"落在底层 substrate 上;编排器不是 stock cc-orchestrator。

## routing table 的角色:搬运工,不是决策者

框架 routing table 是**静态**的(`{from:X}->Y`,"no model-computed baton"),匹配器只有 `{:always}` / `{:from,X}` 一类,**没有"发送者是不是 owner"的谓词,更无意图分类**。所以:

- routing table **能**表达固定跳转:入站(人+agent)→ 编排器;编排器 relay `{:role,"builder"}` / `{:role,"concierge"}` → 该成员(经 `Members.role_name_to_uri` role_name→URI,`resolver.ex:435-460` / `route_provisioner.ex:10-17`)。
- owner/visitor + 意图**决策进不了 routing table**,留在编排器成员的 Elixir 行为里(`owner?` + LLM 意图分类)。

这与标准 socialware 一致:规则在固定端点间搬消息,编排器 agent 是"聪明的一跳"。

## 架构

```
人 或 外部 agent 发消息 → session.send(sender 保留原始发送者)
  → 框架 routing table(默认 mention-gate 规则 + 可选 Definition inbound 规则)
        投递到编排器成员                              (routing table 只承载入站→编排器)
  → 编排器成员经 "hello" flavor bridge adapter → HelloOrchestrator.:hello_sync_result
       · 守卫:发送者是自己 / 自己的 builder|concierge 成员 → 忽略(不路由,防 loop)
       · owner?(session, sender)  (读 :owner_uri slice,ownerless→fail-open)
       · owner 且 build 意图(LLM 分类,复用 Generator/claude_code)→ 目标=builder
         其余(非 owner 恒定 / owner 非 build 意图 / 外部 agent)→ 目标=concierge
       · 进程内直接 handoff(不进 routing table,避免 $session_users 泄漏 + 跨 agent 铸 cap):
           - builder   → Generator.generate(session)         → TurnDriver.drive(admin-genesis) → Surface
           - concierge → Generator.concierge_answer(session, concierge_uri)  (署名 concierge 成员)
  → 页面上屏 / 只读回复
```

**为什么 orchestrator→成员是直接 handoff 而非走 routing table**:核实(2026-07-06)默认路由规则把 `$session_users` 与 `$mentions` 绑在一条(`default_rules.ex:20`),`$session_users` 无条件广播给每个 user 成员——若把 relay 发进 session,内部路由会**泄漏到 owner+访客的公开 feed**;且投给成员 `:receive` 需跨 agent 现铸 `:receive` cap(脆弱,2026-07-03 spec 已因此弃用)。框架自己的 cc-orchestrator 也**不**逐条 relay 走 table(它装静态规则或在 LLM 内决策)。故 per-message 决策+投递留在编排器 Elixir,与框架一致。

**loop 安全 + 多 agent**:守卫从"只接 user"改为"**忽略自己 + 自己的 builder/concierge 成员**,其余(user + 外部 agent)都路由"。这同时:(a)修掉当前 `Router.route` 无守卫的 loop 隐患(moduledoc 声称 loop-safe 但代码未实现);(b)兑现"不止人的消息"——外部 agent 消息按非 owner 走 concierge。加回归测试。

## 组件与改动

### 1. SessionTemplate / Definition(标准 socialware)
- hello session 用 **public_view 版本化 `SessionTemplate`**(`SessionTemplate.persist_version_as_system/2` 或 world 授权路径),content 含 `public_view: true`。
- `Definition`:`shape: [Turn, Surface, SupervisorApproval]`,`views: ["hello_render"]`(demo `hello.ex` 已示范),`roles: [orchestrator, builder, concierge]`(**字段名 `roles` 非 `agents`**),`routing_rules: [...]`。

### 2. 编排器(保留,微调 + flavor 承载行为)
- role `hello.orchestrator` × **`"hello"` flavor**;自带 persona(role recipe `prompt`)。
- 行为 `Ezagent.ActionSet.HelloOrchestrator` 处理 `:hello_sync_result`(经 "hello" flavor 的 in_process_sync bridge adapter;`:receive` 被 flavor-blind 的 `Agent.Receive` 占用,不能被 role 行为覆盖——故走 bridge adapter 这条既有路)。
- **关键改动:把 `HelloOrchestrator` 挂到 `"hello"` flavor 的 `instance_behaviors`**——因为改走 `Definition.roles` materialize 后 `recipe.behaviors` 被丢弃,若只在 recipe 声明,`:hello_sync_result` action 不会进实例 behavior set。参照 py flavor。
- `:hello_sync_result` 里做 `守卫 + owner? + 意图分类 + 直接 handoff`(见数据流);**决策留 Elixir**(可确定性 + 复用现有 `owner?` / `classify_intent`)。

### 3. builder / concierge(声明式成员,identity-only)
- 声明为 `Definition.roles`(`fill: :agent`,固定 role_name `"builder"` / `"concierge"`,`flavor: "native"`),caps 走 recipe `requested_caps`(`GrantRecipeCaps`,`definition_agents.ex:134,303-308`)。materialize 由 `TemplateTeam.materialize_template_team` → `DefinitionAgents.materialize_definition_agents`(消费 `roles` 过滤 `fill: :agent`)。
- **B'-direct 下 builder/concierge 是 identity-only 成员**:编排器直接调 `Generator`(署名到成员 URI),不触发它们的 `:receive`。因此它们**不需要**自定义 flavor / instance_behaviors —— 只需作为声明成员存在(用于:身份/署名、@-mention、world 展示、模板捕获、migrate)。现有 `HelloBuilder`/`HelloConcierge` 的 `:receive` 成为**休眠回退**(`Definition.roles` 路径丢 recipe.behaviors 后甚至不会被装上,天然 inert;保留模块供未来 B'-table)。
- **简化(相对早先"每 role 一 flavor"):只有编排器需要行为承载 flavor(§2 的 "hello" flavor);builder/concierge 用现成 `"native"` flavor,零新 flavor。** 页面生成路径 `Generator → TurnDriver`(admin-genesis chokepoint)**不变**。

### 4. routing table(只承载入站→编排器)
- **入站→编排器**:走框架 routing table。hello 现状已用默认 mention-gate 规则(web `dispatch_post` 发 `session.send` + `mentions: [orchestrator_uri]`,`session_feed_channel.ex:352-379`)达成;B' 保留此机制,并**可选**在 `Definition.routing_rules` 显式声明一条入站→`{:role,"orchestrator"}` 规则(把路由意图写进模板 = 更名正言顺;additive,不改 `$session_users` 现有行为)。
- **orchestrator→成员不进 routing table**(见数据流的"为什么");这一跳是编排器 Elixir 内的直接 `Generator` handoff。
- 移除 hello 自建的 web 层 owner/访客分流(该判定移入编排器);`Router` 逻辑保留但加守卫。

### 5. 版本化 / 迁移
- session 绑定到版本化模板的 `@hash` URI(避开 `"current"` tag 未自动发布的坑)。
- `migrate_session`(`Ezagent.Orchestrator.Tools.Migration`)/ `update_template` 经框架工具(Elixir/CLI)可用;现有 v3 session 走重建或 migrate 到新版本化模板。

## 四个诉求兑现度(诚实)

| 诉求 | 兑现 |
|---|---|
| 名正言顺 | ✅ substrate 全标准(Definition.roles 声明式团队 / 入站走 routing table / 版本化模板 / Turn/Surface)。⚠️ 编排器是 hello role×flavor 成员,非 stock cc-orchestrator;orchestrator→成员是 Elixir 直投(与框架 orchestrator 一致,它也不逐条 relay 走 table) |
| 多 agent 接力(不止人的消息) | ✅ 守卫改为"忽略自己+自己的 builder/concierge,其余(user+外部 agent)都路由";外部 agent 按非 owner 走 concierge |
| 动态团队管理 | 🟡 builder/concierge 声明式;编排器动态 `add_managed_member` 留后续 |
| 版本化 + 迁移 | ✅ 框架 SessionTemplate 版本化 + `migrate_session` |

## 约束与风险

1. **决策 + orchestrator→成员投递都在 Elixir,不进 routing table**(刻意;routing table 表达不了 owner/意图,且走 table 会经 `$session_users` 泄漏内部 relay 到公开 feed)。routing table 只承载入站→编排器。
2. **编排器行为必须挂 `"hello"` flavor `instance_behaviors`**,不能只放 `recipe.behaviors`(`Definition.roles` 路径已证实丢弃)。builder/concierge identity-only,零新 flavor。
3. **拓荒**:全仓库无 cc-orchestrator+Surface 先例;但 B' 不用 cc-orchestrator,走 hello 已验证的 role×flavor + `TurnDriver`,风险显著低。
4. **迁移**:现有 v3 session 重建或 `migrate_session`。
5. **首版不碰核心**;`orchestrator.ex:94`("字面 cc-orchestrator" 升级)留给 Allen。

## 不做(YAGNI)

- 不改 `orchestrator.ex:94`(核心,留 Allen)。
- 不建 native-role AgentTemplate 装配 / 成员 Surface 委托 cap / RoleTemplate Kind(均 deferred core)。
- 首版不做编排器动态 `add_managed_member`(声明式成员够用)。
- 不把路由决策改成 LLM 自然语言编排(保留 Elixir 可确定性)。
- **不把 orchestrator→成员这一跳走 routing table**(B'-table);会泄漏 + 需私有 rule-set,留作后续。
- 不给 builder/concierge 建自定义 flavor(identity-only,`:receive` 休眠)。

## 验收(e2e)

1. owner 发"改标题" → 页面经 builder→TurnDriver 更新(Surface put_version)。
2. visitor 发同样消息 → concierge 只读回复,**页面不变**(非 owner 永无改页权,神圣边界)。
3. **agent 发消息** → 编排器接收并路由(不再被 human-only 拒绝)。
4. **无 loop**:concierge/builder 产出不触发编排器再路由(回归测试)。
5. `migrate_session` 把现有 session 迁到新版本化模板成功。
6. `mix precommit` + `mix ezagent.check_invariants` 绿。

## 关键 file:line 证据(核实来源)

- cc-orchestrator 无 Surface 工具:`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`;recipe 只申请 Template caps:`orchestrator_recipe.ex:71-76`。
- 页面 chokepoint:`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/turn_driver.ex:40-82,150-159`(admin-genesis);`apps/ezagent_domain_session/lib/ezagent/session/surface_seed.ex:71-112`。
- persona 写死:`apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:94`;`orchestrator_template_uri` 被忽略。
- `Definition.roles`(`fill: :agent`)授 caps:`definition_agents.ex:134,303-308`;`roles` 过滤 + materialize 入口:`template_team.ex:8-52`;丢弃 recipe.behaviors:`recipe_materializer.ex:68-74`;custom flavor instance_behaviors:py `application.ex:108`。Definition 无 `agents` 字段(退役):`definition.ex:313-321`。
- routing 定向:`resolver.ex:435-460`;`route_provisioner.ex:10-17`;`members.ex:83-86`。mention-gate 默认(`$session_users`+`$mentions` 绑一条,user 无条件广播):`default_rules.ex:20,90-91`;`resolver.ex:356-371,388-405`。
- 入站投递现状:`session_feed_channel.ex:352-379`(`session.send` + `mentions:[orchestrator_uri]`,sender=user)。发消息 = dispatch `session.send`(`session.ex:147,540`);`Message.new/3` mentions/sender(`message.ex:142`);Delivery 保留 msg.sender 逐成员投:`delivery.ex:169-185`。agent 入 session 发消息先例(无 mention):`plugin_cc/bridge_adapter.ex:131-192`。无"逐条 relay 给成员"先例。
