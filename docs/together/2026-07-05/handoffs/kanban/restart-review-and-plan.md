# Handoff：kanban 迁 socialware —— 能不能重启 + 怎么做

> **日期：** 2026-07-05 · **From：** FP5（funder-socialware 侧读码）· **To：** Allen / kanban 线
> **基准代码：** `upstream/main`（含 #1178 socialware manifest track + membership/registry P0，**以及 #1180 role-slot model P1 —— 已落地，不再是前瞻**）
> **注意（2026-07-05 修正）：** 本 handoff 现已搬到新 worktree `sw-kanban`（分支 `feat/sw-kanban`）。下面所有 file:line 直接对本工作树现读有效。
> **role-slot 已落地（#1180）：** `Ezagent.Socialware.Definition` 的参与者声明字段已从旧 `agents` + `members` **收敛成单一 `roles` 字段**（`definition.ex:20` defstruct），`members` 已退休（不在 defstruct）；owner 只能 `%{type: :installer}`（`:fixed` 被拒，`definition.ex:412-425`）。本文档下面的 Definition 写法全部按 `roles` 现读校准。
> **本文只审阅 + 出计划，不改代码。**
> **件① 改名记录（2026-07-06）：** 本审阅文所述的 `pm-coordinator` 协调者 recipe / role / skill **已定案改名为「看板助手（`kanban-assistant`）」**（recipe slug / role_name / skill 目录 / persona 全套；`__done__` 契约点不变）。本文是**换轨记录**——下方所有 `pm-coordinator` / `pm_coordinator_recipe` 保留旧名，用以忠实记录改名前的 main / 备份分支状态与决策过程，**不改写**（改写会篡改历史事实）。现读代码请以新名 `kanban-assistant` 为准。此外本次同批还做了：**件②** 删 GitHub 主动连接器（保留节点 git 定位数据，action 24 → 20）；**件③** 看板助手 skill 加「用 ezagent CLI 驱动板」教学。

---

## 0. 一句话结论

**能重启，而且当初卡住的两道硬门现在都开了。**
- kanban 迁成 socialware Definition 依赖的四样东西（Definition=app 单元 / materialize / member-cap+admission / 版本化 registry）**在 main 上都齐了**。
- 当初的最硬门 **relay-back（dev→pm 接力）现在能用 `Definition.routing_rules` 声明式表达**——**采用内容触发协议**（`{:text_contains, "__done__"}` 头 或 `{:mention, "<legend名>"}` 走 `message.legend_triggers` 符号名）+ `{:role, "pm-coordinator"}` receiver + skill 软协议，materialize 时装进 session-scoped RuleStore/legends。**不再是缺口。**（**注**：核心 matcher 也支持 `{:from, sender}` sender-lock，但**本迁移不用它**——见 §2.2 决策：sender-lock 会把 dev 实例 URI 塞进活规则、快照回 Definition 时撞 #1180、round-trip 炸；内容协议规则零 URI，round-trip 安全。）
- 两个拆解 PR：**split-b 已被 main 吸收（该关）**；**split-c 的决策已是 main 的既成事实（该并档/关）**。

剩下的是**产品化工作量**（写 Definition、给 kanban 插件补 pm-coordinator recipe、补一个 render view），不是机制缺口。

---

## 1. kanban 在 main 上的现状（现读核实）

**形态：kanban-as-role**——看板 = 一个 agent（recipe `kanban-manager` × flavor `native` 的 **passive** agent），board state = 该 agent `Entity.Agent` 的 `:kanban` snapshot slice（真相源）。

证据（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`，upstream/main）：
- `roles/0` **只声明 `kanban-manager` 一个 recipe**（`application.ex:64` `def roles, do: [kanban_manager_recipe()]`）。
- recipe：`behaviors: [Ezagent.ActionSet.Kanban]`、`passive: true`、`requested_caps` = 每动作一个 cap-template map、`config` 里放**9 段产品开发链**（`stages: [:positioning,:metric,:pain,:anchor,:ux,:feature,:issue,:test,:pr]`，`ci_stage: :pr`）当 **layer-2 业务数据**（`application.ex` `kanban_manager_recipe/0`）。
- **无自有 Kind**（K5 删了 `resource://` Kanban Kind，`arch.scan` 的 `resource_kind_as_genserver` gate 永久锁死）；**无 `kinds/0`、无 `definitions/0`、无 Definition**。
- `Ezagent.ActionSet.Kanban` = **24 个 action**（现数 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`，含 9 个连接器动作薄转发给 `Connectors`，全经 `Behavior.Kanban` 解析）。
- GitHub **内联**在插件（`EzagentPluginKanban.Github`），非独立插件；另有 Miro/markmap connector + `MiroSyncSupervisor`（`children/0`）。
- world 入口：`config_surface/0 = %{kind: :route, path: "/plugins/kanban"}`——一个 React 列表页，**不是** socialware view / SessionView。

**结论：kanban 今天是"一个能起活的 passive 数据 agent + 一堆 action + 一个 world 管理页"，不是一个可发布/可安装/可分发的单元。** 迁成 socialware Definition 正是把它变成"pm + kanban 预配好的一支可安装 team"。

### 对照 addressable-completeness 审计（PR#1148 / `docs/addressable-completeness`）——哪些缺口闭合了

审计原文基准 `de4f40a5`，早于 #1172-1178 + registry P0。对 kanban 迁移相关的行，现状：

| 审计标的 | 审计当时（de4f40a5） | 现在（90e8ee29） |
|---|---|---|
| Definition 发布 | ✅ #1164 CR 治理 publish | 仍✅ `config_governance/socialware.ex:81 publish_cr/2` |
| Definition 发现 | ✅ #1164 `DefinitionRegistry.list/1` | 仍✅ `definition_registry.ex` |
| Definition 安装 | ✅ #1164 按 ref 装 | ✅ 且 **#1176 content-hash 安装 + author-pin** 更硬 |
| Definition 版本化/promote | ❌（审计未覆盖，属 W4 远期） | ✅ **#1173 versioned promotable artifact + retract/restore** |
| 匿名受限写 / per-user use-session | ❌ 审计列"外部人写半边是空的"（W4） | ⚠️→部分闭合：**#1172 member-cap grant-at-join** 给"授外部访客受限写"铺了路；**#1178 admission gate** 给"申请进别人 session + owner 审核 + 私密" 兜了底 |
| install 的安全模型（agent 自举触发） | ⚠️ 审计 §3c "刻意非 dispatch、无门控入口" | 仍⚠️（未变，见下 §4 遗留） |
| 声明式打包 socialware | ❌ manifest 拒 `:socialware` seed | 仍❌（`core/manifest.ex` seed_ref 只认 `:recipe`）——**kanban Definition 只能 imperative seed / governance publish，打不进插件包 manifest** |

**净判断：审计当时标"发布/发现/安装/数据分离"对 Definition 这条链已基本闭合，之后的 #1172-1178 又把"访客受限写 + owner 审核加入"从审计的 W4 远期拉进了现成机制。kanban 迁移不再等这些。**

---

## 2. 能否重启 + 怎么做

### 2.1 能重启——依赖项盘点（全在 main）

| 迁移要用的机制 | main 上的落点（file:line） |
|---|---|
| Definition = app 单元（roles/views/routing_rules 声明） | `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:20,22,70-83`；conformance gate `mix ezagent.socialware.check`（`conformance.ex`，12 条有序 assertion） |
| Definition.roles（fill==:agent 槽）→ live SPAWNED 成员 | `session_creator/template_team.ex:48` `agent_role_slot?` 过滤 `fill==:agent` → `DefinitionAgents.materialize_definition_agents`；每 agent 角色槽 `%{role_name, fill: :agent, recipe, flavor}`（`definition.ex:34-36,284-286`，flavor 校验期必填、materialize 侧缺省回填 `"cc"`，**是 per-角色槽 字段、非 Definition 顶层**） |
| per-session role-agent 起活 | `Ezagent.Agent.SessionAgentMaterialize.materialize_by_role/4`（按 name 经 RecipeRegistry 解析，未注册 fail-closed `{:role_not_registered, role}`，`session_agent_materialize.ex:47,160`）—— **就是 split-b 的东西，已在 main 且已再演进（多了 `recipe_materializer.ex`）** |
| 加成员即授 cap | #1172 member-cap grant-at-join |
| 跨 owner 加入→PENDING→owner 审核 | #1178 admission gate（`membership.ex do_join :85-86`，`:approve_admission`/`:deny_admission`/`:withdraw_admission`，`session.ex` cap-exempt in-handler authz） |
| 版本化/可 promote/content-hash 安装 | #1173 + #1176 |
| 发布/发现/安装全链 | #1164（`publish_cr/2` / `DefinitionRegistry.list/1` / `socialware_install.ex`） |

### 2.2 relay-back（dev→pm sender-locked 接力）—— 当初的硬门，现在能用 Definition 表达吗？**能。**

这是全篇最关键的核实。链路逐段带 file:line：

1. **Definition 有 `routing_rules` 字段**：`definition.ex:23,50,103`（`routing_rules: [map()]`，`new/1` 读、json 双向 round-trip `:149`）。
2. **materialize 时真的装进 live 路由**：`template_team.ex:197-231` `install_template_rule_sets/4`——读 `template_routing_rules_of`，逐条 `install_one_rule`（取 `matcher`/`rule_set`/`position`），写 session-scoped RuleStore 后 `Ezagent.Routing.RuleStore.load_into_registry(table)`（`:229`）。失败整体回滚 `{:install_rule_failed, rule, reason}`（`:223`）。→ Definition 声明的路由规则**确实进活 session 的路由表**。
3. **matcher 支持发送方锁定 `{:from, sender}`**：`apps/ezagent_core/lib/ezagent/routing/matcher.ex:51,69`（`{:from, uri}` 构造）+ `:155`（`match?({:from, uri_str}, %Message{sender: sender})` 按 sender 匹配）。→ **"只接 dev 发来的、锁定转给 pm" 这种 sender-locked 规则是一等表达。**
4. **conformance 校验规则合法**：#1180 后 receivers **只能**解析成已声明的 role_name（`{:role, name}` 或裸串 in declared_roles，`conformance.ex:281,284`；**URI receiver 不再放行** → `:socialware_receiver_not_a_role` `conformance.ex:276`）；`prompt_template_ref` 必须指向 Definition 里声明的 template。→ relay-back 的 receiver（pm）只要是 Definition.roles 里声明的 role_name，就过闸。
5. **旧实现的存在证据**：备份分支 `backup/kanban-pre-actionset-0702` 有 `apps/ezagent_core/test/e2e/scenario_34_sender_locked_relay_test.exs`——当初 relay-back 就是**作为 core 路由的 sender-locked relay E2E 证过的**，用的就是 main 上这套同款 matcher。

**结论：relay-back 不再是硬门。**

**口径校正（load-bearing）：pm↔dev 的真正配合 = dev-together skill 的 git-handoff 工作流，不是 ezagent 路由接力。**
- pm 派活 = 写 markdown handoff（`plan.md → handoffs/<task>.md`，含 DoD）；dev 干活 = `dive`（切 task 分支 off `main`、TDD、PR）；dev 交活 = `return`（CI 绿 + rebase gate + DoD 逐行对账 + 写 `returns/<task>.md` + 给 lead 一条 message）；嵌套 = dev 委托 subagent。**这些是 git + markdown + CI，不是 `@mention`/`dispatch`。**
- ezagent 路由（legend/mention → `{:role}`）**只是把"dev 交活了"这条完成信号消息送到 pm 角色的轻传输**，不是工作流引擎。**别把 routing 写成"工作流"。**
- **两层分开（用户核心洞察）**：能力技能（dev-together git-handoff 工作流，跨 socialware 可移植、照抄不改）vs 协作协议（kanban-team 里 pm 怎么跟 dev 配合，pm skill 里独立一薄层）。
- **真缺口（标给 Allen）**：today **无**"per-socialware 常驻协议注入进 agent"的干净入口——agent 常驻 context 只有 socialware-无关的 `recipe.prompt`（`apps/ezagent_core/lib/ezagent/agent/recipe.ex`）；`Definition.prompt_templates` 是每条消息投递时临时套（PR-4 transform，`legend.ex:40`/`resolver.ex:172,251`）、非常驻。所以"薄协议模块"today 只能落在 dev-together/pm 的 skill 文本里、或 Definition 的 routing_rules/legends/prompt_templates 散配置。**理想的"薄协议模块常驻注入"抽象缺、待 Allen**（spec §5.0/§8/§9 Q5）。

**决策（2026-07-05 修订，见配套 spec §4）：relay-back（完成信号传输）用内容触发协议，不用 sender-lock。**
- **写法**：`Definition.routing_rules` 里一条 `matcher: {:text_contains, "__done__"}`（或 `{:mention, "<legend名>"}` 走 `message.legend_triggers`，`matcher.ex:52,142-152`）、`receivers: ["pm-coordinator"]`（role_name → `{:role,name}`，`receiver.ex:11`）的规则，配合 `legends` 字段声明 `@handle`（member_set 用 role_name，`definition.ex:24`；`define_legend` `tools.ex:719`）。"谁在什么时候传给谁"的行为契约写进 pm/dev-together 的 skill（软协议）。
- **为什么不用 sender-lock `{:from, <dev-uri>}`**：sender-lock 要在 install 期把 `{:from, "dev"}`（role_name）解析成 dev 的运行时实例 URI 写进**活 RuleStore**；一旦这支 live session 被快照回 Definition，活规则里的 dev 实例 URI 被投影进 `routing_rules` → `reject_participant_instance_uris`（`definition.ex:82,323-366`）**拒** → **read-back 即炸，static poisoned artifact**。内容协议规则**零实例 URI**，快照回 Definition 不撞 #1180 → **"拉取→二次开发→再发布" round-trip 闭环**。这是相比 sender-lock 的根本收益。
- **副作用（好）**：内容协议与 agent spawn 顺序/实例 URI 完全解耦 → **无 install/materialize 顺序再设计、无 #1180 落点冲突、无需机制代码改动**（旧稿担心的确定性 `planned_agent_uri/3` vs 随机-UUID spawn 失配问题**随方案变更消失**）。
- **不需要 #1178 或 member-cap 才能表达 relay-back**——#1178/member-cap 解决的是"谁能进这支 team、进来授什么 cap"，是另一维度。

> **软协议锁够用**：kanban team 成员都是 owner 从可信 recipe（kanban 插件 `roles/0`）materialize 的自己人，无"冒充 dev 触发 relay"的对抗面；内容协议靠成员遵守 skill 即可。若未来要**硬**锁且仍 round-trip 安全，需一个 membership-role matcher（只存 role_name、零 URI），是 S5 增强、非本切片前置。

### 2.3 kanban Definition 怎么写（骨架）

```
socialware:kanban-team  （OPAQUE subject，非 URI；workspace 独立字段）
  roles:                                                                           # #1180：单一 roles 字段，不再有 agents/members；三个 agent 角色槽
    - %{role_name: "pm-coordinator", fill: :agent, recipe: "pm-coordinator", flavor: "cc-headless"}  # 协调者（真 brain）
    - %{role_name: "dev-together",   fill: :agent, recipe: "dev-together",   flavor: "cc-headless"}  # 开发者（真 brain，skill 照抄现有 dev-together 全套）
    - %{role_name: "kanban-manager", fill: :agent, recipe: "kanban-manager", flavor: "native"}       # passive 看板数据 actor
  legends:                                                                         # 可选 @handle（member_set 用 role_name，零 URI）
    "完成回传" => %{member_set: ["pm-coordinator"], bound_rule_set: "relay-back", fold: false}
  routing_rules:
    - %{matcher: {:text_contains, "__done__"}, receivers: ["pm-coordinator"], rule_set: "relay-back", position: 0}
      # dev-together→pm 内容触发接力；matcher 是内容标记(或 legend 符号名 {:mention,"完成回传"})、零 URI；receiver 用声明 role_name（{:role,name}）
  owner_policy: %{type: :installer}                                                 # #1180：只准 :installer（:fixed 被拒），装谁谁是 owner
  views:
    - <kanban_render View ActionSet>   # 新增：render board 的 SessionView（今天没有，见 §4 步骤）
```

- `kanban-manager` 的 `passive: true` 由 recipe 携带（`application.ex kanban_manager_recipe/0`），Definition.roles 的 agent 槽只需给 `flavor: "native"`。
- **flavor 是 per-角色槽 字段**（agent 槽携带，`definition.ex:284-286`），pm/dev-together 用 `cc-headless`（真 brain，`plugin_cc/application.ex:112`）、kanban-manager 用 `native`——同一 Definition 混合 flavor 没问题。
- **relay-back matcher 零 URI**：内容标记 `{:text_contains, "__done__"}` 或 legend 符号名 `{:mention, "完成回传"}`（走 `message.legend_triggers`）——**不塞任何参与者实例 URI**（round-trip 安全，见 §2.2 决策）。
- **绝不声明 `members` 或参与者实例 URI**：#1180 退休了 `members` 字段，且 `Definition.new/1` 会 fail-loud 拒 `agents`/`members` 键（`reject_retired_declaration_fields`，`definition.ex:313-318`）+ 拒 roles/routing_rules 里任何 `entity://…/agent|user/…` 实例 URI（`reject_participant_instance_uris`，`definition.ex:323-366`）。

### 2.4 两条"写 Definition 时要注意"的约束（现读核实）

**(a) role-slot 是现在的 API（#1179 设计 → #1180 已落地，不再是"等 main"的前瞻兼容）。直接用 `roles` 声明。**

#1180 已把 `Definition` 的 `agents` + `members` 两个字段**收敛成单一 `roles` 字段，并退休 `members`**（`definition.ex:20` defstruct 只有 `roles`，无 `agents`/`members`）；核心安全不变式是**"任何 socialware 声明产物（`%Definition{}` 或它渲成的 `SessionTemplate`）都不许出现参与者实例 URI"**（design doc `docs/superpowers/specs/2026-07-05-socialware-role-slot-model-design.md §5`）。退休 `members` 正是因为它旧时收 `%{uri: ...}` 这种直接实例 URI，是"冒名声明别人 credential agent"的攻击面。

**现在的 role-slot 形态（现读 `definition.ex:34-36,284-296`）**：
- **agent 槽**：`%{role_name: String, fill: :agent, recipe: String, flavor: String}`——role_name/recipe/flavor 三者必填非空（`role_slot/1` `:284-286`），recipe 是 **NAME** 经 RecipeRegistry 解析、**零 URI**。
- **human 槽**：`%{role_name: String, fill: :human}`——运行期分配，不在建 session 时物化。

写 kanban Definition 时直接：
- **用 `roles` 字段声明参与者角色槽，绝不用 `agents`/`members` 键**（`Definition.new/1` 会 fail-loud 拒退休字段，`reject_retired_declaration_fields` `:313-318`）；
- **routing_rules 的 receivers 用 `{:role, name}`（role_name），不用实例 URI**（§2.2；#1180 conformance 已把"receiver 是实例 URI"直接拒 → `:socialware_receiver_not_a_role`）；
- **owner_policy 用 `%{type: :installer}`**（`:fixed` 被拒，`owner_policy/1` `:412-425`）。

→ **role-slot 不阻塞 kanban 开发，kanban 的 Definition 现在就照 `roles` 写，没有"等 #1179 合入再改名"这回事。** kanban-as-role 本身不声明 socialware Definition，完全不受影响；受影响的只有 kanban-team 这个 Definition 的写法。

**(b) pm 挂载不触发 #1178 审核——materializer 是 admin-caller 走 `{:spawned_by}` 豁免。**

Definition.roles（fill==:agent 槽）materialize 出来的 pm/kanban-manager 是 admin-caller（system-mediated）spawn 的自己的 agent，走 `{:spawned_by, caller}` 门（`membership.ex:149-163` 注释明确：`{:spawned_by, caller}` instance-scope 豁免只放行"自己 spawn 的"），**不会落 `:pending_members`、不触发 owner 审核**。#1178 admission gate 只在**"跨 owner 把别人的 agent 拉进来"**（`session.join` 非 spawned_by）时才 PENDING（`membership.ex:85-86,123`）。→ **建 kanban-team 时 pm 一定进得去，审核只用于"别人申请加入这支 team"那一维（§5 Q1 / S5）。**

---

## 3. split-b / split-c 两个 PR 怎么处理

### split-b（`feat/kanban-split-b` @ `1be1ef6f5`，"generic per-session role-agent materialization substrate"）→ **关闭，已被 main 吸收**

- 该 PR 的三件套 deliverable：`SessionAgentMaterialize.materialize_by_role/4` + `DefaultAgentSeed` + `GrantRecipeCaps` mix task。
- **main 上全有且已再演进**：`session_agent_materialize.ex:47,160`（`materialize_by_role/4` + `{:role_not_registered}` fail-closed）、`default_agent_seed.ex:1`、`mix/tasks/ezagent.agent.grant_recipe_caps.ex`，另外 main 还多了 split-b 没有的 `recipe_materializer.ex`。
- `git diff upstream/main origin/feat/kanban-split-b` 方向上是 **34379 行删除 / 4025 行新增**——split-b 远落后于 main，其价值已落地。
- **建议：关掉 split-b PR/分支**（deliverable 已在 main，硬拉会倒退）。迁移时直接**复用 main 的 substrate**。

### split-c（`feat/kanban-split-c` @ `0e0c542e4`，docs-only "recipe ownership decision"）→ **决策已是 main 的既成事实，并档/关**

- split-c 记录的决策：**agent 域（`ezagent_domain_agent`）不 hardcode 任何产品 recipe；`pm-coordinator` recipe 归 kanban 插件（`roles/0`，board-scoped caps 经 GrantRecipeCaps 授）；`dev-together` = 用户配置的通用 agent；不引入 `DefaultRecipes`/`DefaultRecipeSeed`（grep 可证）。**
- **main 现状印证了这个决策**：`git grep DefaultRecipes upstream/main -- apps/` **为空**；备份分支 `backup/kanban-pre-actionset-0702` 里**曾有** `default_recipes.ex` + `default_recipe_seed.ex`（`pm_coordinator_recipe()`）——那条路被明确否掉了，main 从未采纳。
- **建议：split-c 决策仍成立，作为决策记录并入档（或直接关，因为 main 已按它落地）。** 迁移**按它执行**：pm-coordinator recipe 由 kanban 插件 `roles/0` 出。

---

## 4. kanban 后续分步计划（基于 main 现有 socialware 机制）

> 前提事实（现读）：main 上 kanban 插件 `roles/0` **只有 kanban-manager**（`application.ex:64`）；**pm-coordinator recipe 没被任何 `roles/0` 注册**（`git grep pm_coordinator_recipe upstream/main` 只在备份分支命中；main 只在 `default_agent_seed.ex:52` 作为 role_name 字符串引用，没有对应已注册 recipe）。→ 直接 `materialize_by_role("pm-coordinator")` 会 fail-closed。这是迁移的第一块实活。

**今天能独立做（无需协调）：**

1. **S1 — kanban 插件补 `pm-coordinator` + `dev-together` 两个 recipe（按 split-c 决策）。** 在 `EzagentPluginKanban.Application.roles/0` 加 `pm_coordinator_recipe()`（cc-headless、persona skill **用 skill-creator 规范新建**、board-scoped caps）+ `dev_together_recipe()`（cc-headless、skill = **照抄** sw-kanban 现有 `.claude/skills/dev-together/` 全套，SKILL.md 204 行 + commands/references/scripts/hooks 逐个保留、不重写）。或先确认能否复用 cc 插件的 `OrchestratorRecipe` 当 pm——**先拍"pm = 新 recipe 还是复用 orchestrator"再动手**（§5 Q1）。
2. **S2 — 写 `socialware:kanban-team` Definition**（§2.3 骨架），**发布 = 仿 hello code-seed**（照 hello：`EzagentPluginHello.App.ensure_app` `app.ex:40` + `DefinitionRegistry.seed_definition_if_absent` `app.ex:238`，插件 boot hook 里 imperative seed），**不走插件包 manifest**——因为 `core/manifest.ex` 的 seed_ref 仍只认 `:recipe`、`:socialware` seed 在 parse 期被 REJECT（`manifest.ex:54-56,174-186,354-363`）。跑 `mix ezagent.socialware.check` 过 12 条 conformance。**未来** kanban Definition 可迁到 registry P3（外部 config 源 + deploy-seed/promote，见 `docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md §5`）分发，但那是"更好的分发"、非最小闭环前置。
3. **S3 — relay-back 规则写进 Definition.routing_rules + legends**（§2.2，内容触发协议），用 conformance gate + 两个集成测试证：(a) materialize 后规则真进 session 路由表且**内容触发**生效（带 `__done__`/legend 的消息命中 pm、普通消息不命中）；(b) **round-trip gate**——materialize 后快照回 Definition，`Definition.new/1` 不报 `:socialware_definition_declares_instance_uri`（证规则零 URI、round-trip 安全）。**不移植 sender-lock 的 `scenario_34` 思路**（那用 concrete member URI，与本决策相悖）。
4. **S4 — kanban render view**：今天 kanban 只有 world React 管理页（`/plugins/kanban`），**没有 socialware SessionView**。若 Definition 要带 `views`，得新增一个 `<sw>_render` view ActionSet（board 只读投影）。若首版不要公开页可先 `views: []`，把 board 可视化留给 world 管理页——**先拍首版要不要公开 view**（§5 Q2）。

**需要协调 / 先拍板：**

5. **S5 — kanban team 的 join / admission 语义**：借 #1178 admission gate——别人申请进一支 kanban-team session → PENDING → owner（pm 的 owner）审核。这块是"撮合/邀人进看板"的产品语义，**要不要用、用哪档（匿名读 / 登录非成员读 / 成员读写）要 Allen 拍**。
6. **S6 — 分发形态**：kanban 走 #1169 的 code-vs-config split——**首个 flagship = 插件（代码：recipes + ActionSet.Kanban + connectors + view，留 code repo）+ 一个 Definition（config，可住 registry 版本化/promote，#1173/#1176）**。后续若要"纯重组已有 flavor/view/behavior 的第二支看板变体"就可纯 config。这条要不要现在就按 registry 分发铺，还是先 imperative seed 验证闭环，**协调**。

**已知遗留（非 kanban 独有，别当 kanban 的锅）：**
- socialware **打不进插件包 manifest**（`core/manifest.ex` seed_ref 只认 `:recipe`，无 `definitions/0` callback）——kanban Definition 只能 imperative seed（仿 hello code-seed）/ governance publish；**未来 registry P3 外部 config 源接管声明式分发**（非最小闭环前置）。
- **install 刻意非 dispatch**（agent 无合法自触发路径）——自举回路的 install 入口门控仍是 open question（审计 §3c / §5 Q3）。
- world 无独立 `/socialware` 路由，socialware 渲在 sessions_table 的 "socialwares" rows。

---

## 5. 给 Allen 的 discuss-first

1. **pm = 新 recipe 还是复用 cc 的 orchestrator？** split-c 定的是"pm-coordinator 归 kanban 插件 `roles/0`"，但 main 上 cc 已有 `OrchestratorRecipe`。要么 kanban 出独立 pm-coordinator recipe（贴 split-c），要么 Definition 直接用 orchestrator 当协调者。影响 S1。
2. **kanban Definition 首版要不要公开 view？** 不要就 `views: []`、board 看 world 管理页；要就得新增 `<sw>_render` SessionView（S4 工作量）。
3. **install / 自举门控**（审计遗留 §3c）：agent 自触发 install 的安全模型未定，暂不阻塞 kanban 迁移（迁移用 imperative seed），但影响"看板能不能被 agent 自举装回"。
4. **分发时机**（S6）：先 imperative seed 验证 pm+kanban+relay-back 闭环，还是一步到位走 #1173/#1176 registry 版本化分发。

---

## 附：本 handoff 的路径

`docs/together/2026-07-05/handoffs/kanban-restart-review-and-plan.md`（写在 `feat/kanban-agent-e2e` 分支 worktree）
