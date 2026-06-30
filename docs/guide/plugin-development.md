# 开发一个新 plugin

> 这份文档讲**再开发一个 ezagent plugin 的一般步骤 + 注意事项**：plugin 的骨架长什么样、
> Behavior 怎么写、代码该住哪一层、有哪些硬禁忌、入站/出站/接力怎么接、cap 怎么声明、
> 测试要过哪些 gate。读者是**第一次给 ezagent 加 plugin 的工程师**。
>
> 它承接 `docs/guide/extending-agents-without-violating-the-architecture.md`（那篇讲
> 「新 agent 类型 = role × flavor，不是新 Kind」「平台机制要跟业务逻辑可分离」两条红线）。
> 本篇讲的是**怎么落地一个 plugin**；那篇讲的是**别把它做歪**。两篇一起读。
>
> 配套：写代码前 load skill `ezagent-developer`（权威原则 P1-P27 + CI gate）。
> 真正的参考实现是 `apps/ezagent_plugin_kanban` 和 `apps/ezagent_plugin_github`——
> 本文所有例子都来自它们，照着抄不会错。

---

## 0. 先想清楚：你要加的是 plugin 吗？

加东西之前先问一句「我要加的是什么」，三种常见误判：

- **「我要加一种新 agent」** → 不要建新 plugin 也不要建新 Kind。新 agent 类型 =
  在通用 `Ezagent.Entity.Agent` 上挂一个 **role × flavor**（一个 recipe）。recipe 有两条
  注册路（都落进 `RecipeRegistry`）：plugin 自身的 native agent 经 plugin `roles/0`；通用
  cc-headless agent（如 pm-coordinator / dev-together）经 `Ezagent.Agent.DefaultRecipeSeed`
  统一入口（domain_agent，非 plugin）——详见 `agent-plugin-configuration.md`。见
  `extending-agents-without-violating-the-architecture.md`。
- **「我要加一种新数据资源」** → `resource://` 是纯 FS 数据引用，**绝不能**是能起活的
  Kind / GenServer（`mix ezagent.arch.scan` 的 `resource_kind_as_genserver` AST gate
  永久锁死）。看板就是反面教材的正面解：board 数据住在 agent 的 snapshot slice 上，
  不是 `resource://` Kind（kanban-as-role，K5）。
- **「我要加一组动作 + 它的出/入站集成」** → 这才是 plugin 的正确场景。下面讲怎么做。

一个 plugin 典型由这几块组成（以 kanban 为例）：

```
apps/ezagent_plugin_kanban/
├── lib/ezagent_plugin_kanban/application.ex   # OTP app + Ezagent.Plugin 契约（声明，不调用）
├── lib/ezagent/behavior/kanban.ex             # Behavior：action 声明 + handle_<action>/2
├── lib/ezagent/behavior/kanban/connectors.ex  # 出站连接器实现体（压主模块 LOC）
├── lib/ezagent/behavior/kanban/relay_routing.ex  # 接力路由规则的确定性 seed 入口
├── lib/ezagent_plugin_kanban/board_config.ex  # 本地辅助状态（per-board 配置文件）
├── lib/ezagent_plugin_kanban/miro_sync.ex     # 出站 sidecar（监督树下的 GenServer）
└── lib/ezagent_plugin_kanban/pm_coordinator_seed.ex  # 默认 agent 的 seed wrapper
```

---

## 1. plugin = 一个 OTP app

plugin 是一个 umbrella app（`apps/ezagent_plugin_<name>`），它的 application 模块同时
`use Application`（OTP plumbing）和 `use Ezagent.Plugin`（声明契约）：

```elixir
defmodule EzagentPluginKanban.Application do
  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)   # 唯一入口

  @impl Ezagent.Plugin
  def plugin_info do        # ← 唯一 REQUIRED 的 callback
    %{slug: "kanban", name: "Kanban", description: "...", version: "0.1.0"}
  end
end
```

**核心心智：声明，不调用**（plugin 契约，P-plugin 组）。你只声明 `behaviors/0` /
`roles/0` / `children/0` / `config_surface/0` …，框架的 `Ezagent.Plugin.boot/1` 代你
注册进各种 `*Registry`——**作者永远不碰 `*Registry`**。`:ezagent_plugin_check` 编译器是
非旁路的强制 gate，声明形状不对编译就红。

### Ezagent.Plugin 的 callback 全集

只有 `plugin_info/0` 是必须的；其余都有 `defoverridable` 默认（`[]` / `nil` / `:ok`），
按需覆盖：

| callback | 默认 | 干什么 |
|---|---|---|
| `plugin_info/0` | —（必须） | slug / name / description / version |
| `behaviors/0` | `[]` | 静态 `{kind, action, behavior}` 声明（**role 模型下基本不用**——见 §4） |
| `roles/0` | `[]` | role recipe 列表（map），boot 经 `RecipeRegistry.register/1` 登记 |
| `kinds/0` | `[]` | 自建 Kind 模块（绝大多数 plugin = `[]`，复用 `Entity.Agent`） |
| `agent_flavors/0` | `[]` | 新 flavor 声明（native / cc / cc-headless 已内置，一般不加） |
| `adapters/0` | `[]` | ExternalMirror 出/入站 adapter（`{adapter, binding}` 或裸 pull adapter） |
| `routing_tables/0` | `[]` | 声明式路由表 |
| `resource_types/0` | `[]` | `resource://` FS 资源类型 |
| `config_surface/0` | `nil` | world Plugins 页的配置入口（`%{kind: :route, path:, label:}`） |
| `children/0` | `[]` | plugin 自己的监督树子进程（poller / sync 的 Registry + DynamicSupervisor） |
| `after_boot/0` | `:ok` | boot 后回调（如 seed 模板）。**必须 boot-safe**：失败降级成 warning+telemetry，绝不 crash boot |
| `spawns/0` | `[]` | **保留，必须返 `[]`**：plugin 不许注册 scheme 级 spawn fn |

> **World UI surface（nav_surfaces / session_tabs）——2026-06-30 起不是 core Plugin 契约 callback。**
> 它们是 **World-UI 概念**（左栏一级 nav 入口 / 会话内 Layer-3 tab），消费方只有 World。所以搬到了
> **World 层**：plugin 若想贡献 World UI surface，就定义**普通 public 函数**（无 `@impl`）
> `nav_surfaces/0` / `session_tabs/0`，World 的 `Ezagent.World.UISurfaceProvider` **duck-type**
> 读它们（core `Ezagent.Plugin` 不认识这俩，零 compile dep）。`config_surface/0`（喂 `/plugins`
> 配置页）仍是 core callback。

---

## 2. Behavior 怎么写（developer surface = `use Ezagent.Lifecycle`）

> ⚠️ **重要更正**：开发者写 Behavior 用的是 **`use Ezagent.Lifecycle`**，
> **不是** `use Ezagent.Behavior`。后者是 Lifecycle 宏编译下去的**内部引擎**
> （R/B/K），developer/plugin/domain 代码永不直接写它——`mix ezagent.check_invariants.lifecycle`
> 这条 gate 会 HARD-fail CI 如果开发者层重新引入 `use Ezagent.Behavior` /
> `init_slice` / `def state_slice` / `invoke/4`。kanban 和 github 两个参考实现都是
> `use Ezagent.Lifecycle`。写 Behavior 前先读 `references/lifecycle.md`。

### 2.1 两容器状态模型（核心思想）

Lifecycle 模块持两个状态容器，**永远分开**：

| | `state`（持久） | `transients`（易失） |
|---|---|---|
| 持久化？ | 是——框架自动 snapshot | **永不**——没有任何序列化路径 |
| 放什么 | domain 数据（节点树、配置、caps） | PID / ref / ETS handle / port / 子进程 handle / monitor ref / 缓存连接 |
| 谁建 | `create/1`（首次存在）+ handler 的 `{:set, k, v}` effect | `activate/2`（每次启动重建）+ `{:set_transient, k, v}` effect |
| 怎么读 | `ctx.read.(key, default)`（也支持 `ctx[:read]`） | `ctx.transients[key]` |
| 重启后还在？ | 在（durable） | 不在——`activate` 从 `state`（+外部真相源）重建 |

这套设计**从构造上**杀掉了「fresh 能跑、cold-restart 跑不了」这类最贵的 bug
（#110/#113/#114）：transient 没有别的家可放，`activate/2` 是唯一重建点、且**每次**进程
启动都跑（fresh spawn / supervisor restart / 从快照冷加载），不可能漏。

### 2.2 hooks

```elixir
defmodule Ezagent.Behavior.Kanban do
  use Ezagent.Lifecycle

  # ---- action 声明（宏；grammar 见 §2.3）----
  action(:add_node, args: %{parent_id: :string, title: :string},
    returns: %{id: :string}, caps: [:add_node], modes: [:call], description: "新增节点")

  # ---- create/1：URI 首次存在（历史上跑一次）。建初始 PERSISTENT state，禁建 transient ----
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{tree: empty_tree()}}

  # ---- activate/2：每次进程(重)启。重建所有 transient + 自愈（orphan-reap）。可选 ----
  # def activate(state, ctx), do: {:ok, %{bridge: rebuild_subprocess(state)}}

  # ---- handle_<action>/2：每个声明的 action 一个。纯 (args, ctx) 函数 ----
  @impl true
  def handle_add_node(args, ctx) do
    # 读 state：ctx[:read].(:key, default)；写 state：返 {:set, key, value} effect
    {:ok, %{id: id}, [commit(new_tree)]}      # {:ok, result, [effect]} | {:error, reason}
  end

  # ---- post_handle/4：handler 之后、effect 执行前。审计 / 注入 effect（见 §6 接力）----
  # ---- handle_signal/2：非 action 的 GenServer 消息（:DOWN / PubSub / 自投递）----
end
```

可选 hooks 还有 `activated/2`（ReadyGate flip 之后跑，仅给「广播可达性、邀请 peer
:call」用）、`pre_handle/3`（handler 前做 authz / 改参）、`deactivate/2`（优雅停，实体
仍存活）、`destroy/2`（永久删）。绝大多数 Behavior 只需要 `create/1` + 一堆 `handle_*`。

`ctx` 由框架注入（作者不 plumb）：`:self_uri`、`:caller`、`:reply`、`:caps`、
`:read`、`:transients`、`:siblings`（经 `reads_siblings/0` opt-in）。

### 2.3 action 宏 grammar

```elixir
action(:name,
  args:        %{<字段> => <type_spec>},   # 必填，校验入参
  returns:     %{<字段> => <type_spec>},   # 必填，校验 handler 返回
  caps:        [:name],                    # 选填，默认 [name]；多 cap 见 §7
  modes:       [:call],                    # 选填，默认 [:call]；:call / :cast / :call_stream
  description: "人读字符串")               # 选填，进 /admin/caps + CLI tree + CmdK
```

`args` / `returns` 用 `Ezagent.InterfaceValidator` 的 type tuple：`:string` / `:integer`
/ `:map` / `:uri`（**只匹配 `%URI{}` 结构体，拒裸字符串**，Decision #92）/ `{:list, :uri}`
/ `{:option, :string}` / `%{<字段> => <ty>}` 等。

### 2.4 effect 词汇表

handler 返回 `{:ok, result, [effect]}`，effect 是纯数据，框架按固定桶序执行
（`State → Halt → Saga → Dispatches → Notifies → Events → Terminations`）：

| effect | 形状 | 意思 |
|---|---|---|
| `:set` | `{:set, key, value}` | 改持久 `state`（框架 snapshot） |
| `:set_transient` | `{:set_transient, key, value}` | 改易失 `transients`（**永不** snapshot；Lifecycle 新增） |
| `:emit` | `{:emit, event, payload}` | append 到 EventLog（审计 + EventSubscriber） |
| `:dispatch` | `{:dispatch, %Ezagent.Cmd{}}` | 跨 Kind dispatch；框架重入 Router（见 §6） |
| `:notify` | `{:notify, topic, payload}` | `Phoenix.PubSub.broadcast` fire-and-forget（视图 fan-out 用） |
| `:effect` / `:effect_returning` | `{:effect, mfa, args}` / `{..., bind_as: :n}` | 副作用；`{:ref, :n, [path]}` 取回值 |
| `:saga` | `{:saga, %SagaRunner.Saga{}}` | 线性 saga + best-effort 补偿 |
| `:terminate` | `{:terminate, :self \| URI}` | reply 落地后调度终止 |
| `:halt` | `{:halt, reason}` | 短路，余下 effect 全跳过，不 snapshot |

> 出站 IO 同步拿结果的场景（如 kanban `Connectors` 调 github 后要拿 issue number 拼回
> 返回值再决定是否 commit），`{:ref}` 替换表达不了这层逻辑，**允许在 Kind 进程内同步调**
> （对齐 `Behavior.Chat.handle_send` 内联 dispatch 先例）；但**改树/写 state 仍只能经
> effect**。kanban 全 Behavior 收口到唯一一个 `commit/1` 产 `{:set}` effect。

---

## 3. 三层边界：你的代码住哪一层？

```
core    （ezagent_core）   — R/B/K 引擎、Router、CapBAC、URI、可靠性原语。你基本不碰
domain  （ezagent_domain_*）— 跨 plugin 复用的编排/身份/会话/agent 机制
plugin  （ezagent_plugin_*）— 你的扩展
```

判定法则 **P9 —「读什么数据决定 tier 归属」**：

- 你的 Behavior 只读/写**自己实例的 slice** → 住 plugin。
- 你的机制要被**多个 plugin 复用**（否则会 byte-duplicate） → 提到 domain。
  反面例子：`Ezagent.Agent.DefaultAgentSeed` / `SessionAgentMaterialize` /
  `GrantRecipeCaps` / `DefaultRecipeSeed` 住 `ezagent_domain_agent`——pm-coordinator +
  dev-together 这两个通用 cc-headless agent 的 recipe + 模板 seed 否则会在两个 plugin 里
  逐字复制这段组合（2026-06-30 refactor 前确实如此：pm 在 kanban、dev 在已删的
  `ezagent_plugin_dev_together`），`FF-1 cross_file_duplicate_fn_groups` arch gate 明令禁止
  这种 fork 堆积，所以收口到 domain 的一个统一入口。
- 协议特定代码（HTTP / gh CLI / Miro API）只住 adapter / 出站 helper（**P12**），
  Behavior 本身保持协议无关。

**跨 plugin 零编译依赖**（守不变式 #8）：plugin 不许 `deps` 另一个 plugin。要调外
plugin 的能力，两条 sanctioned 路：

1. **经 dispatch 调系统 gateway**（kanban 调 github：`Ezagent.Invocation.dispatch` 到
   `entity://system/agent/github_gateway` 的 `github.<action>`，系统身份）。
2. **经 role 名 + RecipeRegistry 拿 recipe**（kanban materialize `dev-together` role：
   `SessionAgentMaterialize.materialize_by_role("dev-together", …)`，靠名字解析，零编译依赖）。
   dev-together 的 recipe 不在任何 plugin 里——它住 `Ezagent.Agent.DefaultRecipes`、经
   `DefaultRecipeSeed` 统一入口 boot-seed（2026-06-30 refactor，dev-together = 一份
   workflow/skill recipe，**不是** plugin）；kanban 仍只靠**名字**解析它，故零编译依赖照旧。
   recipe 里引用外 plugin 的 Behavior 时用**字符串模块名**（`"Ezagent.Behavior.Github"`），
   grant 时再 loud 解析成 module，解析不到就 fail-loud 绝不静默。

---

## 4. role 模型：behaviors 怎么挂到 agent 上

绝大多数 plugin **不声明 `kinds/0`**（默认 `[]`），也**不用静态 `behaviors/0`**。正确做法
是经 `roles/0` 声明一个 **recipe**，框架 boot 时 `RecipeRegistry.register/1` 登记；
Behavior 经 RF-1 `per-instance` 挂在通用 `Entity.Agent` 宿主上：

```elixir
@impl Ezagent.Plugin
def roles, do: [kanban_manager_recipe()]

def kanban_manager_recipe do
  %{
    name: "kanban-manager",
    passive: true,                              # 被动数据 actor：不可 @ / 不可 :join / 不收 chat
    behaviors: [Ezagent.Behavior.Kanban],       # 经 role per-instance 挂载（仅 1 个；连接器动作也在它里声明）
    requested_caps:                             # 每动作一个 cap-template MAP（不是裸 atom）
      for a <- Ezagent.Behavior.Kanban.actions(), do: %{behavior: Ezagent.Behavior.Kanban, action: a},
    config: %{                                  # ← Layer-2 业务数据（见下）
      stages: [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr],
      ci_stage: :pr, import_default_stage: :feature
    }
  }
end
```

注意点：

- `requested_caps` 是 cap-template **map** `%{behavior:, action:}`，**不带 `kind`**——
  kind 轴是 materialization 轴，由 flavor 的 `CapMint` 注入（native → `:agent`）。
  硬写 `kind: :kanban` 会让 role×native 路必拒。
- Behavior 里声明 `required_caps/0`（kind 轴写 `:any`，运行时按宿主 type_name 替换成
  `:agent`）+ `data_owner/1`（per-instance 用 `:no_owner`，per-node 授权在 handler 内查）。
- **业务语义不进 Behavior 代码**（taxonomy 红线）：kanban 的 9 棒接力链 + CI 触发棒 +
  导入默认棒是 business data，住 recipe `config`，Behavior 运行时经
  `Shared.stages(ctx)` 读回。Behavior 本身是通用看板**机制**（列/卡/stage/认领/状态机），
  零具体阶段名。这正是「平台机制可分离于业务逻辑」红线的落地。

---

## 5. 入站触发：`bind_session → connectors` 模式

「入站」= 外部世界（webhook / poller / 另一个 agent 的产出）触发你的 plugin。看板的范式：

1. 一个动作 **`bind_session`** 把 plugin 实例绑到一个会话（写 per-board 配置）。
2. 绑定时**反应式地**起入站基建：kanban `Connectors.bind_session` 在写完配置后
   `reconcile_pr_sync/3`——若 repo+session 俱全，经 dispatch 让 github gateway 起一个
   open-PR poller（poller 进程归 github 插件的监督树，跨插件零编译依赖）。
3. poller 周期轮询 → 系统身份 dispatch 回 `kanban.register_pr`，把 PR 挂到节点。

入站的铁律（这是 ezagent 比普通 Phoenix app 多出来的认知负担）——**每个投递点都要问
「这里失败了谁会知道」**：

- 消息没人接收 → telemetry 出口 + DLQ unroutable + 显式 reject，**绝不静默丢**。
- actor 还没 ready 收到 dispatch → ReadyGate 接住（`:cast` 进 PendingDelivery /
  `:call` fail-fast）。
- 辅助入站（poller dispatch）失败**不该**让用户的 `bind_session` 失败 → 只 log+telemetry，
  不回传错误（失败 surface 在 `Logger.warning`，不是静默丢）。
- 重复 webhook → `register_pr` 自幂等（按 `(repo, node_id, pr)` 去重）。

---

## 6. 出站 / 接力：`dispatch` effect + 路由规则

「出站」= 你的 plugin 把消息送出去触发下一棒。两个层次：

**(a) post_handle 注入 dispatch effect**：kanban 在认领/状态/挂 PR 等接力动作成功后，
`post_handle/4` 往本看板绑定的会话注一条公告（`"[kanban:<event>] by <caller>"`），以
`{:dispatch}` effect 重入 `session.send`：

```elixir
@relay_actions [:claim_node, :set_status, :register_pr]

@impl Ezagent.Lifecycle
def post_handle(action, result, effects, ctx) when action in @relay_actions do
  case board_session(ctx) do
    nil -> :cont
    session_uri ->
      text = relay_text(action, ctx)        # 带机器可读标记 [kanban:<event>]
      {:ok, result, effects ++ Shared.session_dispatch(session_uri, ctx[:self_uri], text)}
  end
end
def post_handle(_a, _r, _e, _c), do: :cont
```

> **P14 — Dispatch 是 Kind 之间唯一的路**：永远经 `{:dispatch}` effect / Router，
> **绝不** `Phoenix.PubSub.broadcast` 到 inbound topic（事故 2.1 根因）。消息只做触发器，
> 节点细节由被唤醒的 agent 经 `get_tree` 读真相源——**消息不做数据源**。

**(b) 路由规则把公告路由到下一棒 agent**：`relay_routing.ex` seed 一条**现有** core 路由
规则（零 core 改动，纯组合 `Ezagent.Routing.Matcher` + `RuleStore`）：

```elixir
# marker 触发：本会话内 + 携带 [kanban:<event>] 标记 → 下一棒
{:and, [in_session(session_uri), text_contains("[kanban:claimed]")]} → [receiver]

# sender-locked relay-BACK：本会话内 + sender 是 dev → 路由回 pm（不靠 @mention parse，靠路由规则）
{:and, [in_session(session_uri), from(dev_uri)]} → [pm_uri]
```

接力关系是**配置先行**：bind 建立 kanban-flow 会话时，pm + dev-together 一起 materialize
进**这个**会话，此刻 wire 路由规则。规则是声明式配置，不是 dispatch 代码里的 special-case。
seed 后要 `RuleStore.load_into_registry(table)` 把 DB 规则水合进 ETS（Resolver 读 ETS）。

---

## 7. caps 声明

- **action 的 `caps:`**：默认 `[action_name]`；一个动作多授权轴时写 `caps: [:foo, :bar]`。
- **Behavior 的 `required_caps/0`**：每动作一个 `:any`-kind 的 `%Capability{}`，kind 轴运行时
  按宿主替换成 `:agent`（kanban / github 都这么写）。
- **`data_owner/1`**：per-instance cap 收口用 `:no_owner`；per-node / per-row 的细授权在
  handler 内查（kanban 改一个节点要 `ctx.caller == node.owner` 或持 wildcard admin cap）。
- agent 怎么**拿到**这些 cap（recipe → grant → materialize）是另一篇
  `agent-plugin-configuration.md` 的事，这里只管**声明需要什么 cap**。

---

## 8. 测试 + 全 gate 集

Lifecycle handler 是纯 `(args, ctx)` 函数，可直接在 ExUnit 调（mock `ctx.read`）：

```elixir
ctx = %{self_uri: uri, caller: uri, reply: :none,
        read: fn k, d -> Map.get(state, k, d) end, transients: %{}, caps: MapSet.new()}
assert {:ok, %{id: _}, [{:set, :tree, _}]} = Ezagent.Behavior.Kanban.handle_add_node(args, ctx)
```

冷重启不变式用 `Ezagent.LifecycleCase.assert_transients_rebuilt/2`：把 Kind 驱到非平凡
state → brutal-kill（`Process.exit(pid, :kill)`，跳过 deactivate/destroy）→ 同 URI demand-spawn
→ 断言 state 复原 **且** transient 重建成 LIVE 等价物（无残留死 PID）。

**提交前必须全绿的 gate**（任一红 → 不 tag，暂停）：

```bash
mix compile --warnings-as-errors        # 含 :ezagent_plugin_check 编译器（非旁路）
mix test                                 # 单元 + 集成 + e2e
mix ezagent.check_invariants             # ~17 条跨 PR 架构不变式
mix ezagent.check_invariants.lifecycle   # 禁 developer 层 use Ezagent.Behavior + §11 命名 lint（NP-1/2/3）
mix ezagent.arch.scan                    # AST gate（resource_kind_as_genserver、FF-1 跨文件重复 等）
mix ezagent.uri_query.scan               # 禁裸 ?action= 串拼，必须 with_action
mix ezagent.doc.scan                     # 文档/双语一致性
mix format --check-formatted             # 只格式化你改的文件，别吸收历史格式债
```

> **§11 grep gate（禁忌速查）**——plugin / domain 代码**禁止** import / 直调：
> `Ezagent.EventLog.append`（用 `{:emit}`）、`Ezagent.SnapshotStore.*`（框架写）、
> `Ezagent.Kind.StateRebuilder`、`Ezagent.EventSubscriber` 机制、`Ezagent.Router` internals
> （只有 transport adapter 能调 `dispatch/1`）、`Ezagent.SagaRunner.execute/2`（用 `{:saga}`）、
> handler 里的 `Ezagent.Invocation.dispatch/1`（用 `{:dispatch}`）、handler 里的
> `Phoenix.PubSub.broadcast/3`（用 `{:notify}`）、`Ezagent.Kind.terminate/1`（用 `{:terminate}`）、
> 直接碰 `slice` map（用 `ctx[:read]` 读 / `{:set}` 写）。CI grep gate 命中即红。

---

## 9. LOC budget

- `ezagent_core` 有硬 LOC budget（target ~870，red line 1100，每模块有 cap，
  详见 `ARCHITECTURE.md §14`）。**写 core 才受这条约束**——但加 plugin 通常**不该**改 core。
- plugin 自身没有 core 那样的硬数字 cap，但 **FF-1 反 fork** 约束很硬：跨文件重复的函数组
  （`cross_file_duplicate_fn_groups` arch gate）会红——共享逻辑提到 domain，别在每个
  plugin 里复制粘贴（kanban 的 `Connectors` 把出站实现体从主 Behavior 拆出来压主模块 LOC，
  是同一精神的 plugin 内应用）。

---

## 速查清单（开一个新 plugin 前过一遍）

- [ ] 我加的真是 plugin 吗？（新 agent = role×flavor；新数据 ≠ live Kind）
- [ ] application 模块 `use Application` + `use Ezagent.Plugin`，`start/2 → boot/1`，写 `plugin_info/0`
- [ ] Behavior 用 `use Ezagent.Lifecycle`（不是 `use Ezagent.Behavior`），先读 `references/lifecycle.md`
- [ ] 持久数据进 `create/1` + `{:set}`；PID/ref/ETS 进 `activate/2` + `{:set_transient}`
- [ ] behaviors 经 `roles/0` recipe per-instance 挂 `Entity.Agent`，不建 Kind、不用静态 `behaviors/0`
- [ ] 业务语义（阶段链等）住 recipe `config`，不进 Behavior 代码
- [ ] 跨 plugin 零编译依赖：dispatch 到 gateway / 经 role 名 materialize / cap behavior 用字符串名
- [ ] 每个投递点问「失败了谁会知道」：telemetry + DLQ + 显式 reject，绝不静默丢
- [ ] 接力用 `post_handle` 注 `{:dispatch}` + 声明式路由规则，绝不 PubSub.broadcast inbound
- [ ] 全 gate 绿（compile-w-a-e / test / check_invariants(+lifecycle) / arch.scan / uri_query.scan / doc.scan / format）
- [ ] §11 禁忌一条没碰（grep 自查）
