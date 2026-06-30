# 让一个 agent 具备使用 plugin 的能力

> 这份文档讲**怎么把一个 plugin 的能力配到一个 agent 身上**：role/flavor/recipe/cap
> 模型是什么、能力怎么 materialize 到一个 per-session agent、cap 怎么授予、**哪些现在
> World UI 已经能配**、**哪些当前还得靠代码 seed（以及后续该补哪些配置 UI）**、以及
> 不靠 UI 时的 CLI 逃生口。读者是**想让某个 agent 会用某个 plugin 的人**（运营 / 集成 /
> 给团队搭协作流的工程师）。
>
> 配套：plugin 本身怎么开发见 `docs/guide/plugin-development.md`；本篇假设 plugin 已存在，
> 只讲「怎么让 agent 用上它」。例子用 **pm-coordinator**（看板项目经理大脑）+
> **dev-together**（开发块 agent）。

---

## 0. 一句话模型

> **一个 agent = `Entity.Agent` 宿主 × 一个 role（recipe）× 一个 flavor（大脑类型），
> 它能做什么 = 它实际持有哪些 cap。**

- **role**：一份 recipe（数据，不是代码），声明这个职位**请求**哪些 behavior + cap +
  skill + persona + 业务 config。role-as-data：recipe 统一存为 `config://<ws>/recipe/<name>`
  ConfigObject。两条注册路（都落进 `RecipeRegistry`，按名字寻址）：
  - **plugin 自身的 native agent**（如 kanban-manager，board 本体）→ plugin 的 `roles/0`。
  - **通用 cc-headless agent**（如 pm-coordinator / dev-together）→ `Ezagent.Agent.DefaultRecipeSeed`
    （domain_agent boot 的**非-plugin 统一入口**，2026-06-30 refactor：这类通用 agent 配置不再塞进
    任何 plugin 的 `roles/0`）。
- **flavor**：大脑/宿主类型——`native`（纯机制宿主，无 LLM）、`cc`（真 claude sidecar）、
  `cc-headless`（无头 claude）。flavor 决定 materialize 时怎么接线（如 `cc` 的
  `CapMint` 注入 cap 的 kind 轴、装 skill 进 config_dir）。
- **recipe**：`%{name, passive, behaviors, requested_caps, skills, config}`。`requested_caps`
  是这个 role **想要**的 cap 模板集（least-priv 起手）。
- **cap**：实际授予的 `%Capability{}`（4 元组身份：kind / behavior / action / instance +
  workspace）。**recipe 里的是「请求」，grant 之后才是「持有」**。least-privilege：只授
  recipe 声明的那些，且默认 scope 到 agent 自己实例。

`requested_caps` ≠ 持有的 cap。中间隔着一步 **grant**（§3）。

---

## 1. role / flavor / recipe / cap（声明在哪、长什么样）

plugin 自身的 native agent recipe 由 plugin 的 `roles/0` 声明（kanban 只声明 `kanban-manager`
——它的 native board agent；pm-coordinator / dev-together 这类通用 cc-headless agent 的 recipe
在 `Ezagent.Agent.DefaultRecipes` + 经 `DefaultRecipeSeed` 统一入口注册，不在 kanban roles/0）：

```elixir
# kanban-manager —— 被动看板数据 actor（看板本体）
%{
  name: "kanban-manager",
  passive: true,                       # 不可 @ / 不可 :join / 不收 chat，只在直接 dispatch 上动作
  behaviors: [Ezagent.Behavior.Kanban],
  requested_caps: [%{behavior: Ezagent.Behavior.Kanban, action: :add_node}, ...],  # cap 模板 map，不带 kind
  config: %{stages: [...], ci_stage: :pr, ...}    # Layer-2 业务数据
}

# pm-coordinator —— cc 大脑（项目经理），驱动 9 棒团队开发流
%{
  name: "pm-coordinator",
  passive: false,                      # chat principal：可被 @ / 可 :join（cc 大脑收 chat）
  behaviors: [],                       # pm 不挂 behavior，它经 CLI/dispatch 驱动 ezagent
  skills: ["pm-coordinator"],          # persona/skill，spawn 时装进 agent 的 cc config_dir
  requested_caps:                      # least-priv 起手集：看板 ops + github gateway 读写
    [%{behavior: Ezagent.Behavior.Kanban, action: :get_tree}, ...] ++
    [%{behavior: "Ezagent.Behavior.Github", action: :create_issue}, ...]  # 外 plugin 用字符串名
}
```

要点：

- `requested_caps` 是**模板 map**（`%{behavior:, action:}`），**不带 `kind`**——kind 在
  materialize 时由 flavor 注入（native/cc → `:agent`）。
- 外 plugin 的 behavior 用**字符串模块名**（`"Ezagent.Behavior.Github"`）保持零编译依赖，
  grant 时 loud 解析成 module，解析不到 fail-loud。
- `passive` 三闸区分「数据 actor」（kanban-manager，被动）和「chat 大脑」（pm-coordinator，
  能收 chat、能被 @、能 join）。

---

## 2. materialize：把 role-agent 落成一个 per-session live agent

recipe 只是**声明**；要让 agent 真正活起来并持有 cap，要 **materialize**。看板流的
materialize 触发点 = **board 绑定 session**（`kanban.bind_session`）：

```
operator/UI 触发 kanban.bind_session(session_uri)
        └─> Connectors.bind_session 写 board 配置 + 反应式起入站 poller
              └─> trigger_session_agents_materialize(session, board, ctx)   [best-effort, 非阻塞, Task.start]
                    ├─ PmCoordinatorSeed.materialize(session, ws, owner, board)   # pm 大脑
                    ├─ SessionAgentMaterialize.materialize_by_role("dev-together", session, ws, owner)  # 按 role 名，零编译依赖（recipe 住 domain_agent）
                    └─ wire_relay_back_routing(session, ws)                  # dev→pm 接力回路由规则
```

通用引擎是 `Ezagent.Agent.SessionAgentMaterialize`（住 `ezagent_domain_agent`，不 fork
per-plugin）。它做三件事（无新机制，纯组合既有 domain.agent 原语）：

1. **per-session/workspace scoped URI** —— `planned_agent_uri/3` 建
   `entity://<workspace>/agent/<role>-<session-disc>`（discriminator = 会话名）。身份+生命周期
   **per-session**，不是系统单例（2026-06-29 用户决策）。同 workspace 两个 kanban-flow 会话
   各得各的 pm/dev brain。
2. **凭证复用 orchestrator 路** —— `spawn_from_template_content/5` 以**会话 owner** 作
   `spawned_by_uri` + `caller` + `caps`，credential cascade 据此把 owner 的 `claude` 凭证
   materialize 进 per-agent `config_dir`。
3. **grant 落地** —— agent 一旦 live（Kind up + ReadyGate ready），经 sanctioned 的
   `GrantRecipeCaps.grant_recipe_caps/3` 把 recipe 的 least-priv cap **授到这个 per-session
   URI 上**（grant 在 spawn 之后跑，落在 live identity slice 上——T7b 早先 `:no_such_actor`
   就是因为目标还没 live）。

两个入口：

- `materialize/1`（spec）—— 拥有 role 的 plugin 自己用，spec 里塞自己的 template content +
  recipe（pm 走这条）。
- `materialize_by_role/4`（按 role **名**）—— 调用方对 role 定义**零编译依赖**时用：recipe 经
  `RecipeRegistry.lookup` 解析、cwd 经 `DefaultAgentSeed`。kanban materialize dev-together 走这条
  ——dev-together 的 recipe 住 `Ezagent.Agent.DefaultRecipes`、经 `DefaultRecipeSeed` 统一入口
  boot-seed（2026-06-30 refactor：dev-together 是一份 workflow recipe，**不是** plugin），kanban
  仍只靠**名字**解析它。role 没注册（domain_agent 没 boot / 没 seed，或拥有 role 的 plugin 没
  build）→ `{:error, {:role_not_registered, role}}` fail-closed，绝不静默 spawn 一个 cap-less agent。

> materialize 是 **best-effort + 非阻塞**：`cc` sidecar spawn 是多秒级，inline 会堵
> kanban Kind 的 mailbox，故 `Task.start` detached；materialize 失败**绝不**让 operator 的
> bind 失败，结果走 telemetry/Logger（cast 模式「谁知道它失败了」）。pm + dev-together 在
> **一个** detached Task 里**顺序**跑（两个并发 `cc` 冷启会抢 20s activate budget + DB pool）。

---

## 3. cap 授予（grant）

授予收口在 sanctioned mix-task `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps`：

```bash
mix ezagent.agent.grant_recipe_caps pm-coordinator                              # 授到系统单例默认 agent
mix ezagent.agent.grant_recipe_caps dev-together --agent-uri entity://ws/agent/dev-together-1  # 授到具体 per-session 实例
```

为什么是 mix task 而不是 boot 时自动授（p7 `cap_check_only_at_chokepoint`）：grant
（admin 权威授 cap）必须从**深思熟虑的入口**发起（Identity Behavior / admin LV / **mix task**），
不能从 boot 期 `after_boot` 这种非 deliberate 入口偷偷授。所以 `DefaultAgentSeed.seed/1` 只
**写模板**，grant 在**目标 agent 存在后**由这个 task 落地。

保证（fail-closed，无 partial、least-priv）：

- 每个 requested cap 的 behavior（atom 或 recipe 字符串名）**先**解析成 LOADED module；
  任一未加载 → fail LOUD（telemetry + `{:error, {:behavior_not_loaded, _}}`），**一个都不授**——
  绝不授一个静默 dead 的 cap。
- 每个 cap 在 genesis admin 身份下授（`granted_by: admin`），默认 scope 到 agent **自己**实例
  + workspace（least-priv self-scope）。

### instance_overrides（board-scoping，关键的越权防线）

有些 recipe cap 必须授权 dispatch 到**别的**实例：pm 的 kanban cap 闸的是 **board agent**
（`Behavior.Kanban` 住在 board 宿主上，不在 pm 身上），self-scoped cap 会在 dispatch
chokepoint 被拒。故 `grant_recipe_caps/4` 收一个可选 `%{behavior_module => target_uri}` map，
把那些 behavior 的 cap scope 到目标实例：

```elixir
# PmCoordinatorSeed.materialize 里：pm 的 kanban caps scope 到 BOARD agent
SessionAgentMaterialize.materialize(%{
  role: "pm-coordinator", ...,
  cap_instance_overrides: %{Ezagent.Behavior.Kanban => board_uri}   # 只 kanban caps board-scoped；github caps 仍 self-scoped
})
```

board-scoped cap 是**具体实例** least-priv 授予（**不是** wildcard `:any`），所以：dispatch
到这块 board 命中、dispatch 到**无关** board 被拒（instance 轴不匹配）——既不放松
`no_wildcard` / `no_unowned` 不变式，又给了 `instance: :any` 会丢掉的越权防线。`domain_agent`
对 kanban 一无所知——是 kanban 的 seed（同时知道 `Behavior.Kanban` 和 board URI）供这个 map。

---

## 4. 哪些现在 World UI 已经能配

World 是 transport（P13），它把 plugin 声明的 surface 渲染成可点入口。当前已落地的可配项：

- **Plugins 配置入口**（`config_surface/0`）：plugin 声明 `%{kind: :route, path:, label:}`，
  world `workspace_plugin_data.ex` 的 `list_plugins` 把它渲成 Plugins 页可点入口。
  kanban 声明 `/plugins/kanban`（K4 已落地 world 侧 handler + React 列表态，点击不再 404）。
- **左栏一级 nav**（`nav_surfaces/0`）：机制存在，但 2026-06-30 起**不是 core `Ezagent.Plugin`
  契约 callback**——搬到了 World 层（`Ezagent.World.UISurfaceProvider` **duck-type** 读 plugin 的
  plain `nav_surfaces/0` 函数 + read-time `valid_nav_surface?/1` 形状校验，core 零认知），别的
  plugin 仍可声明顶层 nav。**注意**：kanban 这条 surface 现已**整段删除**（2026-06-27 决策：
  看板 = 一个 agent，不占顶层 nav，正确隔离轴是 `role:kanban-manager` 过滤，已由 world 读模型
  surface 到 Identities/agents 列表）。
- **会话内 tab**（`session_tabs/0`，Layer-3）：一个 session **bind 一块板后**多一个 kanban tab；
  `condition` = `BoardConfig.session_bound?/1` 文件读，world 按当前 session 算可见性、通用渲染
  （没装 kanban 就没这 tab）。kanban 保留这条 plain `session_tabs/0`——与 nav 一样，2026-06-30 起
  它也是 World 层 `Ezagent.World.UISurfaceProvider` duck-type 读的约定（非 core callback）。
- **board 绑定 + 连接器配置**（经 dispatch 的动作，UI 触发）：`kanban.bind_session`（绑会话→
  触发 §2 的 materialize）、`kanban.set_board_config`（写 github_repo + miro 板名）、
  `kanban.sync_*` 等——这些是 Behavior action，world 的 conversation/workspace LV 经 dispatch
  调它们（caller 身份 + caps 来自登录用户）。
- **routing 面板**：会话内已 materialize 的 agent 之间的接力路由，pm 大脑生产环境经
  Orchestrator 现有 MCP 工具 `define_rule_set_rule` 配规则；`relay_routing.ex` 是同一条规则
  形状的确定性 seed 入口（供 e2e gate + 日后按需直调）。

---

## 5. 哪些当前还得靠 seed（代码），后续需开发的配置 UI

下面这些目前**只有代码 seed 路径，没有 UI**——要新建/调整一个 role-agent 的能力，现在得改
代码或跑 CLP/CLI。这是**已知的配置 UI 缺口**，列在这里供后续排期：

| 当前靠代码 seed 的东西 | 在哪 | 后续该开发的配置 UI |
|---|---|---|
| **role recipe 体**（name/passive/behaviors/requested_caps/skills/config） | plugin `roles/0`（如 `kanban_manager_recipe/0` / `pm_coordinator_recipe/0`） | **Recipe 编辑器 UI**：让运营在界面上定义/改一个 role 的请求 cap 集 + skill + persona + config，不必改 `roles/0` 代码重新 build |
| **默认 agent recipe + 模板 seed**（pm / dev-together：recipe ConfigObject + `cc × <role>` AgentTemplate） | `Ezagent.Agent.DefaultRecipes`（role-as-data）+ `Ezagent.Agent.DefaultRecipeSeed` 统一入口（recipe-seed 在 domain_agent boot 跑、template-seed 在 cc plugin `after_boot` 跑）。2026-06-30 refactor：取代了旧的两个 per-plugin seed（kanban 的 pm seed + 已删 `ezagent_plugin_dev_together` 的 dev seed） | **默认 agent 配置 UI**：指定某 role 用哪个 flavor、project_cwd、哪个会话的默认大脑是谁 |
| **kanban-aware materialize wrapper**（仅 pm 的 board-scoping 半边） | `EzagentPluginKanban.PmCoordinatorSeed`（refactor 后**瘦身**到只剩 `role_name/0` + `materialize/4`：per-session 触发 + 把 pm 的 kanban caps board-scope 到具体 board）。dev-together **没有** plugin wrapper——经通用 `materialize_by_role/4` 按名 materialize | 同上——wrapper 现在硬编码了 board-scope 映射（`%{Behavior.Kanban => board_uri}`），应让这层成为 UI 可配的「会话默认 agent 编排」 |
| **cap grant**（把 recipe cap 授到一个 agent 实例） | `GrantRecipeCaps` mix task（materialize 时自动调，或 operator 手跑） | **Cap 授予 UI**（admin）：在界面上给某 agent 实例授/撤 recipe cap，含 board-scoping（instance_overrides）的可视化——现在 board-scope 映射是 seed 代码里写死的 `%{Behavior.Kanban => board_uri}` |
| **接力路由规则 wiring**（dev→pm relay-back 等） | `Connectors.wire_relay_back_routing` + `RelayRouting`，bind 时 seed | **路由规则编辑器**：可视化「会话内 from(X)→Y / marker→Y」规则。pm 大脑已能经 MCP `define_rule_set_rule` 配，但**人**直接配规则的通用 UI 还没有 |
| **role recipe 注册本身** | boot 期 `RecipeRegistry.register/1`（框架代登记 `roles/0`） | 若要支持**运行时**新增 role（不改代码/不重启），需一个 recipe 注册 UI + 持久化 |

判断「这块是不是只有 seed」的简单标准：如果要改它必须改 `.ex` 文件并重新 build/boot，那它
就还是代码 seed，是一个待补的配置 UI 缺口。

---

## 6. CLI 逃生口（没 UI 时怎么操作）

所有 UI 能做的、以及 UI 还没覆盖的，都能经 CLI 走 sanctioned dispatch（CLI ↔ LV runtime
同构，跑在同一个 BEAM 里，过同样的 CapBAC + 审计）：

```bash
# 通用 dispatch 逃生口（T7f）：调 per-instance role-mounted behavior（kanban/github/…）
#   静态 BehaviorRegistry tree 不暴露这些动作，dispatch 动词直达
mix ezagent dispatch <target-uri> --action <behavior.action> --args '<json>'
# 例：让某 agent 在某块 board 上加节点
mix ezagent dispatch entity://team-a/agent/board-1 --action kanban.add_node \
    --args '{"parent_id":"","title":"新需求"}'

# 会话发消息（T7h：建真 %Message{} + @mention 解析，触发会话内接力/路由）
mix ezagent session send --session <session-uri> --text "@pm 看一下这块"

# 授 recipe cap 到一个（已 materialize 的）agent 实例
mix ezagent.agent.grant_recipe_caps pm-coordinator --agent-uri entity://team-a/agent/pm-coordinator-flow1

# 直接建一个 agent（flavor × role）
mix ezagent.agent.create ...
```

caller 身份 + caps 来自 `EZAGENT_USER_TOKEN` + `EZAGENT_ENTITY_URI`（per-process override），
in-dispatch CapBAC 跑在 caller **自己**的 cap 上（跟 UI 同权，无提权）。

> **铁律（Allen 2026-06-03）**：不要用裸 `:rpc.call` + `binary_to_term` / `SpawnRegistry.spawn`
> / 任意 eval 去「把它弄活」——那绕过授权（create entry + CapBAC）且有副作用。RPC 只用于
> **只读 forensics**。operator 动作走 `mix ezagent <verb>`（dispatch → authz）。缺哪个 sanctioned
> CLI 路径，那就是要修的 bug，别绕过。

---

## 速查：从 plugin 到「一个 agent 会用它」要发生什么

1. plugin `roles/0` 声明 role recipe（请求哪些 behavior + cap + skill + config）。
2. boot：框架 `RecipeRegistry.register/1` 登记 recipe；`DefaultAgentSeed` 写 `cc × role` 模板。
3. 触发点（看板流 = `bind_session`）：`SessionAgentMaterialize` per-session spawn 这个
   role-agent（拿到 `entity://<ws>/agent/<role>-<sess>` URI），凭证 cascade 进 config_dir。
4. spawn 成功后 `GrantRecipeCaps` 把 recipe 的 least-priv cap 授到这个 live 实例
   （pm 的 kanban cap 经 `instance_overrides` board-scoped）。
5. 此时 agent 持有 cap，能经 dispatch / CLI / 它自己的 cc 大脑驱动 plugin 的动作；
   会话内接力靠声明式路由规则把产出路由到下一棒。

例子全链路：pm-coordinator（看板默认大脑）+ dev-together（开发块 workflow recipe，住
domain_agent，按 role 名 materialize），bind 一块 board 到一个会话时一起落地，dev→pm 的回路由
relay-back 规则在 bind 时一并 wire。
