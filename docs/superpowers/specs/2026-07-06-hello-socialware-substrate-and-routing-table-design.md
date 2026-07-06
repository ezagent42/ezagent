# hello → 标准 socialware substrate + 框架 routing table 设计 (B')

> **Date:** 2026-07-06 · **Author:** zhangning (via Claude) · **Branch:** `feat/hello-0705`
> **Supersedes:** `2026-07-03-hello-orchestrator-router-design.md`(自建 `Router.route` 直分发的版本)
> **Decision:** 用户在 3 个岔路上选定:目标能力=全套(名正言顺+多 agent 接力+动态团队+版本化迁移);substrate 路径=**B 插件级混合**;编排器落法=**B' 插件级 role×flavor 编排器成员**。

## 目标

把 hello session 从"hello 自建的 `Router.route` 直接分发到 builder/concierge"迁到**标准 socialware substrate**:

- session = **public_view 版本化 `SessionTemplate`**,带 socialware `Definition`(`shape: [Turn, Surface, SupervisorApproval]`, `views: ["hello_render"]`)。
- builder / concierge = **声明式 `Definition.agents`**(固定 role_name),不再由 hello 代码 ad-hoc `ensure_*` + 直调 `Generator`。
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
人 或 agent 发消息
  → 框架 routing rule {:always} → 编排器成员      (routing table,静态)
  → HelloOrchestrator.:receive
       · from_user? / from_agent? 都接(修 human-only + loop 守卫)
       · owner?(session, sender)  (读 :owner_uri slice,ownerless→fail-open)
       · owner 且 build 意图(LLM 分类,复用 Generator/claude_code 管道)→ 目标=builder
         其余(非 owner 恒定,或 owner 非 build 意图)→ 目标=concierge
       · emit relay,mention {:role, target}                (routing table 定向投递)
  → target 成员.:receive
       · builder  → Generator.generate → TurnDriver.drive (admin-genesis) → Surface put_version+set_shell
       · concierge→ Generator.concierge_answer(署名 concierge)
  → 页面上屏 / 只读回复
```

**loop 安全**:编排器的 `:receive` 加 `from_user? / 目标成员回执` 守卫——编排器只对"需要路由的入站消息"动作,对 builder/concierge 产出的回执/自身 outbound 不再路由。当前代码缺这个守卫(moduledoc 声称 loop-safe 但未实现),B' 补上并加回归测试。

## 组件与改动

### 1. SessionTemplate / Definition(标准 socialware)
- hello session 用 **public_view 版本化 `SessionTemplate`**(`SessionTemplate.persist_version_as_system/2` 或 world 授权路径),content 含 `public_view: true`。
- `Definition`:`shape: [Turn, Surface, SupervisorApproval]`,`views: ["hello_render"]`(demo `hello.ex` 已示范),`agents: [orchestrator, builder, concierge]`,`routing_rules: [...]`。

### 2. 编排器(保留,微调)
- hello role `hello.orchestrator` × hello 自定义 flavor,自带 persona(role recipe `prompt`)。
- 行为 `Ezagent.ActionSet.HelloOrchestrator`:`:receive` 里做 `owner? + 意图分类 + emit relay`(不再直调 `Router.route` 的 ad-hoc `ensure_*`)。
- **决策留 Elixir**(可确定性 + 复用现有 `owner?` / `classify_intent`)。

### 3. builder / concierge(声明式成员)
- 声明为 `Definition.agents`(固定 role_name `"builder"` / `"concierge"`),caps 走 recipe `requested_caps`(`GrantRecipeCaps`,`definition_agents.ex:134,303-308`)。
- **行为挂在 flavor 的 `instance_behaviors`**,**不放 `recipe.behaviors`**(Definition.agents 路径丢弃 `recipe.behaviors`,`recipe_materializer.ex:68-74`;已证实)。参照 py flavor `instance_behaviors: fn -> base ++ [PyAgentBehavior] end`。
- **flavor 粒度(已定):每个 role 一个 flavor**——`instance_behaviors` 对该 flavor 的**每个** agent 的 `:receive` 都触发,所以三个 role 不能共用一个 flavor(否则 builder 也会跑 concierge 行为)。故:`hello-orchestrator` flavor(带 `HelloOrchestrator`)、`hello-builder` flavor(带 builder 行为)、`hello-concierge` flavor(带 concierge 行为),各自 `instance_behaviors` 只含自己那一枚。(备选"单 flavor + 按 role 分派的单行为"更省 flavor 但要在行为里读 role 分支;首版取"每 role 一 flavor"求简单直白,planning 阶段若发现 flavor 注册成本高可再收敛。)
- builder `:receive` → `Generator.generate` → `TurnDriver`;concierge `:receive` → `Generator.concierge_answer`。页面生成路径**不变**。

### 4. routing table
- `Definition.routing_rules`:
  - 入站(人+agent)→ 编排器成员(`{:always}` 或等价,投给 orchestrator role_name)。
  - 编排器 relay:编排器 emit 的消息 mention `{:role,"builder"}` / `{:role,"concierge"}` → 该成员(`Resolver.expand_receiver({:role, name})`)。
- 移除 hello 自建的 web 层 owner/访客分流 + `Router.route` 直分发。

### 5. 版本化 / 迁移
- session 绑定到版本化模板的 `@hash` URI(避开 `"current"` tag 未自动发布的坑)。
- `migrate_session`(`Ezagent.Orchestrator.Tools.Migration`)/ `update_template` 经框架工具(Elixir/CLI)可用;现有 v3 session 走重建或 migrate 到新版本化模板。

## 四个诉求兑现度(诚实)

| 诉求 | 兑现 |
|---|---|
| 名正言顺 | ✅ substrate 全标准(Definition/routing table/版本化模板/Turn/Surface)。⚠️ 编排器是 hello role×flavor 成员,非 stock cc-orchestrator |
| 多 agent 接力(不止人的消息) | ✅ routing rule 把 agent 消息也投编排器;`from_user?` 守卫改为"接所有需路由入站" |
| 动态团队管理 | 🟡 builder/concierge 声明式;编排器动态 `add_managed_member` 留后续 |
| 版本化 + 迁移 | ✅ 框架 SessionTemplate 版本化 + `migrate_session` |

## 约束与风险

1. **决策在 Elixir,不在 routing table**(刻意;routing table 表达不了 owner/意图)。
2. **成员行为必须挂 flavor `instance_behaviors`**,不能放 `recipe.behaviors`(已证实丢弃)。
3. **拓荒**:全仓库无 cc-orchestrator+Surface 先例;但 B' 不用 cc-orchestrator,走 hello 已验证的 role×flavor + `TurnDriver`,风险显著低。
4. **迁移**:现有 v3 session 重建或 `migrate_session`。
5. **首版不碰核心**;`orchestrator.ex:94`("字面 cc-orchestrator" 升级)留给 Allen。

## 不做(YAGNI)

- 不改 `orchestrator.ex:94`(核心,留 Allen)。
- 不建 native-role AgentTemplate 装配 / 成员 Surface 委托 cap / RoleTemplate Kind(均 deferred core)。
- 首版不做编排器动态 `add_managed_member`(声明式成员够用)。
- 不把路由决策改成 LLM 自然语言编排(保留 Elixir 可确定性)。

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
- Definition.agents 授 caps:`definition_agents.ex:134,303-308`;丢弃 recipe.behaviors:`recipe_materializer.ex:68-74`;custom flavor instance_behaviors:py `application.ex:108`。
- routing 定向:`resolver.ex:435-460`;`route_provisioner.ex:10-17`;`members.ex:83-86`。mention-gate 默认:`default_rules.ex:20,90-91`;`resolver.ex:356-371,388-405`。
