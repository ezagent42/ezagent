# kanban 迁 socialware Definition — Dev Spec

> **实施对齐说明（2026-07-06 收口）**：本文档是开工时的 point-in-time 规划。实施与之的偏差以代码与 PR body 为准：①角色槽收敛为 2（kanban-assistant + dev-together），board=workspace 级 URI-dispatch actor 不进 roles（RF-6）；②pm-coordinator 更名 kanban-assistant；③gh 连接器整体退役（联通=agent 用 gh/git CLI 的行为，协议在 kanban-assistant skill 的 gh-protocol 模块）；④新增 boot-publish（Demo 照 #162 黄金样板）与 BoardView/KanbanRender view 声明侧。

> **日期：** 2026-07-05 · **分支：** `feat/sw-kanban` · **基准代码：** `upstream/main`（本 worktree `feat/sw-kanban` 代码字节一致）
> **worktree：** `/home/yaosh/projects/ezagent-biz/.claude/worktrees/sw-kanban`
> **产品源：** `docs/together/2026-07-05/handoffs/kanban-restart-review-and-plan.md`（S1-S6 + role-slot #1180 已落地）
> **配套 plan：** `docs/superpowers/plans/2026-07-05-kanban-socialware-plan.md`
> **本文只出规格，不改代码。** 所有 file:line 对本 worktree 现读有效。
> **role-slot 已落地（#1180）：** Definition 参与者声明用**单一 `roles` 字段**（`definition.ex:20`），`agents`/`members` 已退休；owner 只准 `%{type: :installer}`（`:fixed` 被拒，`definition.ex:412-425`）。本 spec 全部按 `roles` 现读校准。
> **relay-back 已改为内容协议（本次修订）：** dev→pm 接力**不再用 sender-lock `{:from, URI}` + install-time URI 解析**，改成**内容触发（legend/header）+ skill 协议**——路由规则里**零参与者实例 URI**，因此快照回 Definition 不撞 #1180 `reject_participant_instance_uris`（`definition.ex:82,323`），**"拉取→二次开发→再发布" round-trip 闭环**。详见 §4。
>
> **S2 建模修正（board 非成员，2026-07-06）：** 早先草稿把 kanban 看板（recipe `kanban-manager` × flavor `native`）当作**第三个 agent 角色槽**塞进 `roles`——**这是建模 bug**。根因（现读核实）：看板是 `passive: true` 的**被动 workspace 级数据 actor**（`application.ex` `kanban_manager_recipe/0`），按 `entity://<ws>/agent/<id>` URI dispatch，**从来不是 session 参与者**。把它声明成角色槽 → materialize 会对它 `session.join` → 撞 RF-6 被动 join 硬门 `{:passive_actor_cannot_join, _}`（`session.ex:723`，`role_native_create_test.exs:119` 锁死）。**修正（自包含解法 a）：`roles` 只留 `kanban-assistant` + `dev-together` 两个 agent 角色槽（都 cc-headless 主动、过 join 门）；看板不进 `roles`，改由 world/owner 经既有 `/plugins/kanban` 建（`Ezagent.World.KanbanActions.create_kanban` → `Workspace.create_agent`，`kanban_actions.ex:296`），pm 用既有 kanban action caps 把 `kanban.<action>` dispatch 到 board URI。** 全文凡「三角色槽 / 三个 agent 角色槽」按本修正读作「两 agent 角色槽（pm+dev）+ board 是 workspace 级 URI-dispatch actor 非成员」。
>
> **件①②③ 修订（2026-07-06，三件自包含重构）：**
> - **件① `pm-coordinator` → 看板助手（`kanban-assistant`）全套改名**（旧名 → 新名）：recipe slug / role_name / skill 目录 / persona 全部由 `pm-coordinator` 改为 `kanban-assistant`（现为 `application.ex kanban_assistant_recipe/0`、`.claude/skills/kanban-assistant/`、Definition `roles` 槽 + relay receiver `{:role, "kanban-assistant"}`）。`__done__` 契约点不变。**本文下方设计段的旧名 `pm-coordinator` / `pm_coordinator_recipe` / `pm_persona` 均已按新名校准；仅历史/决策段保留旧名作换轨记录。**
> - **件② 拿掉 GitHub 主动连接器**：删 `sync_github` / `push_pr` / `sync_prs` / `save_github_creds` 四动作 + `EzagentPluginKanban.Github` REST 客户端；**保留**节点 git 定位数据（`register_pr` / `attach_code_file` / `artifacts` / `set_board_config` 的 `github_repo`——纯数据、不发 HTTP）。kanban action 数 **24 → 20**。
> - **件③ 看板助手 skill 加「用 ezagent CLI 驱动板」教学**：`references/kanban-team-collaboration.md` §(d)——动作面 = 现成 ezagent CLI（`EzagentCli.Exec` / `Dispatch.run_action` → `Router.dispatch`），把 `kanban.<action>` dispatch 到 board 的 `entity://<ws>/agent/<uuid>` URI；board URI 经 `Ezagent.AgentRecipeResolver.list_by_recipe("kanban-manager", ws)` 定位。**skill 层教学，禁改 esr-bridge / core / domain agent 基建。**

---

## §0 一句话

把 kanban 从「一个 passive 数据 agent（recipe `kanban-manager` × flavor `native`）+ 20 个 action + 一个 world 管理页」迁成**一支可安装的 socialware team**：`socialware:kanban-team` Definition，在 `roles` 字段（#1180）声明**两个 agent 角色槽**——`kanban-assistant`（cc-headless 真 brain 协调者）+ `dev-together`（cc-headless 开发者，照抄现有 dev-together skill）。**看板（`kanban-manager` × `native`）不进 `roles`**：它是 workspace 级被动 URI-dispatch 数据 actor，不是 session 成员（见顶部 S2 建模修正），由 world/owner 建、pm 用 kanban action caps dispatch 驱动。发布走「仿 hello 的 code-seed」（imperative，非插件包 manifest）。

> **口径校正（load-bearing —— 别把 routing 当工作流引擎）：pm 与 dev 的真正配合，是 dev-together skill 的 git-handoff 工作流（git + markdown + CI），不是 ezagent 的消息路由接力。** pm 派活 = 写 markdown handoff（`plan.md → handoffs/<task>.md`，含 DoD）；dev 干活 = `dive`（切 task 分支 off `main`、TDD、PR 进 task 分支）；dev 交活 = `return`（CI 绿 + rebase gate + DoD 逐行对账 + 写 `returns/<task>.md` + 给 lead 一条 message）；嵌套 = dev 委托 subagent。**这些是 git + markdown + CI 的工作流，不是 `@mention`/`dispatch`。** ezagent 的路由（legend/mention → `{:role}`）**只是把「dev 交活了」这条消息送到 pm 角色的轻传输**——不是工作流本身。所以本 spec 的 `routing_rules`（§4）只承担**传输**（把完成信号投给对的角色），**工作流的实体（handoff/dive/return/CI gate）住在 dev-together skill 里**（§5.4）。

---

## §0.1 routing 承担什么 vs 协议承担什么（职责对照，唯一契约点）

**这是本 spec 的地基。** kanban-team 的协作分成两块干净分离的东西——**routing 只搬消息，协议才是约定**。别把任何一块塞进另一块。

| 维度 | **routing（消息传输层）** | **协作协议（协作约定层）** |
|---|---|---|
| **唯一职责** | 把一条消息送到对的角色。**只此一件事。** | 谁、在什么条件下、发什么标记、handoff/return/DoD 纪律——**协作的全部语义。** |
| **住在哪** | `Definition.routing_rules` + `legends`（config-as-data，随 Definition 走） | skill 的**协议模块**（pm 的 `references/kanban-team-collaboration.md` + dev-together 的薄 overlay，§5.3） |
| **具体是什么** | matcher（`{:text_contains,"__done__"}` / `{:mention,"完成回传"}` 走 `legend_triggers` **符号名**，`matcher.ex:142-152,170`）+ receiver `{:role,name}`（`receiver.ex:11,14-15`） | 「dev `return` 完了才发完成标记」「标记里带卡号+目标阶段」「pm 收到先审 `returns/<task>.md`+CI 再推卡」「9-棒阶段纪律」 |
| **懂不懂工作流** | **不懂**——不知道什么时候该发、发什么内容、谁负责发、分支/CI/DoD 是什么。命中标记就投递，仅此。 | **懂**——它*就是*工作流约定；但它也不碰传输机制（不知道 matcher/receiver 怎么实现）。 |
| **改一处会怎样** | 改 matcher `arg` = 改「哪个标记触发投递」 | 改协议 = 改「dev 该发什么标记 / pm 该怎么响应」 |

**唯一契约点（协议 ↔ 传输之间只有这一根线）**：协议模块里约定的**完成标记字面**（`__done__` header / `@完成回传` legend 名）**必须与 `Definition.routing_rules` 的 matcher `arg` 逐字一致**（§4.2 + §5.5）。两端对齐，闭环成立；对不齐，dev 发的标记路由不认、消息投不到 pm。**除这根线外，routing 与协议互不知对方内部。**

> **反面自查**：如果你发现自己在 `routing_rules` 里表达「dev 交活后才转」的*时序条件*、或在 matcher 里编码「谁是合法发送方」的*身份规则*——**停**，那是协议的活，不是传输的活。routing 里出现「时序/条件/身份判断」= 把传输写成了工作流引擎（本 spec 明令禁止，§4.0）。sender-lock（`{:from, <dev-uri>}`）正是这种越界——把「只有 dev 发才转」的协议身份判断硬塞进传输层，代价见 §4.4。

---

## §1 目标 / 非目标

### 目标

1. kanban 插件 `roles/0` 从只有 `kanban-manager`（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:64`）扩到**三个** recipe：加 `kanban-assistant`（cc-headless 协调者，skill-creator 规范新建 persona skill）+ `dev-together`（cc-headless，skill = **照抄** sw-kanban 现有 `.claude/skills/dev-together/` 全套）。
2. 出 `socialware:kanban-team` Definition（`Ezagent.Socialware.Definition`，`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:12-28` 的 17-字段结构），声明 `roles`（**两个** agent 角色槽 pm+dev，**零实例 URI**；board 非成员，见 §3.2）+ `routing_rules` + `legends`（relay-back，内容触发）。
3. **relay-back（dev-together→pm 接力）落成内容协议**：`Definition.routing_rules` 里一条**内容触发** matcher（`{:text_contains, "__done__"}` 头 或 `{:mention, "<legend名>"}` 走 `message.legend_triggers` 符号名）→ receiver `{:role, "kanban-assistant"}`（角色，非 URI），配合 `legends` 字段声明 `@handle`；「谁在什么时候传给谁」的行为契约**写进 pm/dev-together 的 skill**。规则里**无任何参与者实例 URI** → 快照回 Definition 不撞 #1180，**round-trip 闭环**（§4）。
4. 发布 = code-seed（仿 hello `DefinitionRegistry.seed_definition_if_absent`，`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:238`），过 `mix ezagent.socialware.check` 的 12 条 conformance（`apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex:63-78`）。
5. kanban 用户面（owner 对 pm 派活 → pm @dev-together 派活 + 推进看板 → dev-together 完成发 `__done__`/legend → relay-back 回 pm → 看板前进）用**真浏览器 Playwright e2e** 证（dev server 10042，真登录，每步截图）。

### 非目标（本切片不做，见 §9 discuss-first / §8 待 main）

- **不**把 kanban Definition 打进可分发插件包 manifest（`core/manifest.ex:174-186` seed_ref 只认 `:recipe`，是 Allen 有意绕过、非缺口；走 code-seed）。
- **不**做 registry P1/P2/P3 分发（catalog UI / 统一安装 / 外部 config 源）——那是「更好的分发」，叠加非前置。
- **不**做「跨 owner 动态申请加入 kanban-team + owner 审核」的 world 审批 UI（#1178 admission 机制现成，但驱动 UI 是增强，§9 Q3）。
- **不**改 `ARCHITECTURE.md`（Allen 维护）。

---

## §2 迁移映射（旧 → 新）

| 维度 | 迁移前（main 现状，现读核实） | 迁移后（socialware:kanban-team） |
|---|---|---|
| **形态** | kanban-as-role：单 passive agent | 可安装 socialware Definition（team = pm + dev-together 两成员预配；看板是 workspace 级 actor，非成员） |
| **agent 声明** | `roles/0 = [kanban_manager_recipe()]`（`application.ex:64`），只有 kanban-manager | `roles/0 = [kanban_manager_recipe(), kanban_assistant_recipe(), dev_together_recipe()]`（三 recipe 不变）；但 **Definition.roles 只声明两个** agent 角色槽（pm+dev）——`kanban-manager` recipe 供 world 建 board 用，不进 Definition 成员 |
| **kanban-assistant** | 未注册（materialize 时 `DefinitionAgents.lookup_recipe` fail-closed `{:unknown_agent_recipe, "kanban-assistant"}`，`definition_agents.ex:130-135`；注：#1185 role-slot P2 已删死代码 `SessionAgentMaterialize`/`materialize_by_role`，live materialize 走 `DefinitionAgents`）；`default_agent_seed.ex:52` 只作 role_name 字符串引用 | kanban 插件 `roles/0` 注册的 cc-headless recipe（skills=`["kanban-assistant"]` + persona，**skill-creator 规范新建**） |
| **dev-together** | main 上是一个 **skill**（`.claude/skills/dev-together/`，8-command 团队开发流），无对应 recipe | kanban 插件 `roles/0` 注册的 cc-headless recipe（skills=`["dev-together"]`，**skill 照抄现有全套**，§5.4） |
| **board 真相源** | `Entity.Agent` 的 `:kanban` snapshot slice（不变） | 不变——但 kanban-manager 是 **workspace 级被动 URI-dispatch actor，不是 session 成员**；Definition **不**声明它。board 由 world/owner 建（`/plugins/kanban` → `Workspace.create_agent`），pm 用 kanban action caps dispatch 到 board URI |
| **relay-back（dev-together→pm）** | 无（备份分支 `scenario_34_sender_locked_relay_test` 曾用 sender-lock + concrete member URI 证过 —— **本次不采用该路** ） | `Definition.routing_rules` 内容触发（`text_contains`/`mention` legend）+ `{:role}` receiver + skill 软协议，**零实例 URI**，round-trip 安全（§4） |
| **发布/安装** | 无（kanban 不是可发布单元） | code-seed（`seed_definition_if_absent` → `workspace://system`）+ per-install（`Installation.install_template_installs/4`，`installation.ex:185`） |
| **conformance** | 无 | `mix ezagent.socialware.check kanban-team` 过 12 条（task `@reference_apps` 已含 `:ezagent_plugin_kanban`，`ezagent.socialware.check.ex:29-33`） |
| **用户面** | world React 列表页 `/plugins/kanban`（`config_surface/0`，`application.ex:133`） | socialware session（owner ↔ pm 聊天派活）+ 看板推进；board 可视化首版复用 `/plugins/kanban`（S4 render view 为增强，见 §9 Q2） |
| **20 个 action** | `Ezagent.ActionSet.Kanban.actions()`（现数 24，`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`），全经 `Behavior.Kanban` 解析 | 不变——迁移不碰 action 层；pm/dev-together 经 requested_caps 拿这些 action 的 cap 驱动看板 |

---

## §3 Definition 声明（`socialware:kanban-team`）

### 3.1 字段（17-字段结构，`definition.ex:12-28`）

Definition 顶层**无 flavor 字段**；flavor 在每个 `roles` 里的 agent 角色槽携带（`role_slot/1`，`definition.ex:278-303`，校验期必填非空、materialize 侧缺省回填 `"cc"`）。本 team 声明：

| 字段 | 值 | 说明 |
|---|---|---|
| `name` | `"kanban-team"` | OPAQUE subject `socialware:kanban-team`（非 URI，`definition.ex:5-8`） |
| `title` | `"Kanban Team"` | 展示名 |
| `description` | `"pm 协调 + dev-together 开发 + 看板数据，内容触发 relay-back"` | — |
| `uses` | `["kanban"]` | 依赖 kanban 插件（conformance 断言 0 检查已安装，`conformance.ex:82-96`）——**不是组合轴** |
| `bases` | `[Ezagent.ActionSet.Session]` | Session host 行为 |
| `shape` | `[]` | 首版无额外 flow shape |
| `views` | `[]`（首版）| S4 加 `<kanban_render>` view（§9 Q2） |
| `roles` | 见 §3.2 | **两个** agent 角色槽 pm+dev（`fill: :agent`），**零实例 URI**（#1180 硬 enforce）；board 非成员 |
| `routing_rules` | 见 §4 | relay-back（内容触发，零 URI） |
| `legends` | 见 §4 | relay-back 的 `@handle`（member_set 用 role_name，`definition.ex:24,98`） |
| `visibility_policy` | `%{publish_policy: :auto, web_anon_access: false, scope: :private}` | 私有、非公网面 |
| `owner_policy` | `%{type: :installer}` | owner = 安装者派生（`owner_uri/2`，`definition.ex:176`）；#1180 只准 `:installer`，`:fixed` 被拒（`owner_policy/1`，`definition.ex:412-425`） |
| `prompt_templates` / `adapters` / `assets` / `orchestrator_template_uri` | 空 | 首版不用 |
| ~~`members`~~ | **已退休** | #1180 收敛进 `roles`；`Definition.new/1` fail-loud 拒 `agents`/`members` 键（`reject_retired_declaration_fields`，`definition.ex:313-318`），塞实例 URI 是攻击面（§8） |

### 3.2 roles（两个 agent 角色槽 pm+dev；board 非成员）

```elixir
roles: [
  %{role_name: "kanban-assistant", fill: :agent, recipe: "kanban-assistant", flavor: "cc-headless"},
  %{role_name: "dev-together",   fill: :agent, recipe: "dev-together",   flavor: "cc-headless"}
]
```

- agent 角色槽四字段 `role_name`/`fill`/`recipe`/`flavor` 全是**字符串**（`fill: :agent`），`role_name`/`recipe`/`flavor` 三者必填非空（`role_slot/1`，`definition.ex:284-286`）；`recipe` 是 NAME 经 `RecipeRegistry` 解析，**零 URI**。
- **`kanban-assistant` / `dev-together` 用 `cc-headless`**（cc 插件注册的真-brain headless flavor，`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:112`；`cc_headless_bridge_adapter.ex:16` `def flavor, do: "cc-headless"`）——两者都是真 Claude brain 的**主动** agent，过 RF-6 join 门。
- **看板（`kanban-manager` × `native`）不在 `roles`**（S2 建模修正，见顶部）：它 `passive: true`（`application.ex` `kanban_manager_recipe/0`），是 workspace 级被动数据 actor，**不是 session 成员**——塞进角色槽会让 materialize 对它 `session.join` 撞 RF-6 被动 join 门 `{:passive_actor_cannot_join, _}`（`session.ex:723`）。
  - **供给**：board 由 world/owner 经既有 `/plugins/kanban` 建（`Ezagent.World.KanbanActions.create_kanban` → `Ezagent.Workspace.create_agent`，flavor `native` × role `kanban-manager`，`kanban_actions.ex:296`）。建 board 是 operator/world-UI 动作（需 workspace cap + caller_ctx），**不是 agent 可 dispatch 的 action**，故 pm 不自建。
  - **访问**：pm 用既有 `kanban_action_caps`（`kanban_assistant_recipe/0` `requested_caps`）把 `kanban.<action>` dispatch 到 board 的 `entity://<ws>/agent/<id>` URI，无新增 cap。
- 若要人类参与者，用 human 槽 `%{role_name: n, fill: :human}`（运行期分配，不物化）——kanban-team 首版无 human 槽（owner 由 `owner_policy: :installer` 派生，不进 roles）。
- **零实例 URI 由 #1180 硬 enforce**：`Definition.new/1` 递归扫 `roles` + `routing_rules` 拒任何 `entity://…/agent|user/…` 实例 URI（`reject_participant_instance_uris`，`definition.ex:323-366`）。
- **materialize 不触发 #1178 审核**：这两个 agent（pm+dev）由 materializer admin-caller 走 `{:spawned_by, caller}` 豁免 spawn（`membership.ex:149-163`），不落 `:pending_members`——建 team 时一定进得去（handoff §2.4b）。

### 3.3 materialize 链路（现读，不改）

`TemplateTeam.materialize_template_team/4`（`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex:9`）依次：
1. `install_template_prompt_templates`（:20）
2. `install_template_legends`（:21 → :216）——装 `legends` 进活 session（`Session.system_set_legends`，`template_team.ex:222`）；**relay-back 的 `@handle` 在此落地，零 URI**
3. `install_template_rule_sets`（:23 → :229）——装 routing_rules 进活路由；**relay-back 的内容触发 matcher（`text_contains`/`mention`）+ `{:role}` receiver 在此落地，零 URI**
4. `DefinitionAgents.materialize_definition_agents`（`template_team.ex:33`，先经 `agent_role_slot?` 过滤只留 `fill==:agent` 的槽，`template_team.ex:48-50`；human 槽不物化）——把**两个** agent 角色槽（pm+dev，都主动、过 join 门）spawn 成 live 成员，**每个在新的随机 UUID 实例 URI** spawn（`planned_agent_uri/1`，`definition_agents.ex:108,285`），`grant_recipe_caps` LAST（`definition_agents.ex:246`）。**board 不在这步**（非成员，由 world 单独建）

> **关键**：#3（rule/legend install）**不再**依赖 #4（agent spawn）产出的 URI —— 内容触发 matcher + `{:role}` receiver 只用 role_name 与内容，与 spawn 顺序/实例 URI **完全解耦**。旧 sender-lock 方案要求「rule 解析成 dev 的运行时 URI」，被 #1180 随机-UUID spawn 打乱了 install/materialize 顺序（旧 §4.3 冲突）——本方案**从根上消除该顺序耦合**。

---

## §4 relay-back（dev-together→pm 的**完成信号传输**，内容协议）

### 4.0 先说清楚：这一节只是「传输」，不是工作流

**真正的配合是 §5.4 的 dev-together git-handoff 工作流**（pm 写 handoff → dev `dive` 建 task 分支/TDD/PR → dev `return` 过 CI+rebase gate + DoD 对账 + 写 `returns/<task>.md`）。本节的 `routing_rules` **只做一件事：当 dev 交完活、发一条带完成标记的消息时，把这条消息投到 `kanban-assistant` 角色**——让 pm 知道"该看 return / 推看板了"。**不要把 routing 读成"工作流引擎"**：它不管分支、不管 CI、不管 DoD，那些全在 dev-together skill 的 git+markdown+CI 里。routing 在这里等价于「dev 交活后 @ 一下 lead」的那声轻传输。

### 4.1 目标语义

「dev-together 成员在 git-handoff 工作流里交完一件活（`return` 完成）后，发一条完成信号消息，路由把它送到 kanban-assistant 角色，让 pm 去审 return 并推进看板」。**不用 sender 锁定**（不看发送方 URI），改用**内容触发 + role 受端 + skill 软协议**表达：dev-together 按 skill 约定在完成消息里带一个**内容标记**（`__done__` 头 或 `@<legend名>`），路由规则命中该标记 → 投给 `kanban-assistant` 角色。

### 4.2 声明形态（`Definition.routing_rules` + `legends`）

**首选（最小闭环）—— header 内容触发，无需 legend registry：**

```elixir
routing_rules: [
  %{
    "matcher"   => %{"type" => "text_contains", "arg" => "__done__"},  # 内容标记，非 URI（matcher.ex:52,170）
    "receivers" => ["kanban-assistant"],                                  # role_name → {:role,name}（receiver.ex:11）
    "rule_set"  => "relay-back",
    "position"  => 0
  }
]
```

**可选增强（richer @handle）—— legend 符号名触发：**

```elixir
legends: %{
  "完成回传" => %{member_set: ["kanban-assistant"], bound_rule_set: "relay-back", fold: false}  # member_set 用 role_name（definition.ex:24; legend.ex:20-45）
},
routing_rules: [
  %{
    "matcher"   => %{"type" => "mention", "arg" => "完成回传"},  # legend 符号名，走 message.legend_triggers（matcher.ex:142-152），非 URI
    "receivers" => ["kanban-assistant"],
    "rule_set"  => "relay-back",
    "position"  => 0
  }
]
```

- **matcher 零 URI**：
  - `{:text_contains, "__done__"}` 对 `message.body` 做子串匹配（`matcher.ex:170`；类型 `matcher.ex:52`）——纯内容。
  - `{:mention, "完成回传"}` 命中当 `"完成回传"` ∈ `message.legend_triggers`（**符号名，非 URI mention**，`matcher.ex:142-152`；parser 把 legend NAME 注进虚拟 `:legend_triggers` 而非 `:mentions`，`legend.ex:29-45`）。
- **receiver `{:role, "kanban-assistant"}` 零 URI**：`"kanban-assistant"` 是声明的 role_name → `{:role, name}`（`receiver.ex:11,14-15`），Resolver 投递时按 session 成员的 role facet 展开成 pm 的 per-session URI。
- **legend 机制**：`legends` 字段把一个 `@handle`（如 `"完成回传"`）绑到一组 role_name（`member_set`）+ 一个 `bound_rule_set`（`define_legend(legend_name, member_role_names, bound_rule_set, fold)`，`tools.ex:719,736`；纯 map 语义 `legend.ex:20-45`）。materialize 时 `install_template_legends`（`template_team.ex:216-227`）装进活 session，**member_set 用 role_name、零 URI**。
- **conformance**：断言 8（`routing_receivers_resolve`）#1180 后只校验 receiver 解析成已声明 role_name（`receiver_resolvable?`：`{:role, name}` 或裸串 in declared，`conformance.ex:281,284`；**URI receiver 已被拒** → `:socialware_receiver_not_a_role`，`conformance.ex:276`）→ `"kanban-assistant"` 在 declared roles 里，过闸。matcher 侧 conformance 不校验内容标记（`text_contains`/`mention` 是合法 matcher 类型，`matcher.ex:234-241`）。

### 4.3 「谁在什么时候传给谁」写进 skill（软协议）

**路由规则只提供机制**（命中 `__done__`/legend → 投 pm 角色）；**行为契约（何时发、发什么）写进两个 role 的 skill**：

- **kanban-assistant skill**：`@dev-together` 派活时明确要求「完成后发 `__done__` 头（或 `@完成回传`）+ 一句话说清哪张卡到哪个阶段」；收到 relay-back 后推进对应卡、回 owner。
- **dev-together skill**（照抄现有 + 一段 kanban-team 协议附注，§5.4）：完成一件活后，按约定在回传消息里带 `__done__` 头 / `@完成回传` + 卡号 + 目标阶段。

> **软协议锁 vs sender 硬锁**：sender-lock（`{:from, <dev-uri>}`）在路由层强制「只有 dev 发的才转」；内容协议靠 dev-together 遵守 skill 约定发标记。**对 kanban 团队够用**——team 成员都是 owner 从**可信 recipe**（kanban 插件 `roles/0`）materialize 出来的自己人，不是不可信外部输入，没有「冒充 dev 触发 relay」的对抗面。换来的是**零 URI → round-trip 闭环**（§4.4），这是硬收益。

### 4.4 关键收益：round-trip 闭环（相比 sender-lock 的根本优势）

- **本方案规则里无参与者实例 URI**：matcher 是内容标记（`text_contains`）或 legend 符号名（`mention` on `legend_triggers`）；receiver 是 role_name（`{:role}`）；legend member_set 是 role_name。**全程零 `entity://…/agent|user/…`。**
- **→ 快照回 Definition 不撞 #1180**：当 orchestrator 把一支 live session 快照回一个 Definition（`DefinitionSync` / `save_template_as`），`Definition.new/1` 会递归扫 `roles` + `routing_rules` 里所有字符串、拒任何参与者实例 URI（`reject_participant_instance_uris`，`definition.ex:82,323-366`）。本方案的规则字符串里没有 URI，**扫描通过** → **「拉取已发布 socialware → 二次开发（加成员/改规则）→ 再发布」round-trip 闭环**。
- **对比 sender-lock 为什么会炸**：sender-lock 要把 `{:from, "dev"}`（role_name）在 install 期解析成 `{:from, <entity://…/agent/dev-xxx>}`（dev 的运行时实例 URI）写进**活 RuleStore**。一旦这支 live session 被快照回 Definition，活规则里的那个 dev 实例 URI 被投影进 `routing_rules` → `reject_participant_instance_uris` **拒**（`definition.ex:323-366`）→ **读回即炸，static poisoned artifact**（发布出去的 Definition 再也 load 不回来，且失败点在别人二次开发时才暴露）。**这正是本次放弃 sender-lock 的根因。**
- **附带**：本方案还消除了旧 §4.3 的 #1180 落点冲突（sender-lock 要求 rule 解析成 spawn 后的真实 member URI + 调 install/materialize 顺序）——内容协议与 spawn 顺序/实例 URI 完全解耦，**无顺序再设计、无需 Allen re-verify 解析源**。

### 4.5 精确边界（诚实 flag）

- 内容协议对「**任意**遵守 skill 协议、发 `__done__`/legend 的成员」都命中（不限声明的 dev-together 槽）——所以**动态加入的外部 dev**只要走 dev-together skill 也能 relay，比 sender-lock 的「只锁声明成员」**更泛化**，且不引入新机制。
- 代价：内容协议**不是**路由层强制锁（靠成员遵守 skill）。若未来需要「只有特定角色发才转」的**硬**锁且仍要 round-trip 安全，需一个 **membership-role matcher**（按成员 `role_name` facet 匹配发送方、只存 role_name、零 URI）——是真缺口，列 §9 discuss-first / S5，**本切片不做、也不需要**。

---

## §5 kanban-assistant recipe（skill-creator 新建）+ dev-together recipe（照抄现有）

### 5.0 设计原则：能力技能（可移植）vs 协作协议（薄模块）两层分开

这是本迁移的一条核心设计原则（用户洞察），落到两个 role 的 skill 上：

- **能力技能 = 可移植**：`dev-together` skill 是**通用开发能力**（`dive`/`plan`/`review`/`push`/`return`/`handoff` 的 git-handoff 工作流），**跨 socialware 复用**——它不知道自己在 kanban-team 里，照抄进任何 team 都能用。**所以 dev-together = 原样照抄现有 skill，一字不改**（§5.4）。
- **协作协议 = 薄模块**：「在 kanban-team 里 pm 具体怎么跟 dev 配合」（派活→写 handoff→收 return→推看板→回 owner）是**这支 team 特有的协作协议**，应**单独成一薄层**，别跟 pm 的通用协调能力混在一起。pm 用 skill-creator 造 skill 时，把这段 kanban-team 协作协议**独立成段/独立 reference 文件**（§5.3 (b)）。

**⚠️ 真缺口（今天没有干净落点，标给 Allen —— §8/§9）**：现有代码**没有**"把一段 per-socialware 的常驻协作协议注入进 agent 常驻 context"的干净入口：

- agent 的**常驻** context 只有 `recipe.prompt`（`apps/ezagent_core/lib/ezagent/agent/recipe.ex`）——**socialware-无关**（recipe 是 flavor-agnostic 通用体，不该塞某个 team 的协作细节）。
- `Definition.prompt_templates`（`definition.ex:23,97`）**不是常驻**：它在 materialize 时 install（`template_team.ex:203-211`），但**每条消息投递时才临时套用**（`prompt_template_ref` = PR-4 delivery transform，`legend.ex:40` / `resolver.ex:172,251` / `prompt_template.ex:6`），不是 agent 一直带着的 context。

→ **所以「薄协议模块」today 只能落在两处（都不理想）**：(1) 写死在 dev-together/pm 的 **skill 文本**里；(2) 散配在 Definition 的 **routing_rules / legends / prompt_templates** 三块。本 spec 采 (1)（pm skill 里独立一段 kanban-team 协作协议 + relay 标记，§5.3）。**理想的"per-socialware 薄协议模块常驻注入"抽象缺，列 §8 迁移标注 + §9 discuss-first 待 Allen。**

### 5.1 决策：新 recipe 归 kanban 插件（贴 split-c，main 既成事实）

split-c 决策（`feat/kanban-split-c`，已是 main 事实：`git grep DefaultRecipes upstream/main -- apps/` 为空）：**agent 域不 hardcode 产品 recipe；kanban-assistant / dev-together 归 kanban 插件 `roles/0`**。本 spec 按它落地。

> **discuss-first Q1（§9）**：pm 也可复用 cc 的 `Ezagent.Orchestrator.OrchestratorRecipe`（`orchestrator_recipe.ex:65`，name `"orchestrator"`）当协调者。本 spec 选**新 kanban-assistant recipe**（贴 split-c + 让 pm persona 讲 kanban 派活 + relay 协议）。Allen 若拍复用 orchestrator，则 §3.2 pm 角色槽 `recipe` 改 `"orchestrator"`、删 S1 recipe 部分即可。

### 5.2 kanban-assistant recipe 形态（cc-headless 协调者）

- `name: "kanban-assistant"`，`flavor` 由角色槽给（`"cc-headless"`）。
- `skills: ["kanban-assistant"]`（persona skill，cc `OrchestratorBootstrap.install_role_sandbox` 把它 copy 进 `config_dir/skills/`，`orchestrator_bootstrap.ex:165-169`，解析根 `.claude/skills`，`:66`）。
- `prompt: kanban_assistant_persona()`（协调者 persona 字符串）。
- `requested_caps`：pm 要能驱动看板 → 每个 kanban action 一个 cap-template map（同 kanban-manager recipe 的 `requested_caps` 生成法，`application.ex:93-96`）：
  ```elixir
  for action <- Ezagent.ActionSet.Kanban.actions() do
    %{behavior: Ezagent.ActionSet.Kanban, action: action}
  end
  ```
  conformance 断言 4（`agent_caps_and_role_uniqueness`）校验这些 cap 的 behavior 可 load（`conformance.ex:171-196`）——`ActionSet.Kanban` load，过闸。

### 5.3 kanban-assistant persona skill —— **用 skill-creator 规范新建，必须写全**

- 新目录 `.claude/skills/kanban-assistant/`（cc 的 `role_skill_install_test.exs` 已锚定 `@skill_ref "kanban-assistant"`，`apps/ezagent_plugin_cc/test/ezagent/template/role_skill_install_test.exs:18` — 本 skill 是它期待的真实来源）。
- **用 skill-creator（`superpowers:writing-skills` / skill-creator）规范建**：`SKILL.md`（YAML frontmatter name/description + body）+ 按需 `references/` `scripts/`（不重造已有工具，需要时补 reference）。
- **两层分开写（§5.0 原则，本切片硬要求）——协议必须独立成可切出模块**：
  - **pm 主体（SKILL.md body）= 只写通用协调能力**（读 owner 意图、拆活、审 DoD、跟 owner 汇报）。这部分不知道 kanban-team 协议的任何细节。
  - **kanban-team 协作协议 = 一个独立 reference 文件 `references/kanban-team-collaboration.md`**（**必须独立成文件，不许内联进 SKILL.md 主体**）。下 (a)/(b)/(c) 的全部协议细节（9-棒环节流转、派活=写/审 handoff、收活=看 `returns/<task>.md`+CI、完成标记约定）写在这个 reference 里。**SKILL.md 主体只用一行 `@references/kanban-team-collaboration.md` 引它**，绝不复述协议内容。
  - **（可选）`scripts/relay-signal-check.sh`**：一个协议校验/信号脚本，检查完成标记字面与 Definition matcher `arg` 是否对齐（唯一契约点自检，§4.2）——不是必须，但让「协议 ↔ 传输对齐」可机器验。
- **⚠️「可切出模块」标注（load-bearing）**：`references/kanban-team-collaboration.md` **是一个可整块切出的独立模块**——今天因为平台没有「workflow 编排模块」的落点，它暂时寄居在 pm 的 skill 里；**一旦 §9 的 workflow 编排模块（`feat/ezagent-scout` discuss-first，见 §9 Q5）落地，这个 reference 整块上移到编排模块，pm skill 回归纯通用协调能力**。所以它**必须**跟 pm 的核心协调能力物理分开（独立文件、独立可读、不与主体逻辑交织），切走时不牵动主体。**别把协议细节撒进 SKILL.md 主体的段落里——那样将来切不干净。**
- **唯一契约点写进协议模块**：`references/kanban-team-collaboration.md` 里**必须显式写明**——完成标记（`__done__` header / `@完成回传` legend 名）**必须与 `socialware:kanban-team` Definition 的 `routing_rules` matcher `arg` 逐字一致**（§4.2）。这是协议模块与传输层之间**唯一**的契约，改任一端都要同步改另一端。
- **协议 reference 覆盖清单（③ 完备性 —— 下三项全写进 `references/kanban-team-collaboration.md`，非 SKILL.md 主体；每项都要有对应段，见 §5.5 矩阵）**：
  - **(a) 环节流转**：9-棒阶段链 `positioning → metric → pain → anchor → ux → feature → issue → test → pr`（`ci_stage: :pr`），是 kanban-manager recipe 携带的 **layer-2 config**（`application.ex kanban_manager_recipe/0`）；pm skill 讲清每棒的准入/推进条件与顺序。
  - **(b) 派活协议 = 走 dev-together 的 git-handoff 工作流，不是 @dispatch**：pm 派活 = **写一份 markdown handoff**（`plan.md → handoffs/<task>.md`，含 DoD，dev-together `handoff` command 的产物）交给 dev-together 成员；dev 干活 = `dive`（切 task 分支 off `main` / TDD / PR 进 task 分支）；dev 交活 = `return`（CI 绿 + rebase gate + DoD 逐行对账 + 写 `returns/<task>.md`）**并发一条带完成标记（`__done__` 头 / `@完成回传`）的消息**——这条消息经 §4 的内容触发路由投到 pm（**routing 只是这声"交活了"的传输**）。**pm skill 要写清：派活=生成/审 handoff（不是把路由算给 worker），收活=看 dev 的 return（`returns/<task>.md` + CI 状态），完成标记只是让 pm 知道"该看 return 了"。**
  - **(c) 审 gate / 推进看板**：收到完成信号后**审 dev 的 return（DoD 对账 + CI 绿 + rebased）**，再用 `kanban.<action>` 建卡/assign/推进阶段、`pr` 棒是 CI-gated 收口、回 owner 汇报。

### 5.4 dev-together recipe（照抄现有 dev-together skill）

> **这份 skill 就是 pm↔dev 配合的实体（能力技能层，§5.0）**：它的 8-command git-handoff 工作流（handoff/dive/return/CI gate/…）**是**协作机制本身；§4 的 routing 只是这套工作流里"交活了"那声轻传输。所以它**跨 socialware 可移植、照抄不改**。

- `name: "dev-together"`，`flavor` 由角色槽给（`"cc-headless"`），`skills: ["dev-together"]`，`requested_caps` = kanban action caps（claim/work/推进相关，同 §5.2 生成法）。
- **skill = 照抄 sw-kanban 现有 `.claude/skills/dev-together/` 全套**（**迁移=原样搬、逐条保留，不重写不裁剪**）。现有那份的真实功能清单（现读 `SKILL.md` 204 行 + 全套文件）：

  | 组成 | 内容 | 来源文件 |
  |---|---|---|
  | **8 个 command** | `init` / `plan` / `handoff` / `dive` / `return` / `push` / `close` / `review` 每日循环 | `SKILL.md:149-163` + `commands/{init,plan,handoff,dive,return,push,close,review}.md` |
  | **角色** | Lead programmer（唯一进 `main` 的路径，经 `close`）+ Developer（接 handoff、per-task 分支、return） | `SKILL.md:72-76` |
  | **分支模型** | `main` 是 trunk；`beta`/`release` 是 deploy 指针（非 task 分支），deploy flow 推进 | `SKILL.md:78-84` |
  | **产物布局** | `docs/together/YYYY-MM-DD/`：`plan.md`+`plan.html` / `handoffs/<task>.md` / `returns/<task>.md` / `stack.md` / `review.md`+`review.html` | `SKILL.md:86-96` |
  | **持久团队状态** | `docs/together/team.md`（roster，行标识=`github_username`）+ `<ISO-week>/weekly-goals.md`（周目标） | `SKILL.md:100-121` |
  | **Ledger 规则** | No empty plan / timestamp every return / reconcile whole ledger / close PR state / team-facing `.html` render / SDD scratch 在 `.superpowers/sdd/` | `SKILL.md:123-147` |
  | **Handoff 标准** | 四-属性 Definition of Done + discuss-first 触发 + defer 规则 + per-task-branch merge 模型 | `SKILL.md:168-173` + `references/handoff-standard.md`（93 行）+ `references/handoff-template.md`（64 行） |
  | **完整 PDCA loop** | Front clarify/research（`clarify_first` research handoff）+ Back method-writeback（return 的 DoD 逐行 reconciliation + review 的 method-deltas）+ Machine return gate（CI `precommit + check_invariants` 绿 + rebased on main） | `SKILL.md:175-204` |
  | **scripts/** | `new_day.sh`（60 行，scaffold 当日 folder）/ `validate_skill.sh`（44 行）/ `install_hooks.sh`（70 行，装 deadline hook） | `scripts/*.sh` |
  | **hooks/** | `handoff-deadline-reminder.sh`（51 行，deadline 提醒 hook） | `hooks/handoff-deadline-reminder.sh` |
  | **delegates** | superpowers:brainstorming / writing-plans / executing-plans / subagent-driven-development、codex-rescue review、ezagent-deploy | `SKILL.md:62-70` |

- **迁移动作**：把上表**每个文件原样 copy** 进 kanban 插件的 skill 目录，作为 `dev-together` 角色槽的 skill；**dev-together 自身 skill 内容一字不改**（8-command 主体 / references / scripts / hooks 全部原样保留）。
- **dev-together 在 kanban-team 里的参与 = 一个薄协议 overlay（不改 dev-together 自身 skill）**：dev-together 作为通用能力技能不知道自己在哪个 team。它在 kanban-team 里「完成后发什么标记」这段**协作约定**，落成一个**新增的薄 reference 文件 `references/kanban-team-relay.md`**（**只新增、不动原 8-command 主体**）。这个薄 overlay **不复述协议、只指向同一份协作协议**——即 pm 的 `references/kanban-team-collaboration.md`（唯一权威协议源），并复述唯一契约点：完成标记字面必须与 Definition matcher `arg` 一致。**同一份协作协议、两个角色各一个薄 overlay 指过去**——将来协议整块上移到 workflow 编排模块时（§9 Q5），两个 overlay 一起退休，dev-together 恢复为纯通用能力技能、pm 恢复为纯协调能力。

### 5.5 pm skill 覆盖矩阵（③ 完备性检查 —— 每格都要有 skill 段落，不漏）

| 维度 | 具体项 | pm skill 覆盖段 |
|---|---|---|
| **阶段 · 9 棒** | positioning / metric / pain / anchor / ux / feature / issue / test / pr | (a) 环节流转：每棒准入 + 推进条件 |
| **操作 · 建卡** | `kanban.create_*` 建卡 | (c) 推进看板 |
| **操作 · 派活** | `@dev-together` assign + 要求 relay 回传 | (b) 派活协议 |
| **操作 · 推进** | `kanban.<advance>` 移阶段 | (c) 推进看板 |
| **操作 · 收口** | `pr` 棒 CI-gated 收口 | (a)+(c) |
| **relay 协议** | 收到 `__done__`/legend → 审 DoD → 推进 → 回 owner | (b)+(c) |
| **回报** | 对 owner 汇报变更 | (c) |

**完备性判据**：矩阵每一行在 pm 协议 reference `references/kanban-team-collaboration.md`（**非 SKILL.md 主体**——主体只写通用能力 + `@reference`，§5.3）都有对应段落，且 (b) 的回传标记（`__done__`/`@完成回传`）与 §4.2 routing_rules 的 matcher `arg` **字面一致**（协议 ↔ 传输唯一契约点，两端对齐才闭环）。

---

## §6 测试策略

**跑法（umbrella 根，绝不 per-app cd）**：先 `docker start ezagent-pg-compat-audit-postgres` + `mise exec -- mix ecto.create && mise exec -- mix ecto.migrate`，然后 `mise exec -- mix test apps/<app>/test/...`。

| 层 | 覆盖 | 命令 |
|---|---|---|
| **单元** | kanban-assistant / dev-together recipe 注册进 RecipeRegistry + 可解析（S1）；kanban-team Definition `new/1` round-trip + body/content_hash + **零实例 URI 断言**（S2）；legends/routing_rules 内容触发形态（S3） | `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_team_test.exs` 等 |
| **conformance gate** | kanban-team 过 12 条断言 | `mise exec -- mix ezagent.socialware.check kanban-team --workspace workspace://system` |
| **round-trip gate（新增，load-bearing）** | materialize kanban-team → 快照回 Definition（`DefinitionSync`/orchestrator save）→ `Definition.new/1` **不报** `:socialware_definition_declares_instance_uri`（证明规则里零 URI，round-trip 安全，§4.4） | `mise exec -- mix test apps/ezagent_plugin_kanban/test/integration/kanban_team_roundtrip_test.exs`（**kanban test 树，非 domain**，§11） |
| **集成（relay-back）** | materialize kanban-team → 读 RuleStore/legends 断言规则含内容触发 matcher（`text_contains "__done__"` 或 `mention "完成回传"`）+ `{:role,"kanban-assistant"}` receiver；Resolver：带 `__done__`/legend 的消息 → 命中 pm，不带的消息 → 不命中 relay-back | `mise exec -- mix test apps/ezagent_plugin_kanban/test/integration/kanban_team_relay_back_test.exs`（**kanban test 树**，§11） |
| **真浏览器 e2e（最高纪律）** | dev server 10042 真登录 → 安装 kanban-team → 打开 session 聊天面 → owner 对 pm 派活 → pm @dev-together 派活 + 建卡/推进 → dev-together 发 `__done__` relay-back → 看板前进（board 可视化用 `/plugins/kanban`）；**每步截图** | Playwright（见 plan Task 6，`docs/scenarios/kanban-team/`） |

**e2e 硬纪律**：禁止硬编码/stub 当 e2e；每个有意义步骤（配置→登录→安装→聊天派活→relay 回传→看板推进→结果）都截图；证据留 `docs/scenarios/kanban-team/`。

**relay-back 集成测试设计（内容触发 + role 受端）**：
1. 建一个 kanban-team live session（materialize）。
2. 断言 RuleStore（`rule_set: "relay-back"` 的规则）：matcher == 内容触发（`{:text_contains, "__done__"}` 或 `{:mention, "完成回传"}`）、receivers == `[{:role, "kanban-assistant"}]`、position 0；若用 legend，断言 `legends["完成回传"].member_set == ["kanban-assistant"]`（role_name，零 URI）。
3. 构造 `Message`（body 含 `"__done__"` 或 `legend_triggers` 含 `"完成回传"`）→ `Resolver.resolve_with_ctx` → 命中 pm（展开成 pm per-session URI）。
4. 构造 `Message`（普通正文，无标记）→ **不**命中 relay-back。
5. **零-URI 结构 gate**：断言存进 RuleStore / Definition 的规则字符串里无 `entity://…/agent|user/…`（round-trip 安全的结构证据）。

---

## §7 代码 vs 配置 分类表（四硬要求 #1）

| Task | ①写代码 / ②提交配置 | 落点 | 今天有 UI？→ 交付方式 |
|---|---|---|---|
| S1 kanban-assistant recipe | **①写代码** | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（`roles/0` + `kanban_assistant_recipe/0`） | — |
| S1 pm persona skill（skill-creator 新建） | **①写代码**（资产文件） | `.claude/skills/kanban-assistant/SKILL.md`（+ 按需 `references/`） | — |
| S1 dev-together recipe | **①写代码** | `application.ex`（`dev_together_recipe/0`） | — |
| S1 dev-together skill（照抄现有全套） | **①写代码**（资产文件，原样 copy） | kanban 插件 skill 目录（`SKILL.md` + `commands/` + `references/` + `scripts/` + `hooks/`，逐个保留） | — |
| S2 kanban-team Definition 声明（roles/字段） | **②提交配置** | 新 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex` 里的 Definition body（config-as-data） | **无 UI** → **走 code-seed**（仿 hello `seed_definition_if_absent`，`app.ex:238`）。未来 registry P3 从外部 config 源发布（§8） |
| S2 seed 装配（boot hook 调 seed） | **①写代码** | kanban `application.ex` `start/2`（env-gated skip `:test`，仿 hello `application.ex:59`） | — |
| S3 relay-back routing_rules + legends | **②提交配置** | kanban-team Definition body（`routing_rules` + `legends`，内容触发，零 URI） | **无 UI** → code-seed |
| S3 relay 协议写进 skill | **①写代码**（资产文件） | pm skill（§5.3 (b)）+ dev-together skill 的 kanban-team 协议附注（§5.4） | — |
| S4 kanban render view（可选） | **①写代码** | 新 view ActionSet（`<kanban_render>`）+ Definition `views` 加它（②配置） | 见 §9 Q2 |
| S6 e2e 脚本 + 证据 | 测试资产 | `docs/scenarios/kanban-team/` + Playwright | dev server 10042 真浏览器 |

**判定原则**（handoff / dev-readiness）：配置类今天大多**没 UI** → 一律 **code-seed**（imperative Elixir 调 `seed_definition_if_absent`），不走插件包 manifest（`manifest.ex` 拒 `:socialware` seed 是 Allen 有意，§8）。**relay-back 从「机制代码（S3a URI 解析）」降级为「纯配置（内容触发规则）+ skill 协议」**——不再需要动 `template_team` 的 matcher 解析代码（这是内容协议相比 sender-lock 的又一收益：**S3 无 core/session 机制改动**）。

---

## §8 迁移标注表（等 main 更新要迁移的项，四硬要求 #2）

| 受影响项 | 现在怎么做（main，含 #1180） | ⚠️ main 到 X 后迁移 Y |
|---|---|---|
| Definition 参与者声明 | **现在的 API（#1180 已落地）**：用 `roles` 字段声明 agent 角色槽 `%{role_name, fill: :agent, recipe, flavor}`（全字符串、零 URI，`definition.ex:34-36,284-286`）；`agents`/`members` 已退休，`Definition.new/1` fail-loud 拒它们（`definition.ex:313-318`）。**直接 `roles` 写** | —（role-slot 已落地，无未来迁移动作） |
| owner 声明 | **#1180**：`owner_policy: %{type: :installer}`（`owner_uri/2` `definition.ex:176`）；`:fixed` owner 类型**已被拒**（`definition.ex:412-425`） | —（已落地） |
| relay-back 表达 | **内容触发 + role 受端 + skill 协议**（`text_contains`/`mention` legend + `{:role}` receiver，零 URI，§4）——纯配置 + skill，无 core/session 机制改动 | —（形状 #1180-safe，round-trip 闭环，无未来迁移） |
| relay-back **硬**锁（可选） | 不做——内容协议是软锁（靠 dev-together 遵守 skill），对可信 team 够用（§4.3） | ⚠️ main 若加 **membership-role matcher**（按成员 role_name facet 匹配发送方、只存 role_name、零 URI）后：可做「只有特定角色发才转」的硬锁且仍 round-trip 安全。今天需新机制，flag S5（**非本切片前置**） |
| kanban-team 发布 | code-seed（`seed_definition_if_absent` → `workspace://system`，仿 hello） | ⚠️ main 到 **registry P3**（外部 config 源 + deploy-seed/promote，`docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md §5`）后：Definition 从「插件 imperative seed」迁到「registry 版本化分发/promote」。**更硬的分发，非最小闭环前置** |
| 发现/安装面 | `DefinitionRegistry.list/1` + `Installation.install_template_installs/4` + world sessions_table「socialwares」rows | ⚠️ main 到 **registry P1/P2**（catalog 发现 UI/API + 统一安装路径）后：kanban-team 在平台目录被搜/装、建 session 收敛进标准安装路。**工程整洁，非前置** |
| 声明式打包进插件包 | **不做**——`core/manifest.ex:174-186` seed_ref 只认 `:recipe`，`core/plugin.ex:195-257` 无 `definitions/0`（**Allen 有意绕过，非待补缺口**） | 无迁移动作；若 main 未来加 `definitions/0` callback（`#1148` 审计标的「声明式打包」propose），可把 code-seed 换成契约声明——但那是平台决策 |
| 跨 owner 动态加入 kanban-team | 不做 world 审批 UI（§9 Q3）；#1178 admission gate 机制现成（`membership.ex do_join :85-86` + `:approve_admission`） | ⚠️ 要「陌生人申请进 team + owner 审核」的完整产品语义时，在 world/e2e 层驱动 #1178（机制不缺，缺 UI 驱动） |
| **per-socialware 薄协作协议注入（§5.0 缺口）** | **无干净入口**：常驻 context 只有 socialware-无关的 `recipe.prompt`（`recipe.ex`）；`Definition.prompt_templates` 是每条消息投递时临时套（PR-4 transform，`legend.ex:40`/`resolver.ex:172,251`），非常驻。today 只能把 kanban-team 协作协议写死进 pm/dev skill 文本，或散配进 Definition 的 routing_rules/legends/prompt_templates | ⚠️ 若 main 加「per-socialware 常驻协议模块」抽象（一段绑到某 Definition 的常驻 team-context，materialize 时注入进该 team 成员的常驻 prompt，与通用 recipe.prompt 分层），则 pm/dev skill 里那段 kanban-team 协作协议可上移到该薄模块、skill 回归纯通用能力。**抽象缺，非本切片前置，flag 给 Allen（§9 Q5）** |

**净判断**：**role-slot #1180 已落地、relay-back 改内容协议后无 #1180 冲突、round-trip 闭环**——本 spec 直接用 `roles` + owner `:installer` + 内容触发规则 + `{:role}` receiver，**零返工、无需 Allen re-verify 任何机制冲突**（旧 §4.3 的 sender-lock 解析源冲突已随方案变更消失）；registry P1-P3 / membership-matcher 是叠加、也不阻塞。

---

## §9 discuss-first（给 Allen 拍板；不阻塞 S1-S3 最小闭环）

1. **Q1 — pm = 新 recipe 还是复用 cc orchestrator？** 本 spec 选新 kanban-assistant recipe（贴 split-c）。影响 S1。
2. **Q2 — kanban-team 首版要不要公开 render view？** 本 spec 首版 `views: []`，board 可视化复用 world `/plugins/kanban`。要公开页则 S4 加 `<kanban_render>` SessionView（工作量 + conformance 断言 2/9 要求 render cap 注册，`conformance.ex:109-143`）。
3. **Q3 — join/admission 语义（S5）**：别人**动态申请**加入一支 kanban-team session 用不用 #1178 admission gate（cross-owner → PENDING → owner 审核）？+ 若要 relay 的**硬**锁（membership-role matcher，§4.5）要不要现在做。**要 Allen 拍档位**（匿名读 / 登录非成员读 / 成员读写）。
4. **Q4 — 分发时机（S6）**：先 imperative code-seed 验证 pm+dev-together+kanban+relay-back 闭环，还是一步到位走 #1173/#1176 registry 版本化分发。本 spec 建议先 code-seed 验证闭环。
5. **Q5 — per-socialware 薄协作协议模块 = workflow 编排模块的切出目标（§5.0/§5.3 缺口，`feat/ezagent-scout` discuss-first）**：本切片已把 kanban-team 协作协议**独立成一个可切出模块** `references/kanban-team-collaboration.md`（§5.3，SKILL.md 主体只 `@reference` 引它，两个角色各一薄 overlay 指向它）——这是 today 能做到的最干净落点。**理想终态**：这段协作协议该住在一个**绑到 Definition 的常驻 team-context 薄模块 / workflow 编排模块**（materialize 时注入进 team 成员的常驻 prompt，与通用 `recipe.prompt` 分层），而不是寄居在 skill 的 reference 里。**today 无此抽象**（常驻只有 socialware-无关的 `recipe.prompt`；`prompt_templates` 是 per-delivery 非常驻，`legend.ex:40`/`resolver.ex:172,251`）。**要 Allen 拍**：(a) 现在就在 `feat/ezagent-scout` 立 workflow 编排模块、把这个 reference 整块上移；还是 (b) 先接受本切片的「独立 reference 寄居 skill」形态、待编排模块落地再切。本 spec 走 (b)（不阻塞闭环），但**已按「可切出」结构写**——切走时 pm/dev skill 回归纯能力，零返工。

> **注**：旧版本这里有一条「给 Allen 的 `{:from_role}` sender-matcher 解析 discuss-first」——**已删**：relay-back 改内容协议后不再有 `{:from, role}` → URI 的解析问题，无待拍机制冲突。

---

## §10 S1-S6 → Task 映射 + 最小切片顺序

| 产品步 | 内容 | Plan Task | 切片阶次 |
|---|---|---|---|
| **S1** | kanban `roles/0` 补 kanban-assistant recipe（skill-creator 新建 persona）+ dev-together recipe（照抄现有 skill 全套） | Task 1 | **最小切片①** |
| **S2** | 写 kanban-team Definition（两 agent 角色槽 pm+dev；board 非成员）+ code-seed + 过 conformance + round-trip gate | Task 2 | **最小切片②** |
| **S3** | relay-back：内容触发 routing_rules + legends + 两 role skill 协议 + 集成测试（无机制代码改动） | Task 3 | **最小切片③** |
| **S4** | kanban render view（gated Q2） | Task 4 | 增强（Allen 拍后） |
| **S5** | join/admission（#1178 驱动）+ relay 硬锁（membership-role matcher，gated Q3） | Task 5 | 增强（Allen 拍后） |
| **S6** | 真浏览器 Playwright e2e（pm 派活 / dev-together relay / 看板推进）+ 截图 | Task 6 | 闭环验收（S1-S3 后即可） |

**最小切片先行**：**S1（两 recipe + 两 skill）→ S2（两角色槽 Definition，board 非成员）→ S3（内容触发 relay-back）**，三步跑通即「pm + dev-together + kanban + relay-back 打成一支可安装 team 且 round-trip 安全」的最小可 ship 闭环；S6 e2e 收口验收；S4/S5 待 Allen 拍板再做。

---

## §11 self-containment 审查表（对抗自查 —— 每个 Task 只碰 `ezagent_plugin_kanban` + 纯配置）

**铁律**：本次 kanban 开发**只准**动 (1) `ezagent_plugin_kanban` 自己的代码/测试/skill 资产；(2) 纯配置（Definition/routing_rules/legends，走 code-seed）。**禁碰** `ezagent_core` / `ezagent_domain_*` / 别的 plugin / hello 的任何代码。逐 Task 现读 `Files: Create/Modify` 核对如下。

**依赖方向现读核实**（决定测试能放哪）：`ezagent_plugin_kanban/mix.exs` 有 `{:ezagent_domain_session, only: :test}` + `{:ezagent_domain_workspace, only: :test}` + `{:ezagent_domain_agent}`（`mix.exs:52-59`）；`ezagent_domain_session/mix.exs` **无** kanban 依赖（现读确认）。→ **plugin → domain 是允许的箭头；domain → plugin 是层级违规。** 任何同时引用 `EzagentPluginKanban.*` 与 `TemplateTeam`（domain_session）的集成测试**只能住在 kanban 的 test 树**（kanban 有 test-dep 到 domain_session），**绝不能住在 `apps/ezagent_domain_session/test/`**（那会逼 domain 依赖 plugin）。

| Task | `Files:` 落点 | 只在 kanban + config？ | 判定 |
|---|---|---|---|
| **T1** recipe+skill | `apps/ezagent_plugin_kanban/lib/.../application.ex`（改）；`.claude/skills/kanban-assistant/**`（新，含 `references/kanban-team-collaboration.md`）；dev-together skill copy（新资产）；`apps/ezagent_plugin_kanban/test/kanban_role_test.exs`（改） | ✅ application.ex/test 是 kanban 自己；skill 资产是 kanban 角色的新资产（不动任何其它 app） | 🟢 GREEN |
| **T2** Definition+seed | `apps/ezagent_plugin_kanban/lib/.../kanban_team.ex`（新）；`apps/ezagent_plugin_kanban/lib/.../application.ex`（改 `start/2` 加 env-gated seed）；`apps/ezagent_plugin_kanban/test/kanban_team_test.exs`（新） | ✅ 全在 kanban；seed 调 `DefinitionRegistry.seed_definition_if_absent`（domain 的 **public API**，仿 hello，不改 domain 代码）；Definition body = 纯 config-as-data | 🟢 GREEN |
| **T3** relay-back | `kanban_team.ex`（改 config：加 routing_rules+legends）；pm/dev skill reference（改资产）；**集成/round-trip 测试** | ⚠️ **plan 原把两个集成测试放 `apps/ezagent_domain_session/test/integration/` + `use EzagentDomainInstanceMessage.DataCase`** → **碰插件外 app + 反向依赖（domain 依赖 plugin）+ 用了不对外暴露的 DataCase** | 🔴 **RED → 已改** |
| **T4**（gated Q2） render view | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex`（新）；`kanban_team.ex`（改 config）；`application.ex`（改，注册 SessionView 走 domain public API）；`test/behavior/kanban_render_test.exs`（新） | ✅ 全在 kanban；SessionView 注册调 `Ezagent.UI.SessionViewRegistry.register`（domain public API，仿 hello，不改 domain） | 🟢 GREEN（gated） |
| **T5**（gated Q3） admission + 硬锁 | (a) admission 集成测试（放 kanban test 树，驱动 `session.join` public 路）；**(b) relay 硬锁 = 在 `Ezagent.Routing.Matcher` 加 `{:from_role}` leaf + 改 `install_one_rule`** | ⚠️ **(b) 要改 `apps/ezagent_core/lib/ezagent/routing/matcher.ex`（CORE 原语）** —— 不可自包含 | 🔴 **RED（(b) 越界）→ 移平台 track** |
| **T6** e2e | `docs/scenarios/kanban-team/**`（新，docs+截图）；Playwright 脚本（团队 e2e 目录） | ✅ 纯 docs/测试资产，不碰任何 app 代码 | 🟢 GREEN |

### 违规项 + 处置

- **🔴 T3 集成测试放错 app（已在本轮修正）**：plan 原 `Files:` 把 `kanban_team_relay_back_test.exs` + `kanban_team_roundtrip_test.exs` 放 `apps/ezagent_domain_session/test/integration/`，并 `use EzagentDomainInstanceMessage.DataCase`。**三重问题**：(1) 落在 `ezagent_domain_*` 树 = 碰插件外 app；(2) 测试引用 `EzagentPluginKanban.KanbanTeam`，逼 domain_session 依赖 plugin = 层级违规（domain→plugin）；(3) `EzagentDomainInstanceMessage.DataCase` 是 domain_session 的 test-support，**不对下游 app 暴露**。**处置 = 改成自包含**：两个测试**移进 `apps/ezagent_plugin_kanban/test/integration/`**，`use EzagentCore.DataCase`（core DataCase 对下游可用），`setup` 里 `Application.ensure_all_started(:ezagent_domain_session)` + `EzagentDomainInstanceMessage.UriQueryResolvers.register()` 把 domain 拉进测试运行时——**这正是 kanban 现有集成测试的既有模式**（`apps/ezagent_plugin_kanban/test/e2e/role_native_create_test.exs:26,34-38` 现读）。改后 T3 全部落点回到 🟢。plan Task 3 已同步改。
- **🔴 T5(b) relay 硬锁触碰 core（本切片不做，移平台 discuss-first）**：membership-role matcher 需在 `Ezagent.Routing.Matcher` 加 `{:from_role}` leaf——这是 **core 路由原语的新增**，**不可能自包含在 kanban 插件里**。**处置 = 不在本 kanban 切片做**；作为平台能力移去 `feat/ezagent-scout`（或等 Allen 拍 Q3）当 platform discuss-first。本切片的内容协议软锁已够（§4.3/§4.5），**不需要**这块。plan Task 5 已标 gated + 明确「要改 core、非本切片」。

### 净结论

修掉 T3 测试落点后，**S1-S3 最小闭环 + S6 e2e 的每一个 Task 都只碰 `ezagent_plugin_kanban` 自己的代码/测试/skill 资产 + 纯配置**（Definition/routing_rules/legends 走 code-seed），并只经 **domain 的 public API**（`seed_definition_if_absent` / `SessionViewRegistry.register` / `session.join`）与 domain 交互——**零 domain/core/hello/别的 plugin 代码改动**。唯一真越界项 T5(b) 已隔离到平台 track、非本切片。
