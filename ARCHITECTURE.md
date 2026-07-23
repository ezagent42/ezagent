# Ezagent Kind Runtime — 架构设计 v0.4

> **Status**: 架构骨架冻结,Phase 0-1 完成(`phase0` + `phase1b` tags),Phase 1 sign-off,实施期决策 Decision #84-#87 入账
> **Last updated**: 2026-05-15(Phase 1 完成 + §12.8 重写)
> **Owner**: Allen / ezagent42
> **Changes from v0.3**: 顶层加"Ezagent 是 router 不是 req/resp app"framing;Resource Kind 加"shared referent needs identity"判定原则;Template 升级为双层模型(Class / Instance,Workspace 是 Instance 示范);加 reliability primitives 三件套(ReadyGate / PendingDelivery / Idempotency);RoutingRegistry 加 `put_new` 语义(unique-key only)+ `reverse_index` 反查;Matcher 边界按"读 core 数据 → core"画线;Plugin 判定原则显式化;5 个事故坑全部 design-in;LOC 校准 475/595 → ~870 → 920;feishu-cc 切片 4 张参考表入 spec;ES 从 deferred 改为已决不做;dev 两轮 review 闭环
> **Impl-period 更新**: §5.7.4 承认 Kind 生命周期两条等价实现路径(宏 / 共享 Server,Decision #84);**§12.8 重写反映 "Channel = MCP + 1 capability" 协议层简化**(Phase 1b 实证,Decision #86);Phase 2 加 K-path Behavior 模型 / `handle_kind_message` Kind.Server 转发器 / `ctx.kind_module` + `ctx.self_uri` 注入 / MessageStore 单一真相源 / `:uri` primitive / `session://` scheme + 两条 PubSub `:events` 通道(Decision #88-#94);**Phase 3 加 RoutingRegistry 第 3 个 Registry 家族 / Matcher 5 leaf + JSON serde / Resolver 双层 fan-out / message_routings 关联表(保 #40 identity invariant 同时支持多 session) / Identity Behavior in slice(admin_caps 从 module function 迁 slice state)/ `cap_for_action/3` helper / dispatch step 5.5 hard flip(`:stub_grant` 永久死亡)+ check_invariants #9 #10 / Reply 契约 D8 / Bridge↔Agent floating + LV @-dropdown 只列 session 成员 / push_to_claude meta 必含 "session"(Decision #95-#104)**;Decision Log 当前到 #104

---

## 1. 项目定位

**Ezagent 是一个 socialware platform** —— 它的 runtime 是一个 message router,在 router 之上 host 可 install 的 **socialware**(human+program hybrid FLOW)。一个 session 是一个 host;它 **installs** 一个或多个 socialware definitions(config-as-data,`socialware:<name>`),socialware 把 **bases**(capability substrates)+ 一个 **shape**(flow-specific behavior+recipe)compose 进 session 的 `:kind_base` union。Operator 打开一个 socialware(不是"打开 base"),在 shared、observed 的 turn surface 内跟 agents 协作,可 hold / settle / approve / take over program output 在它到达 external audience 之前 —— human-in-the-loop gating 是 first-class,不是 add-on。

Router 层把五件事正交拆开——**寻址 / 调用 / 执行 / 行为 / 权限**——用 Phoenix 的 transport 层作为外部入口,Registry 作为内部路由,把它们缝合。**系统形状是 IRC-style multi-tenant message bus over Phoenix transport**——actor 间通过 Message 通信,routing rules 决定每条 Message 的 receivers,Behavior 处理 Invocation 做出反应。Session = routing context owner(类似 IRC channel);Agent / User = Principal(类似 IRC nickname);Message = Entity-Entity 通信的 envelope。

> **概念 taxonomy 详见** `docs/socialware-concepts.md`(base / socialware / fixture 三层)+ `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`(4 carrier layers + anti-leak red lines)+ GLOSSARY.md §2 术语表。本节只给 router 层的 framing;socialware 概念在 §3 + §9 展开。

### 1.1 不是什么

- **不是 framework** — 是一套约定 + 薄胶水(`ezagent_core` ≈ 920 LOC)+ Phoenix 的 transport 层
- **不是 web 应用** — 但用 Phoenix 的 transport 子系统(Endpoint / Socket / Channel / Plug / PubSub / Presence)
- **不是 fullstack Phoenix** — 不用 Controller / View;LiveView 用作早期内部 IM 前端 dogfood + 未来可选 admin dashboard
- **不是 mixin 系统** — 一切扩展通过运行时 Registry
- **部署形态** — **单文件 SQLite + 单 BEAM 节点 = 一个目录**,可部署到 Raspberry Pi 级边缘硬件。launchd / systemd 托管(v0);v0.x+ 支持 federation(独立节点 + cross-node 消息协议)

### 1.2 跟 typical Phoenix app 的两条核心差异

Ezagent 的多数特殊设计(投递保证、`put_new`、零匹配出口、幂等检查、稳定 `type_name`)都源自这两条:

#### 差异 1: Ezagent 是 message router,不是 request/response web app

普通 Phoenix app:请求进来 → handler 跑 → 响应出去。**调用方在等结果**——错误有天然的家(`{:error, _}` 一路冒泡回去),没人能忽略失败。

Ezagent:消息进来 → 路由给 N 个 receiver → 各自反应 → 可能晚点从另一条路回复。**没有"在等结果的调用方"**。所以"消息到达零个 / 错误的 / 没 ready 的 receiver"是一条**合法代码路径,长得跟成功一模一样**——失败默认静默。

**推论:Ezagent 必须人工制造可观测性**——普通 Phoenix app 免费得到的"错误冒泡",router 拿不到。每一处"消息没去到预期的地方"都必须显式变成 telemetry / DLQ / 大声 reject。**默认静默 = 默认有 bug**。

这条差异是 4 个 P1/P2 设计动作的共同根:
- PubSub 先发后订 → ReadyGate + PendingDelivery(§5.7)
- 注册 shadowing → RoutingRegistry.put_new(§5.4)
- 零匹配 → telemetry + DLQ unroutable(§5.5)
- 幂等去重 → Ezagent.Idempotency(Appendix A step 2.7)

#### 差异 2: 持久化层存了代码引用

普通 Phoenix app 持久化的是数据,不是"哪个模块来处理"。**Ezagent 持久化层引用 Kind 模块身份**——`kind_snapshots` 表要知道"这条 state 是哪个 Kind 的"才能 rehydrate。

如果直接存模块名字符串(`"Elixir.Ezagent.Entity.Agent"`),**代码身份和数据耦合**——rename 模块时旧 snapshot 行 orphan,`init/1` 时 `String.to_existing_atom` 会炸。

**推论:用稳定的 `type_name` 作为间接层**(§10.1 schema 用 `kind_type`,KindRegistry 维护 `type_name → module` 映射)。模块改名时映射改一处,snapshot 行不动。

### 1.3 名字债

项目名 Ezagent = **Session Router**(不是 Event-Sourcing Router)。"Event-Sourcing" 是历史误会,**v0 不做 ES**,改用 snapshot 持久化(详见 §10)。完整 ES 不在 v0.x roadmap 上——append-only Message stream 已经具备所有"ES 听起来很美"的优势,不需要承担 ES 复杂度(详见 Decision Log)。

---

## 2. 实现原则

> **本节四条原则的"规则陈述"已迁移到 SKILL 权威集**:`.claude/skills/ezagent-developer/SKILL.md` §Design Principles。本节保留每条的 **rationale / 反例 / Phoenix 子系统取舍表** 作为"为什么 + 实施细节",不再独立列规则。
>
> 旧位置 → 新原则对照:
> - §2.1 少发明,多装配 → **P8**
> - §2.2 Plugin 判定原则 → **P9**
> - §2.3 Phoenix as transport → **P13**
> - §2.4 Adapter pattern → **P12**

### 2.1 少发明,多装配 — rationale(权威规则见 SKILL P8)

整个系统真正属于"我们写的"代码约 920 行,集中在 `ezagent_core`。剩下全部装配 Phoenix / OTP / 生态库。判断标准:**新人加入项目时多懂几个东西还是少懂几个东西**——多记的拒绝,少记的接受。LOC budget 详见 §14。

### 2.2 Plugin 判定 — "读什么数据" rationale(权威规则见 SKILL P9)

**反例为什么这条原则重要**:Matcher 的 `from`/`mention` 类型,如果按"chat 业务边界"放进 `esr_behavior_chat`,那未来一个 `esr_behavior_audit` 或 `esr_behavior_workflow` 也路由 `%Message{}`,就要**依赖 chat plugin** 才能用 `from/1`——破坏 plugin 隔离(SKILL §Design Principles P1 北极星)。按"读 core 数据"原则,这些 matcher 直接在 core,任何 Message-router plugin 直接调用,**不依赖 chat**。

具体 core / domain / plugin 三层边界表见 SKILL §Three-tier project structure。

### 2.3 Phoenix as transport, not fullstack — 子系统取舍(权威规则见 SKILL P13)

Phoenix 在 Ezagent 里扮演 **transport framework** 角色,不是 fullstack framework。具体用与不用:

| Phoenix 子系统 | 角色 | 是否核心 |
|---|---|---|
| `Phoenix.Endpoint` | HTTP/WS 监听入口 | ✅ 核心 |
| `Phoenix.Socket` + `Channel` | WS 长连接 adapter | ✅ 核心 |
| `Phoenix.PubSub` | actor 间消息总线 | ✅ 核心 |
| `Phoenix.Presence` | 跨节点在线状态 | ✅ 核心 |
| `Plug` | 同步 HTTP 入口(webhook、REST API) | ✅ 核心 |
| `Phoenix.Router` | path → Channel/Plug 的 transport routing | ✅ 核心 |
| **`Phoenix.LiveView`** | **server-rendered UI** | ✅ 早期内部 IM dogfood 前端 + 未来 admin |
| `Phoenix.Controller` + `Phoenix.View` | 传统 HTML 渲染 | ❌ 不用 |
| `Phoenix.HTML` form helpers | 同上 | ❌ 不用 |

**LiveView 的两个用途**:

1. **早期内部 IM 前端**(v0)— 在接外部 IM(Feishu/Slack)之前,先用 LiveView 写一个简陋的 IM-style 浏览器界面。**目的不是产品级 UI**,而是让我们尽早 dogfood Ezagent 的 IM-shape 概念(adapter pattern、Behavior schema、`@interface` 生成),验证它跟传统 IM 的差异。这部分代码原在 `ezagent_web_liveview` plugin,**该 app 已并入** `ezagent_plugin_world`(world/admin LiveView surface)+ `ezagent_web`(Phoenix entry + `home_live`);`lv_cli_parity` invariant test enforce 旧 `ezagent_plugin_liveview` 名不再存在。
2. **未来 admin dashboard**(v0.x)— 系统监控面板可用 LiveView 写;若选 Next.js 也行,两条路都保留。哪条最终主用,看 dogfood 结果。

**Phoenix.Controller / View 仍然不用** — 我们的 HTTP 入口都是 Plug-level(Webhook / AdminAPI),不需要 MVC convention。

### 2.3.1 World UI refresh — 声明式 surface，不是插件专用事件

World 是浏览器 UI 的组合宿主：插件声明 renderer surface 和 caller-scoped
`refresh_state/2` projection，World 只负责把已提交状态投影到当前挂载的
surface。普通刷新只有一条链路：

```
Kind slice commit → Ezagent.SliceChange → WorldLive
→ RefreshSurfaceRegistry → state_builder.refresh_state(uri, ctx)
→ world:surface_state → React partial-state merge
```

`Ezagent.World.UiSurfaceProvider` 是插件向 World 声明 `pages/0` 或
`refresh_surfaces/0` 的 duck-typed contract；`RefreshSurfaceRegistry` 在读侧
校验并合并这些声明，非法声明或 provider failure 都 fail-closed。`WorldLive`
用当前 presenter caps 构造 ctx、按 active surface/URI 合并待处理刷新、再发出
通用 `world:surface_state` envelope。React 仅合并该 surface 的 JSON-safe
partial state；它不自行推导权限或跨过 World 读取状态。

新增插件 UI 不得在 World 写插件名分支、增加专用 browser event，或以直接
PubSub 广播替代这条链路。新的 surface = 声明 + `refresh_state/2`；若需不同的
transport semantics，必须先形成新的架构决策。

### 2.4 Adapter pattern — 硬测试(权威规则见 SKILL P12)

所有外部入口(Feishu/Slack/CLI/MCP/HTTP/internal)都是 **Adapter**。Adapter 做两件事:

1. 解析外部输入 → 构造 `%Invocation{}`
2. 渲染结果回外部协议(通过 `ctx.reply`)

**Adapter 不允许有业务语义**。判断硬标准:**这段代码能在 ExUnit 里直接 `Invocation.dispatch/1` 复现吗?** 不能 = 越界,拆。

详见 §12。

---

## 3. 核心抽象

```
Kind        — URI-addressable actor type     (Session / Entity / Resource)
              implementation: GenServer

Behavior    — action module                  (the only invokable thing)
              owns a state slice
              declares @interface schema

Plugin      — OTP application                (registers Kind / attaches Behavior)
              naming: :ezagent_plugin_<name>

Capability  — (Kind, Behavior, instance)     (CapBAC via ctx.caps)
```

四大概念。**v0.2 的 Process trait/impl 概念在 v0.3 删除**——执行机制就是 GenServer,没有第二种;v0.2 里 `os-process`/`pty`/`web` 三种 impl 实际是不同层的东西混在一起:

### 3.0 Socialware concept axis(正交于上面四个 core 抽象)

上面四个(Kind/Behavior/Plugin/Capability)是 **router 层**的 core 抽象。Socialware unification(2026-06-26/28)在其之上叠了一组 **concept-taxonomy 抽象**,把 ezagent 从"一个 router"reframe 成"一个 host 可 install socialware 的 platform"。完整定义见 `docs/socialware-concepts.md` + GLOSSARY.md §2;此处给摘要 + code 锚点(均 `origin/main`-verified):

```
Base (基座)         — capability substrate(Behavior owning a state slice + general
                      reusable actions);composed INTO a socialware;NOT user-operable.
                      Verified: orchestrator (Behavior.Template content + Orchestrator.Tools
                      + SessionManager, no new Behavior), surface (Behavior.Surface),
                      pty (Behavior.Pty), sandbox (Behavior.Sandbox), cc-headless-agent.
Socialware          — human+program hybrid FLOW;composes ≥1 base + a shape;directly
                      user-operable. Verified instances: chat (world Conversation,
                      generic; composes orchestrator+surface+Turn shape), kanban
                      (board WITH task semantics; Behavior.Kanban shape).
Fixture             — a seeded instance/use of a socialware for a business (autoservice
                      = chat for customer-service). NOT a concept; must NOT enter the
                      concept/schema layer.
Recipe (axis A)     — flavor-agnostic sandbox-content recipe (what an agent is built
                      from). Ezagent.Agent.Recipe (apps/ezagent_core/.../agent/recipe.ex);
                      ConfigObject recipe:<name>, key "recipe";
                      resolved by Ezagent.Agent.RecipeRegistry (apps/ezagent_domain_agent/...).
Responsibility (B)  — the function a principal serves in a session (role_name:
                      bot/reviewer/orchestrator/supervisor), routed via {:role, name}.
                      "role" word stays ONLY in this responsibility sense.
Definition          — L2 ConfigObject (config-as-data): reusable/forkable/content-addressed
                      config bundle (recipe or socialware definition).
                      recipe:<name> / socialware:<name>; NOT a Kind URI.
Runtime state       — L3 per-instance dynamic slice of a Kind's Behavior state
                      (kind_snapshots; rehydrated on restart).
Shape               — flow-specific behavior(s)+recipe making composed bases into a
                      particular flow (chat's Turn; kanban's Kanban).
Install relation    — "session S has socialware W installed" = (a) a per-install
                      ConfigObject (subject=session_uri, key="install:"<>ref) +
                      (b) the socialware's bases+shape mounted into the session's
                      :kind_base union. LANDED: Ezagent.Socialware.Installation
                      (apps/ezagent_domain_session/.../socialware/installation.ex).
```

**两条正交轴**(详见 `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`):

- **recipe(axis A)vs responsibility(axis B)**(#1059 / Decision #155):recipe = "what an agent is built from"(build-time,agent-only);responsibility = "what function a principal serves in a session"(runtime,cross-principal)。一个 member 可 built from `bot` recipe 且 carrying `bot` responsibility —— 两 name 不必匹配。
- **4 carrier layers**(artifact-kind 轴)vs **3 code tiers**(core/domain/plugin,code-dependency 轴):正交。一个 plugin 可同时发 L1 code + L2 seed definitions。详见 §10.8。

**老 `:public_view` SessionTemplate boolean** 已 split(landed P4):identity job → install relation;anon-gate job → socialware-def `visibility_policy.web_anon_access`。`Ezagent.Socialware.PublicView` 保留为 compat facade(delegate 到 `Installation.web_anon_access?/1`)。**老 `Ezagent.Role` 已 rename 为 `Ezagent.Agent.Recipe`(#127/#1071)** —— 全 codebase 无 `defmodule Ezagent.Role`。

### 3.1 Kind

- `web` → **Transport adapter**(顶层,§12)
- `os-process` / `pty` → **Behavior 内部资源**(§6.3 标准 Behavior 库)

### 3.1 Kind

URI 可寻址的运行时类型。三个子类:

| 子类 | 特征 | 例 |
|---|---|---|
| **Session** | 临时、有时限、绑定一组外部资源 | `Ezagent.Session.Feishu2CC`、`Ezagent.Session.CC` |
| **Entity** | 长期存在、`@behaviour Principal`、持有 capability | `Ezagent.Entity.User`、`Ezagent.Entity.Agent` |
| **Resource** | 操作对象,无 Principal | `Ezagent.Resource.Workspace`、`Ezagent.Resource.Path`、`Ezagent.Resource.ExternalChannel` |

每个 Kind 类型有三个模块:

```
Ezagent.<Category>.<KindType>            — Kind 声明
Ezagent.<Category>.<KindType>.Server     — 单实例 GenServer
Ezagent.<Category>.<KindType>.Supervisor — 该 KindType 的 DynamicSupervisor
```

**Kind instance 的 URI 同时是它的 PubSub topic 前缀**:

```
agent://allen-小满              ← URI(寻址)+ topic(订阅 inbound)
agent://allen-小满:events       ← outbound 事件流 topic
agent://allen-小满:_internal    ← 内部 topic(plugin 自约定)
```

#### 3.1.1 Resource 子类 — "薄"形态 + Shared referent 判定原则

Resource 是"操作对象,无 Principal"。它**可以是薄的**——没有消息流、没有外部进程、没有路由规则。它的 GenServer 不需要长期活跃,操作时存在、操作完落盘退出(`persistence: :on_terminate` 或 `:external` 都适合)。

**判定一个概念该不该是独立 Resource Kind 的硬标准**:

> **任何被多方指向的命名锚点都需要独立身份**(shared referent needs identity)

具体来说:如果一个概念被 2 类以上的引用者按身份引用(cap subject、session bindings、user.default、其他 Resource 表、plugin 运行时配置 ...),它必须有稳定可寻址 URI,**不能展开成 tuple/字段集合分发到各引用者**——否则编辑就要 fan-out,变成 silent divergence 来源。

Workspace 是这条原则的代表性应用(详见 §9.2 Template Instance):它被 5 类引用者指向(cap / session bindings / user.default_workspace_id / repo registry / plugin config),所以必须是独立 Resource Kind,不能展开成"folder URIs + agent_def + settings" tuple。

#### 3.1.2 Kind 实例化策略默认值

每种 Kind 子类的默认实例化模式:

| 子类 | 默认实例化模式 | 默认 persistence | 例 |
|---|---|---|---|
| **Session** | 按需 spawn(template instantiate 时建,任务结束销毁) | `:on_terminate` | Feishu2CC 收到新 chat → 建一个 |
| **Entity** | 显式 spawn(`/user:new` / `/agent:invite`,长期存在) | `:on_change` | 用户注册一次,长期使用 |
| **Resource** | 按需 spawn,操作完可终止 | `:on_change` 或 `:on_terminate` | Workspace 用户创建一次,后续操作时短暂活跃 |

Kind module 可在 `use Ezagent.Kind` 里 override 这些默认值。

> **Implementation**:
> - 单实例 → **`GenServer`**(OTP)
> - Supervisor → **`DynamicSupervisor`**(OTP)
> - URI → pid 寻址 → **`Registry`**(Elixir 标准库)
> - PubSub topic → **`Phoenix.PubSub`**
> - 跨节点 actor 寻址(v0.x+) → **`Horde.Registry`**
> - 在线状态 → **`Phoenix.Presence`**

### 3.2 Behavior

**整个系统唯一可调用的东西。** Action 模块,声明 actions + 编写 `handle_<action>/2` 处理器,处理器返回 effects(§6.0)。Behavior 通过 `use Ezagent.ActionSet` 接入新合约;`action/3` 宏自动派生 schema(`interface/0`)+ cap 声明(`required_caps/0` + `cap_subjects/0`)。

```elixir
defmodule Ezagent.ActionSet.Movable do
  use Ezagent.ActionSet   # post-2026-05-28 new contract opt-in

  action :move,
    args:    %{position: {:tuple, :integer, :integer}},
    returns: %{position: {:tuple, :integer, :integer}},
    caps:    [:move],
    modes:   [:call],
    description: "Move to a 2D position"

  action :stop,
    args:    %{},
    returns: %{ok: :boolean},
    caps:    [:stop],
    modes:   [:call, :cast],
    description: "Halt motion"

  def state_slice, do: :movable
  def init_slice(_args), do: %{position: {0, 0}, velocity: 0}

  def handle_move(%{position: pos}, ctx) do
    {:ok, %{position: pos}, [{:set, :position, pos}]}
  end

  def handle_stop(_args, ctx) do
    {:ok, %{ok: true}, [{:set, :velocity, 0}]}
  end
end
```

`action/3` 宏接受 `args / returns / caps / modes / description / data_owner / workspace_scoped?` keyword 列表,在编译期生成 `__actions__/0` + 派生 `interface/0`,所有 adapter(CLI、Slash、HTTP、MCP、LiveView)从这一份声明自动生成。这是 Ezagent 与 OpenAPI 类比的关键——**URI = operationId,`action` 宏 = schema**。

> **Implementation**:`use Ezagent.ActionSet` + `action/3` defmacro + `@before_compile` 派生 + handler 编译期校验(`def handle_<action>(args, ctx)` 必须存在,否则 CompileError)。Phase 3 PR #464 之前的 `@interface` module attribute + `invoke/4` callback 模式见 §6.1 — 那是历史形态,新代码不再写。

### 3.3 Plugin

OTP application,启动时向 Registry 注册 Kind 或 attach Behavior。详见 §8。

> **Implementation**:**`Application`** + **`Supervisor`**(OTP);发现机制基于 `Application.spec/2` 元信息。

### 3.4 Capability

```elixir
%Ezagent.Capability{
  kind:       Ezagent.Entity.Agent,
  behavior:   Ezagent.ActionSet.Movable,
  instance:   URI.t() | :any | {:within_session, URI.t()},
  granted_by: URI.t(),
  granted_at: DateTime.t()
}
```

> **Implementation**:`MapSet` + struct;`Ezagent.Capability.matches?/2` 纯函数,~30 LOC。**不用第三方 ACL 库**——`Bodyguard`/`Canada` 是 RBAC,跟 CapBAC 不兼容。

### 3.5 Message — Entity-Entity 通信的特化 envelope

`%Ezagent.Invocation{}` 是 Ezagent 的 universal envelope(协议层)。`%Ezagent.Message{}` 是 Invocation 的一个**特化 args shape**,代表 Entity ↔ Entity 通信。

```elixir
%Ezagent.Message{
  sender:      URI.t(),               # Entity URI(user://... 或 agent://...)
  mentions:    [URI.t()],             # @-targets
  body:        term(),                # text / structured map(attachments 等)
  ref:         URI.t() | nil,         # ^reply-to(另一条 Message 的 URI)
  inserted_at: DateTime.t()
}
```

**何时是 Message,何时不是** — 判定标准是 **sender 跟 effective recipient 都是 Entity**:

| 链路 | Message? |
|---|---|
| User → Agent | ✅ |
| Agent → Agent(`@reviewer 看下`) | ✅ |
| Agent → User(回复) | ✅ |
| User → Session(`/set-default A`) | ❌ Entity → Session/Resource,管理操作 |
| Agent → OSProcess(写 stdin) | ❌ Entity → Resource |
| Session 中转给 receivers | ✅ Session 中转;`sender` 仍是源头 Entity |
| pty 输出 → Agent | ❌ Resource → Entity,非 Entity-Entity |
| Webhook ingest 第一跳 | ❌ adapter → Session,管理 |

**Message identity invariant**:

> 一条 Message 在系统内被任意次路由、转发、广播,其 `sender` / `ref` / `body` / `inserted_at` / `mentions` 字段**始终不变**。中转者(adapter / Session)**只创建携带该 Message 的新 Invocation**,从不修改 Message 本身。

这条不变式是 Message stream 作为业务事实层(audit / replay)的基础。等价于 IRC `PRIVMSG` 在跨服务器中转时 source 字段不变。

> **Implementation**:struct + helpers,**~25 LOC**(`Ezagent.Message.new/4`、`identity_match?/2`、`Jason.Encoder` impl)。Behavior 的 `@interface.args` 可以直接声明 `args: %Ezagent.Message{}` 作为 schema。

---

## 4. URI & Invocation

### 4.1 URI as universal operationId

URI 是 **system-wide operation identifier**,类比 OpenAPI 的 operationId。每个 invokable 操作有唯一 URI。

```
agent://allen-小满                          ← Kind instance(寻址 / subscribe)
agent://allen-小满/behavior/movable         ← Behavior 引用(introspect / grant target)
agent://allen-小满/behavior/movable/move    ← Action(invoke target)
```

URI 跟外部协议**完全解耦**——`slash://`、`feishu://`、`http://` 这种协议 ID **不进 URI**。协议事件在 Adapter 层翻译成内部 URI(详见 §12)。

URI 的 scheme 决定 Kind 类型:`agent://`、`session://`、`user://`、`channel://` 等等,在 `Ezagent.URI.SchemeRegistry` 注册。

> **Implementation**:Elixir 标准库 **`URI`** + `ezagent_core` 自写 ~25 行 scheme registry。

### 4.2 Invocation = URI + Verb + Args + ctx

```elixir
%Ezagent.Invocation{
  target: %URI{...},
  mode:   :call | :cast | :call_stream | :subscribe | :introspect,
  args:   map(),
  ctx: %{
    caller:      URI.t(),
    caps:        MapSet<%Ezagent.Capability{}>,
    trace_id:    String.t(),
    deadline_ms: pos_integer(),
    reply:       reply_target()           # ← 协议无关回复路由,见 §4.3
  }
}
```

**Mode 集合**(有限,不允许增长):

| Mode | 实现 | 用途 |
|---|---|---|
| `:call` | `GenServer.call` | 同步 RPC,返回 `{:ok, value}` 或 `{:error, _}` |
| `:cast` | `GenServer.cast` | fire-and-forget |
| `:call_stream` | `GenServer.call` + Stream | 返回 `{:ok, Stream.t()}`,例:pty 输出、agent token 流 |
| `:subscribe` | `Phoenix.PubSub.subscribe` | 建立订阅 |
| `:introspect` | `GenServer.call` + 静态查询 | 查 schema / instance list / cap matrix(自指——对任意 URI 都可调) |

`:introspect` 是 Ezagent 的 `/openapi.json` 等价物。`dispatch(agent://x, :introspect)` 返回该实例所有 Behavior + `@interface` 的合集。

### 4.3 `ctx.reply` — 协议无关的回复路由

Reply target 是 ctx 字段,**不是 URI 的一部分**。Behavior 完全不知道自己回的是 slash 还是 HTTP——它只返回结果,`Ezagent.Invocation.reply(ctx, result)` 根据 `ctx.reply` 路由回原协议。

```elixir
@type reply_target ::
        {:phoenix_channel, topic :: String.t()}
      | {:phoenix_pubsub, topic :: String.t()}
      | {:plug_conn, conn :: Plug.Conn.t()}
      | {:stdio_pipe, pid :: port()}
      | {:mcp_response, request_id :: String.t()}
      | {:caller_inbox, pid :: pid()}
      | :ignore
```

Adapter 在构造 `%Invocation{}` 时填好 `ctx.reply`,所有 Behavior 共享一份 reply 协议。

---

## 5. Dispatch via Registry

Ezagent 有三种 Registry 家族,各管一事:

| Registry | 形态 | 用途 |
|---|---|---|
| **`KindRegistry`** (§5.1) | `URI → pid` | 寻址(Invocation 主路径) |
| **`BehaviorRegistry`** (§5.2) | `{Kind, action} → Behavior module` | dispatch(Kind 内查 Behavior) |
| **`RoutingRegistry`** (§5.4) | `external_key → URI(s)` | inbound / discovery / fan-out |

### 5.1 KindRegistry

```elixir
Ezagent.KindRegistry.lookup(URI.parse("agent://allen-小满"))
# → {:ok, #PID<0.234.0>}
```

每个 Kind instance 启动时注册自己的 URI。

> **Implementation**:**`Registry`**(单节点)/ **`Horde.Registry`**(v0.2+ 集群)。`ezagent_core` ~30 行 wrapper。

### 5.2 BehaviorRegistry

Kind 声明时只是"列出"它支持的 Behavior:

```elixir
defmodule Ezagent.Entity.Agent do
  use Ezagent.Kind,
    behaviors: [
      Ezagent.ActionSet.Identity,
      Ezagent.ActionSet.Movable,
      Ezagent.ActionSet.Spawnable
    ],
    template: Ezagent.Entity.Agent.Template,
    persistence: {:snapshot, :on_change}
end
```

Plugin 在 `Application.start/2` 里把 Behavior 注册到 ETS:

```elixir
Ezagent.BehaviorRegistry.register(
  kind: Ezagent.Entity.Agent,
  behavior: Ezagent.ActionSet.Movable
)
# ETS:
#   {Ezagent.Entity.Agent, :move} → Ezagent.ActionSet.Movable
#   {Ezagent.Entity.Agent, :stop} → Ezagent.ActionSet.Movable
```

> **Implementation**:**ETS**(微秒级 lookup)+ ~50 行 wrapper。

### 5.3 Why dispatch over mixin

| 维度 | Dispatch | Mixin (`use Behavior`) |
|---|---|---|
| Plugin 加 Behavior | ✅ Runtime register | ❌ 必须改 host 源码 + 重编译 |
| 字段冲突 | ✅ Slice 隔离 | ❌ Macro hygiene 灾难 |
| 编译期 / 运行期 | ✅ 一致 | ❌ 割裂 |
| Dialyzer 校验 | ❌ Runtime check | ✅ 编译期可验 |

代价:Dialyzer 不能验证"Kind 是否实现了它声明的 Behavior"。换用 `Application.start/2` 阶段的 fail-fast validation 弥补。**接受这个 trade-off**。

### 5.4 RoutingRegistry — 第三种 Registry 家族

#### 5.4.1 为什么需要

n×n 网络的核心问题:**外部世界的 key 如何映射到 Ezagent URI**。例:

```
{chat_id: "oc_abc", app_id: "feishu_cli_x"}   → session://feishu-cc/cc-7f3a
{feishu_user_id: "ou_xyz"}                    → user://allen
{session_uri, role: :architect}               → [agent://arch-a, agent://arch-b]
```

任何 multi-channel adapter 都会遇到这种查询。如果不抽象,每个 plugin 各自建一个 ETS 表 + 自写注册/查询/崩溃恢复/集群同步代码——5 个 plugin 后就是 5 种风格的半成品(dev review 里 `chat_routing` / `ActorQuery` / `AdapterSocket.Registry` / multi-app routing 的现状)。

**RoutingRegistry 是这类查询的统一抽象**——一组命名的 lookup 表,owner plugin 写,任何 plugin 读。

#### 5.4.2 形态

底层就是 **`Phoenix.Registry`**(支持 unique / duplicate keys,partition,value 任意 term)。RoutingRegistry 在它之上加一层**命名表 + owner-only-write 约束 + 写语义**。

```elixir
# Plugin Application.start 里声明表:
defmodule EzagentPluginFeishu.Application do
  use Application

  def start(_, _) do
    Ezagent.RoutingRegistry.declare_table(
      name: ChatRouting,
      duplicate_keys: false,
      owner: :ezagent_plugin_feishu
    )
    Ezagent.RoutingRegistry.declare_table(
      name: PrincipalMapping,
      duplicate_keys: false,
      owner: :ezagent_plugin_feishu
    )
    Supervisor.start_link([], strategy: :one_for_one)
  end
end

# 写(只允许 owner plugin):
Ezagent.RoutingRegistry.put(ChatRouting, {chat_id, app_id}, session_uri)
Ezagent.RoutingRegistry.put_new(ChatRouting, {chat_id, app_id}, session_uri)  # ← 新增

# 读(任何 plugin):
Ezagent.RoutingRegistry.lookup(ChatRouting, {chat_id, app_id})
# → {:ok, session_uri} | :error

Ezagent.RoutingRegistry.lookup_all(RoleIndex, {session_uri, :architect})
# → [agent_a_uri, agent_b_uri]
```

##### `put` vs `put_new` — unique-key 表必须用 `put_new`

`put` 是 last-writer-wins,**对 unique-key 表很危险**——会静默 shadow 已有 entry,后果是消息发给"错的那个 receiver"或"已死的连接",**无任何报错**(现有 esr 真实事故 `mcp-transport-orphan-session-hazard.md`)。

```elixir
def put_new(table, key, value) do
  case lookup(table, key) do
    {:ok, existing} ->
      if alive?(existing),
        do: {:error, {:already_registered, existing}},   # ← reject,不静默覆盖
        else: put(table, key, value)                      # 旧的死了,可接管
    :error -> put(table, key, value)
  end
end
```

**用法纪律**:

| 表的 key 类型 | 用 `put` 还是 `put_new`? |
|---|---|
| `duplicate_keys: false`(unique-key,例 `ChatRouting`) | **`put_new`**——撞了 reject;`put` 只在"明知要覆盖"的场景用,且要有显式注释 |
| `duplicate_keys: true`(duplicate-key,例 `SessionRules`) | **`put`**——本就是 append 语义,N 条 entry 是正常的 |

`put` 在 unique-key 表上 **几乎永远不该用**。Linter 可加 warn:`Ezagent.RoutingRegistry.put` 调用 unique-key 表时提示用 `put_new`。

#### 5.4.3 跟 KindRegistry 的关系——两段式 routing

```
        external_key             URI                    pid
             │                    │                      │
             │ RoutingRegistry    │ KindRegistry         │
             ├───────────────────→├──────────────────────→│
             │ external → URI     │ URI → pid             │
             │ (plugin domain)    │ (ezagent_core domain)     │
             ▼                    ▼                       ▼
    "oc_abc + cli_x"      session://feishu-cc/cc-7f3a   #PID<0.512.0>
```

- **RoutingRegistry** = `external_key → URI`,plugin 域知识(Feishu 知道 chat_id,但 ezagent_core 不该懂)
- **KindRegistry** = `URI → pid`,纯 ezagent_core 域,跟外部协议无关

每次 inbound 流程**两个 Registry 配合**——adapter 用 RoutingRegistry 拿到 URI,然后 dispatch(内部用 KindRegistry 找 pid)。

#### 5.4.4 责任分配:写入侧 vs 读取侧

**写入侧(Phase 1: Session 创建)** — Session plugin 负责。Template instantiate 时把 `external_key → session_uri` 写入对应 table。

```elixir
defmodule Ezagent.Session.Feishu2CC.Template do
  def instantiate(template_data, _opts) do
    {:ok, session_uri} = start_session_genserver(...)
    Ezagent.RoutingRegistry.put(ChatRouting,
      {template_data.chat_id, template_data.app_id},
      session_uri)
    # ... 接着拉起 Pty 等
    {:ok, session_uri}
  end
end
```

**读取侧(Phase 2: 消息到达)** — Adapter 负责。WebhookPlug / Channel 拿到外部协议事件 → 查 RoutingRegistry 拿 URI → 翻译 payload 成 `%Invocation{}` → dispatch。

```elixir
defmodule Ezagent.Web.WebhookPlug do
  def handle_feishu_event(payload, conn) do
    # 步骤 A — 查地址(RoutingRegistry)
    {:ok, session_uri} = Ezagent.RoutingRegistry.lookup(ChatRouting,
      {payload.chat_id, payload.app_id})
    {:ok, user_uri} = Ezagent.RoutingRegistry.lookup(PrincipalMapping,
      payload.user_id)

    # 步骤 B — 翻译消息(adapter plugin 知识)
    invocation = %Ezagent.Invocation{
      target: URI.parse("#{session_uri}/behavior/chat_room/receive"),
      mode: :call,
      args: %{text: payload.text, sender: user_uri},
      ctx: %{caller: user_uri, caps: ..., reply: {:plug_conn, conn}}
    }

    # 步骤 C — dispatch(ezagent_core)
    Ezagent.Invocation.dispatch(invocation)
  end
end
```

**RoutingRegistry 完全不感知消息长什么样、怎么翻译**——它只是地址簿。

#### 5.4.5 责任分配总表

| 步骤 | 谁负责 | 做什么 |
|---|---|---|
| Phase 1: 注册 | **Session/Entity plugin** | `external_key → URI` 映射写入 RoutingRegistry |
| Phase 2 步骤 A: 查地址 | **RoutingRegistry**(ezagent_core 服务) | `external_key → URI` |
| Phase 2 步骤 B: 翻消息 | **Adapter plugin** | 外部 payload → `%Invocation{}` 结构 |
| Phase 2 步骤 C: dispatch | **ezagent_core** | URI → pid → Behavior |

#### 5.4.6 Core 不预定义任何 table

`ezagent_core` 只提供 API(`declare_table` / `put` / `lookup` / `lookup_all` / `delete`),**不预定义任何具体 table**。理由:

- core 不该懂 Feishu/Slack/MCP/CLI 这些协议
- core 不该懂"role"这种业务概念
- 每张 table 跟它的 owner plugin 同生共死

典型 table 由 plugin 声明:

| Table | Owner Plugin |
|---|---|
| `ChatRouting` | `ezagent_plugin_feishu` / `esr_plugin_slack`(各管自己) |
| `PrincipalMapping` | 同上 |
| `RoleIndex` | 谁定义 role 概念(通常 session orchestrator plugin) |
| `SocketSession` | `ezagent_web`(WS connection → session URI) |
| `SlashRoute` | `esr_adapter_slash` |
| `AgentMention` | session plugin(@-mention 路由,见 §18.4) |

#### 5.4.7 防 drift 的四条硬约束

1. **URI 是寻址唯一入口**——"找 pid"必须最终回到 `KindRegistry.lookup(uri)`
2. **Plugin 不准自建 ETS / Registry / Agent 做二级查询**;必须注册到 RoutingRegistry
3. **Cross-session / cross-plugin 调用 = 普通 Invocation**;caller `ctx.caps` 必须含跨域 cap
4. **每张 routing table 由一个 plugin owner-注册**;其他 plugin 只读不写

#### 5.4.8 跨节点(v0.2+)

`Phoenix.Registry` 单节点。集群时:
- **KindRegistry** → 切到 **`Horde.Registry`**
- **RoutingRegistry** → 切到 **`Horde.Registry`** 或 **`Phoenix.Tracker`**(底层都是 CRDT)
- **`Phoenix.PubSub`** → 已经天然集群,不动

迁移成本低,API 同型。

> **Implementation**:**`Phoenix.Registry`**(底层)+ ~60 行 wrapper(owner check + table 注册 + put_new + helper)。
>
> **重要 framing 澄清**:这 ~60 行是**存储底座**,不代表 "routing 复杂度被解决了"。现有 esr 的 9 个 registry 共 1722 行,其中 prefix 匹配、overlay 分层、attach/detach 状态语义等业务逻辑 **没有消失,只是从"散落在 core"搬到了"各 owner plugin 内部"**。这符合 §5.4.6 "core 不预定义任何 table" 哲学,但读者不要因此低估总工作量——~1000 行 routing 业务逻辑会出现在 owner plugin 里(slash route plugin / chat routing plugin 等)。
>
> 不过这些 ~1000 行的迁移**不是 verbatim 移植**,大多数会**蒸发**——v0.4 的新模型(`@interface` 自动派生 slash routing、RoutingRegistry 通用存储、`put_new` 注册一致性)免费提供了相当一部分功能。迁移分诊规则详见 §17.2。

### 5.5 Routing Rules — additive rules + matcher DSL

RoutingRegistry 的一个特别重要的 use case 是 **session 内 message routing**——决定每条 Message 谁收。形态是**additive rules**:每条 rule `(matcher, receivers)` 独立可加,所有命中的 rule 的 receivers 取并集。不存在"谁覆盖谁",编辑路径就是 add/remove rule。

#### 5.5.1 演化场景示例

```
Session 创建后,Feishu2CC Template 自带 1 条 rule:
  Rule {matcher: from_external(:inbound), receivers: [pty_uri]}
  // pty 永远收到所有 inbound,这是模板自带

阶段 1: agent A 加入 → /invite 自动加:
  Rule {matcher: mention("A"), receivers: [agent_a_uri]}

阶段 2: /set-default A → 加 1 条:
  Rule {matcher: always(), receivers: [agent_a_uri]}
  // @A 进来同时命中两条,union 还是 [agent_a]

阶段 3: agent B 加入:
  Rule {matcher: mention("B"), receivers: [agent_b_uri]}
  // @B 进来:命中 mention "B" → [B];命中 always → [A];union = [A, B]
  // 这就是"mention B 时,A 也收到"——不需要特殊机制

阶段 4: agent B 输出 @A:
  // B 的输出经 Session 重新路由:命中 mention "A" → [agent_a];命中 always → [agent_a]
  // union = [agent_a]
```

**整套 routing 函数 ~8 LOC**:

```elixir
def route(session_uri, message) do
  Ezagent.RoutingRegistry.lookup_all(SessionRules, session_uri)
  |> Enum.filter(fn {matcher, _} -> Matcher.match?(matcher, message) end)
  |> Enum.flat_map(fn {_, receivers} -> receivers end)
  |> Enum.uniq()
end
```

#### 5.5.2 Matcher 是数据(DSL 编译期产),不是函数

Plugin 作者写 DSL,编译期就是 AST 数据(类似 Ecto.Query):

```elixir
import Ezagent.Routing.Matcher

# 用户写:
rule always()              => [agent_a_uri]
rule mention("B")          => [agent_b_uri, agent_a_uri]
rule from_member(:pty)     => [external(:inbound_chat)]
rule text_contains("deploy") and not from(agent_b_uri) => [deploy_agent_uri]

# 编译/eval 后,RoutingRegistry 里存的:
%{matcher: %{type: :always}, receivers: [agent_a_uri]}
%{matcher: %{type: :mention, name: "B"}, receivers: [agent_b_uri, agent_a_uri]}
%{matcher: %{type: :from_member, member: :pty}, receivers: [{:external, :inbound_chat}]}
%{matcher: %{type: :and, ops: [
  %{type: :text_contains, pattern: "deploy"},
  %{type: :not, op: %{type: :from, uri: agent_b_uri}}
]}, receivers: [deploy_agent_uri]}
```

`always/0`、`mention/1`、`from_member/1` 等不是函数调用,是**返回 matcher struct 的 constructor**——整个表达式 evaluate 出来是一棵数据树。所有下游消费(LiveView 显示、SQLite 存、跨节点同步、CLI `/route show`)都基于数据。

#### 5.5.3 内建 matcher constructor — 全部在 core

按 §2.2 Plugin 判定原则,**读 `%Message{}` / `%Invocation{}` 字段的 matcher 都在 core**——`%Message{}` 是 core 数据结构(§3.5,`message.ex` 在 §14 core 布局里),操作它的 matcher 是 core 数据上的逻辑。

```
组合子(纯逻辑):
always()                        — 任何 message 都匹配
and(matchers)
or(matchers)
not(matcher)

Message-field matcher(读 %Message{} 字段):
mention(name :: String.t())       — message.mentions 含 name 对应 Entity
mention_uri(uri :: URI.t())       — message.mentions 含具体 URI
from(uri :: URI.t())              — message.sender == uri
from_member(role :: atom())       — sender 属于 session 内某 role
from_external(direction :: atom()) — message 源自 ExternalChannel
text_contains(pattern)            — body 文本含 pattern
ref_to(uri :: URI.t())            — message.ref == uri(回复某条 message)
```

**为什么这些都在 core,不放 chat plugin**:Message routing **不是 chat 专属**。未来 `esr_behavior_audit` 或 `esr_behavior_workflow` 也会路由 `%Message{}`、也需要 `from`/`mention`。如果这些 matcher 在 `esr_behavior_chat`,audit plugin 要用就得**依赖 chat plugin** —— 违反 plugin 隔离北极星。

这条规则的正向应用:**未来 plugin-专属 payload 的 matcher 才进 plugin**——例如假设的 `feishu_card_type(:approval)` 读 Feishu 专属卡片结构,进 `ezagent_plugin_feishu`;`slack_block_type(:section)` 读 Slack Block Kit,进 `esr_plugin_slack`。Core 不知道这些 plugin-专属结构。

#### 5.5.4 Plugin 扩展新 matcher type

```elixir
# 在 plugin 的 Application.start 里注册:
Ezagent.Routing.Matcher.register(
  :feishu_card_type,
  fn message, %{type: type} ->
    case message.body do
      %{__feishu_card__: %{type: ^type}} -> true
      _ -> false
    end
  end
)

# 然后 rule 可以是:
rule feishu_card_type(:approval) => [agent_a_uri]
```

注册的扩展 matcher **只在该 plugin 已加载时可用**,不影响其他 plugin。

#### 5.5.5 路由函数 — 投递保证 + 零匹配出口

```elixir
defmodule Ezagent.Routing do
  def route(session_uri, message) do
    receivers =
      Ezagent.RoutingRegistry.lookup_all(SessionRules, session_uri)
      |> Enum.filter(fn {matcher, _} -> Matcher.match?(matcher, message) end)
      |> Enum.flat_map(fn {_, receivers} -> receivers end)
      |> Enum.uniq()

    case receivers do
      [] ->
        # 零匹配:不能静默返回 [],必须显式可观测
        :telemetry.execute(
          [:ezagent, :routing, :unroutable],
          %{count: 1},
          %{session: session_uri, message_uri: message.uri}
        )
        Ezagent.DeadLetter.put(:unroutable, %{
          session: session_uri,
          message: message,
          reason: :no_matching_rule
        })
        []

      rs ->
        # 有 receivers:逐个 dispatch Invocation(via dispatch 自动走 ReadyGate)
        Enum.each(rs, fn receiver_uri ->
          Ezagent.Invocation.dispatch(%Invocation{
            target: build_target(receiver_uri, :chat, :receive),
            args: message,
            mode: :cast,
            ctx: %{caller: message.sender}
          })
        end)
        rs
    end
  end
end
```

**为什么零匹配不能静默**:Ezagent 是 chat 系统(§1.2 差异 1),用户发的 message 到达零个 receiver **本身就是 bug**——用户期待"有人收到"。返回 `[]` 跟"正常工作"在代码上无法区分,bug 永远不会被发现。零匹配必须 → telemetry + DLQ unroutable,变成可观测事件。

**投递保证**:`dispatch/1` 内部按 §5.7 reliability primitives 走——target ready 则 `KindRegistry.lookup + cast`,not-ready 则 `:cast` buffer / `:call` fail-fast。**plugin 作者只调 `dispatch/1`,投递保证自动生效**。

#### 5.5.6 编辑就是普通 Invocation

`/set-default A`、`/route mention B also-to A`、`/invite agent` 这些**不是特权 API**,而是 `Ezagent.ActionSet.SessionRouting` 上的标准 actions。走完整 dispatch / CapBAC / audit / telemetry 链路——**编辑路径本身也有权限和审计**。

```elixir
defmodule Ezagent.ActionSet.SessionRouting do
  @behaviour Ezagent.ActionSet

  @interface %{
    set_default:    %{args: %{agent: :string}, ...},
    add_rule:       %{args: %{matcher: :map, receivers: {:list, :string}}, ...},
    remove_rule:    %{args: %{rule_id: :string}, ...},
    invite:         %{args: %{agent_template: :map}, ...},
    kick:           %{args: %{agent: :string}, ...}
  }
  # ...
end
```

> **Implementation**:`Ezagent.Routing.Matcher` 模块 **~85 LOC / cap 110**(组合子 + Message-field matcher + DSL 宏 + `match?/2` 递归 + `register/2` API + `to_string/1` 反向渲染)。整个 session routing 表逻辑 ~10 LOC,因为 RoutingRegistry 把存储和 lookup 接走了。

### 5.6 三条 dispatch 不变式 → 见 SKILL P19

权威源现在在 `.claude/skills/ezagent-developer/SKILL.md` §Design Principles **P19**(三条 dispatch hygiene rules 完整逐字保留 + 解释为什么这是 P14/P15/P16 的本地 hygiene)。P19 同时上下文链接到 P14(dispatch is the only path)、P15(capability shape)、P16(Kind lifecycle single entry)。本节不再独立列规则,避免双源 drift。

### 5.7 Reliability Primitives — 让正确性落在 core,不靠 plugin 作者纪律

§1.2 差异 1(Ezagent 是 router 不是 req/resp)推论:必须人工造可观测性。落到 core 层就是三个 primitive,**plugin 作者根本无法绕过**——`use Ezagent.Kind` 宏自动接入,`Ezagent.Invocation.dispatch/1` 自动走对应路径。

#### 5.7.1 ReadyGate — 标记 Kind 何时可投递

```elixir
defmodule Ezagent.ReadyGate do
  # 三态:
  #   :unknown   — URI 未在 KindRegistry,根本没启动
  #   :not_ready — 已注册但 init/subscribe 还没完
  #   :ready     — 已 mark_ready,可投递
  
  def mark_ready(uri) :: :ok
  def status(uri) :: :unknown | :not_ready | :ready
end
```

实现:ETS 表 `{uri, :ready | :not_ready}`,KindRegistry 注册时插 `:not_ready`,GenServer `handle_continue(:announce_ready, ...)` 后置 `:ready`。

#### 5.7.2 PendingDelivery — not-ready 窗口的消息 buffer

```elixir
defmodule Ezagent.PendingDelivery do
  # bounded per-URI buffer(默认 100/URI),溢出走 DLQ
  def buffer(uri, message) :: :ok | {:error, :buffer_full}
  
  # ready 时主动 flush
  def flush(uri) :: [message]
end
```

实现:ETS 表 `{uri, [message]}`,GenServer `handle_continue(:announce_ready, ...)` 后调 `flush/1` 把 buffer 倒进 mailbox。

#### 5.7.3 Idempotency — webhook 重试去重

```elixir
defmodule Ezagent.Idempotency do
  # bounded ETS(默认 10k entry,LRU evict)
  def seen?(key) :: boolean
  def record(key) :: :ok
end
```

由 adapter 在构造 Invocation 时填 `ctx.idempotency_key`(从外部协议 message_id derive),`dispatch/1` step 2.7 自动检查。

**v0 语义:"收到即记",不是"成功才记"** — Appendix A step 2.7 `record(key)` 在 Behavior 执行**之前**完成。如果第一次 invocation 处理到 step 7 抛异常,key 已经记下;同一 message_id 的 webhook 重试会拿 `:duplicate_ignored`,**不会重试到成功**——失败路径走 DLQ 兜底。

理由:更宽松的"成功才记"语义需要 invocation 全程事务化保护(record 写在 commit 阶段),会让 Idempotency 跟 Behavior 内部状态变更耦合,远超 v0 ~20 LOC 的复杂度预算。v0 接受这个 limitation,因为:

- DLQ 已经捕获失败 invocation,运维可以查 + 重放
- "幂等"在 webhook 协议层的本意是"provider 没收到 200 就重试",但 Ezagent 内部失败 ≠ provider 没收到——这两个失败模式应该分别处理(provider 没收到走 idempotency,内部失败走 DLQ),不该混在同一个 key 里
- 真需要"重试到成功"的关键 invocation 应该用专门的 retry policy(future,§17 可加),不依赖 Idempotency

显式标注这是 limitation,实施时不要"自然扩展"成事务化语义。

#### 5.7.4 Kind GenServer 生命周期 — 两条等价实现路径

Ezagent Kind 的 `register → subscribe → announce_ready` 生命周期是不变式(Decision #66),
**有两条 means 实现等价 property**,plugin 作者都无法绕过:

**路径 A — `use Ezagent.Kind` 宏**(原方案):每个 Kind 模块通过 `use Ezagent.Kind` 宏展开,
宏生成 `init/1` 实现固定的 register→subscribe→announce_ready 三步。

```elixir
# 路径 A:use Ezagent.Kind 宏展开出:
def init(args) do
  state = load_or_init(args)
  :ok = Ezagent.KindRegistry.put_new(state.uri, self())   # 撞 key crash, let-it-crash
  :ok = subscribe_own_topics(state.uri)
  {:ok, state, {:continue, :announce_ready}}
end

def handle_continue(:announce_ready, state) do
  Ezagent.ReadyGate.mark_ready(state.uri)
  Ezagent.PendingDelivery.flush(state.uri) |> Enum.each(&handle_inbound(&1, state))
  {:noreply, state}
end
```

**路径 B — `@behaviour Ezagent.Kind` + 共享 `Ezagent.Kind.Server`**(Phase 1 实施选择,Decision #84):
每个 Kind 模块只声明 `@behaviour Ezagent.Kind` + callback(`type_name/0`、`behaviors/0`、
`persistence/0`、可选 `uri_from_args/1`)。整个系统**一个**共享 `Ezagent.Kind.Server` GenServer,
Kind 实例由 `Ezagent.Kind.Server.start_link({kind_module, args})` 启动。plugin 作者根本不写 init,
property 等价或更强(用户写不出 wrong init,因为没 init 可写)。

```elixir
# 路径 B:Kind 模块
defmodule Ezagent.Entity.Echo do
  @behaviour Ezagent.Kind
  def type_name, do: :echo
  def behaviors, do: [Ezagent.ActionSet.Echo]
  def persistence, do: :ephemeral
end

# 共享 server 处理生命周期(同等 register→subscribe→announce_ready 严格三步)
defmodule Ezagent.Kind.Server do
  use GenServer
  def init({kind_module, args}) do
    state = load_or_init(args, kind_module)
    :ok = Ezagent.KindRegistry.put_new(state.uri, self())
    :ok = subscribe_own_topics(state.uri)
    {:ok, %{kind: kind_module, uri: state.uri, state: state}, {:continue, :announce_ready}}
  end
  # handle_continue + handle_call/cast 同上
end
```

**保证次序**(两条路径都满足):`register → subscribe → mark_ready` 严格三步,plugin 作者改不了。这消除了"先发后订"race:

- 注册前没人能 lookup 到 → 没人能 cast 进来
- 注册后 subscribe 前的窗口里:**`dispatch/1` 路径被 ReadyGate 接住**(`put_new` 时 ReadyGate 就置 `:not_ready`,`:cast` 进 PendingDelivery buffer,`:call` fail-fast),所以 dispatch 来的 message 一条不丢
- mark_ready 前 dispatch 来的消息 → PendingDelivery buffer,ready 时 flush

**两条路径的 trade-off**:

| 维度 | 路径 A(宏) | 路径 B(共享 Server) |
|---|---|---|
| Kind 之间隔离边界 | **compile time**(每 Kind 自己的 GenServer module,代码层独立) | **runtime**(所有 Kind 共享 `Ezagent.Kind.Server`,state shape 由 slice key 隔离) |
| `handle_dispatch/3` 复杂度 | 简单(每 Kind 自己处理) | 必须 defensive 处理多 Kind 的 state shape |
| Plugin 隔离 invariant | 强(模块级) | 弱(运行时 dispatch table 隔离) |
| 宏调试复杂度 | 高(stack trace 难读) | 低(无宏展开) |
| Plugin 作者改 init 的能力 | 不能(宏展开覆盖) | 不能(根本没 init 可写) |
| Property 等价 | ✓ | ✓ |

**Phase 1 选路径 B**(详见 `docs/phase-specs/phase1/DECISIONS.md` P1-D2 + Decision Log #84):理由是 Phase 1 只有 Echo 一个业务 Kind,runtime 隔离风险接近零;property 收益(用户写不出 wrong init)对 Phase 1 dogfood loop 价值更大。Phase 2+ 加 Chat Behavior 时如果发现共享 Server 跟某些 Kind 的 state 假设冲突,届时评估是否需要切回路径 A 或两条并存。

**关键不变式**(两条路径都依赖):这个窗口的正确性依赖 §5.7.6 的硬不变式(inbound 永远走 dispatch,**不**裸 `PubSub.broadcast` 到 inbound topic)。Phoenix.PubSub 对没有订阅者的 topic **不** buffer——裸 broadcast 进 inbound topic 在 register→subscribe 窗口里**会被丢**(这正是事故 2.1 的本来面貌)。

**Phase 2 增补合约 — 统一 Behavior 消息转发器**(Decision #89):路径 B 的 `Ezagent.Kind.Server.handle_info/2` 同时充当所有 composing Behavior 的"非 dispatch 入站"转发点。任何不来自 `Ezagent.Invocation.dispatch/1` 的 GenServer 消息(`Process.monitor` 触发的 `:DOWN` / 外部 `send/2` 回调 / 未来 timer tick)都经此 mailbox,转发到每个 Behavior 的可选回调:

```elixir
@callback handle_kind_message(message :: term(), slice :: map(),
                              ctx :: %{kind_module: module(), self_uri: URI.t()}) ::
            {:ok, new_slice :: map()} | :ignore
```

返 `{:ok, new_slice}` 更新该 Behavior 的 slice;返 `:ignore` 不变。`Kind.Server` 仍**完全不感知**任何业务 Behavior——只查 `function_exported?/3` 后调用。Phase 2 Chat 用此 hook 实现 offline 状态机(`:DOWN` → last_seen)和 bridge→Agent reply 回路(`{:reply_received, _}` → 构造 Message + dispatch chat/send),Kind.Server 一行业务代码都不加。

**`ctx.kind_module` + `ctx.self_uri` 单点注入**(Decision #90):`Ezagent.Kind.Runtime.handle_dispatch/4` 在调用 `invoke_behavior` 前在 ctx 上 `Map.put` 这两个 key。Behavior 跨 Kind 时(Chat 的 `:receive` 分支 User vs Agent / Session 的 `:send` 用 self_uri 当 broadcast topic 前缀)需要它们,Adapter 构造 Invocation 时**不**填——是 runtime injection contract。

#### 5.7.5 `Ezagent.Invocation.dispatch/1` 内置投递路径选择

```elixir
def dispatch(%Invocation{mode: mode, target: target} = inv) do
  with :ok <- maybe_idempotency_check(inv),          # step 2.7
       :ok <- validate_args(inv),                     # step 2.5
       receiver_uri <- extract_receiver(target) do
    
    case {Ezagent.ReadyGate.status(receiver_uri), mode} do
      {:ready, _} ->
        # 标准路径:KindRegistry.lookup + cast/call
        case Ezagent.KindRegistry.lookup(receiver_uri) do
          {:ok, pid} -> deliver_to_pid(pid, mode, inv)
          :error     -> {:error, :no_such_actor}
        end
      
      {:not_ready, :cast} ->
        # 异步可 buffer
        Ezagent.PendingDelivery.buffer(receiver_uri, inv)
      
      {:not_ready, mode} when mode in [:call, :call_stream] ->
        # 同步调用不能 buffer——caller 阻塞等结果会撞 deadline_ms,
        # 必须 fail-fast 让 caller 自己决定重试
        {:error, :not_ready}
      
      {:unknown, _} ->
        {:error, :no_such_actor}
    end
  end
end
```

**plugin 作者从此只调 `dispatch/1` 一个 API**——投递保证、ready gate、idempotency、cap check、telemetry **全部自动**。隐式正确性 > 显式选择。

#### 5.7.6 何时用 `PubSub.broadcast` 而不是 dispatch — 硬不变式

`dispatch/1` 路径用于"投递给确定 receiver"(routing 算出 N 个 receiver,逐个 dispatch)。**`Phoenix.PubSub.broadcast`** 仍然用于另一类场景:

- **View 渲染**:Message 到达后,Chat Behavior 同时 broadcast 到 `<session_uri>:events` topic,View(LiveView / CLI / Feishu adapter)各自订阅渲染。**受众是不确定旁观者**,不需要 ready gate(view 没来就没渲染,语义上 OK)
- **Telemetry events**:`:telemetry.execute` 内部走 broadcast pattern,handler 自由 attach

**硬不变式(不是 guideline,是 §5.7.4 正确性依赖):inbound 消息永远走 `dispatch/1`,绝不允许裸 `PubSub.broadcast` 到 inbound topic**。

**Topic taxonomy(Phase 2 增补,Decision #93)**:`:events` 后缀是 view fan-out 的统一命名约定。当前在用:

| Topic 模板 | 谁广播 | 谁订阅 | 用途 |
|---|---|---|---|
| `esr:audit:stream` | `Ezagent.Audit` | LiveView /admin audit log + telemetry 观察者 | invocation 流式 |
| `esr:session:<session_uri>:events` | `Ezagent.ActionSet.Chat` (Session 侧) | LiveView /admin chat stream + 成员状态;Feishu/CLI adapter 渲染 | Chat 消息 + 成员 join/leave/offline |
| `esr:user:<user_uri>:events` | `Ezagent.ActionSet.Chat` (:receive 在 User Kind) | 该 User 的 inbox 渲染(LV 多个 view 共享 admin User) | 个人 inbox 通知 |
| `esr:bridge_v1:events` / `esr:bridge_v1:to_claude:<bridge_id>` | `Ezagent.Bridge.V1Prototype.Server` | LV bridge 状态 + SSE endpoint | v1_prototype bridge 协议(Phase 5 替换) |

新增 view fan-out topic 走 `:events` 后缀;`mix ezagent.check_invariants` #1 的 allowlist 列源文件(audit.ex / invocation.ex / chat.ex / ...),新加 broadcast 源码必须同步更新 allowlist。

理由:Phoenix.PubSub **不** buffer 没有订阅者的 topic 的消息。裸 broadcast 在 receiver 的 register→subscribe 窗口里**会被丢**——这正是事故 2.1 的根因。`dispatch/1` 通过 ReadyGate + PendingDelivery 接住这个窗口,broadcast 不行。

判断规则的简化记法:**有特定 receiver → `dispatch/1`;广播给不确定旁观者 → `PubSub.broadcast`**。前者必须有投递保证,后者本来就接受"晚来没看到"。`code review` 时 grep `PubSub.broadcast` 出现在 inbound 路径上 = bug。

> **Implementation**:三个 primitive 总共 ~65 LOC(ReadyGate ~20 / PendingDelivery ~25 / Idempotency ~20)。新增模块在 §14 LOC budget 反映。

---

## 6. Behavior

> **2026-05-28 — Router/Behavior/Kind contract migration complete (Phase 1-4).**
> The plugin authoring contract has been rewritten per SPEC PR #445
> (`docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`).
> Plugin Behaviors now opt into the new per-action declarative
> contract via `use Ezagent.ActionSet` + `action/3` macro +
> `handle_<action>/2` handlers returning effects. The legacy
> `Behavior.invoke/4` callback is `@optional_callbacks` only (no
> runtime path consults it after Phase 3 PR #464); plugin authors
> never see `slice` or `snapshot` directly. Read §6.0 first; §6.1
> below documents the legacy callback shape kept for grep-ability
> and Decision Log archaeology.
>
> Phase chronology (all merged to main):
> - **Phase 1 (#451)** — `Ezagent.Router` + `Ezagent.ActionSet` (new contract) + `Ezagent.Kind` + `LegacyBehaviorAdapter` primitives
> - **Phase 1.5 (#453) + 1.5b (#454)** — `Ezagent.Kind.Runtime` wires new-contract dispatch; effect executor complete
> - **Phase 2 (#462)** — 28+ domain Behaviors migrated to new contract (chat / identity / external-mirror / workspace / plugins)
> - **Phase 2.5 (#463)** — 6 remaining core Behaviors migrated
> - **Phase 3 (#464)** — `LegacyBehaviorAdapter` DELETED; `invoke/4` callback retired to `@optional_callbacks`
> - **Phase 4 (#469)** — `Kind.Server` attach metadata + `read_graph` cleanup + audit fix
> - **E2E tests (#465-#468)** — 165 passing E2E tests across the new pipeline
> - **E2E scenarios catalog (#452)** — 30 scenarios documented in `docs/scenarios/`

### 6.0 The new Router/Behavior/Kind contract (SPEC 2026-05-28)

Three primitives. Plugin authors touch only Behavior + Kind; the Router and the rest of the framework are plugin-invisible.

| Primitive | Owns | Plugin-author touches |
|---|---|---|
| **Router** (`Ezagent.Router`) | dispatch envelope `%Ezagent.Cmd{}`, URI canonicalisation, idempotency, cap check, workspace isolation, audit, effect application | NEVER calls directly; transport adapters (LV / CLI / Channel) construct `%Cmd{}` and hand to `Router.dispatch/1` |
| **Behavior** (`use Ezagent.ActionSet`) | the action namespace + how each action's effects are computed | declares `action :foo, args: %{...}, returns: ..., caps: [...]` + writes `def handle_foo(args, ctx) → {:ok, result, [effects]}` |
| **Kind** (`@behaviour Ezagent.Kind`) | URI identity, process lifecycle, attached Behavior list, composition pattern (Session / Entity / Resource) | declares Kind module + attaches Behaviors |

#### 6.0.1 Dispatch flow (ASCII)

```
  CLI / LV / Channel / Webhook
        │
        ▼
  builds %Ezagent.Cmd{target, action, args, ctx}
        │
        ▼
  Ezagent.Router.dispatch(cmd)
        │
        │   1. URI canonicalise   (Ezagent.URI.instance/1)
        │   2. Idempotency dedup  (ctx.command_uuid)
        │   3. ReadyGate consult  (:ready / :not_ready / :unknown)
        │   4. BehaviorRegistry.lookup({kind_module, action})
        │   5. Cap check          (step 5.5 — chokepoint)
        │   6. Workspace iso      (step 5.6 — cross-workspace gate)
        │   7. Args validate      (Behavior.@interface)
        │   8. Read framework state into ctx[:read].(key, default)
        ▼
  behavior.handle_<action>(args, ctx)
        │
        │   returns {:ok, result, [effect, ...]}
        │
        ▼
  Behavior.apply_effects/2   — pure bucketiser
        │
        ▼
  Kind.Runtime.apply_new_contract_effects/4
        │   bucket exec order (Phase 1.5b):
        │     State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations
        ▼
  framework writes: snapshot via SnapshotStore (every N events + on-terminate)
                    events via EventLog
                    PubSub broadcasts
                    cross-Kind Router.dispatch (sequential, in declared order)
                    SagaRunner for orchestration
        │
        ▼
  result post-process via Invocation.reply/2 per ctx.reply
```

#### 6.0.2 Effects vocabulary

The handler's return contract is `{:ok, result, [effect]} | {:ok, result} | {:error, reason}`. The effect list grammar (SPEC §4.4 — see `Ezagent.ActionSet` moduledoc for the executable @type):

| Effect | Shape | Meaning |
|---|---|---|
| `:set` | `{:set, key, value}` | Update this Kind's slice (framework writes via SnapshotStore) |
| `:emit` | `{:emit, event_name, payload}` | Append a row to EventLog (audit + event-driven subscribers) |
| `:dispatch` | `{:dispatch, %Ezagent.Cmd{}}` | Cross-Kind dispatch; framework re-enters Router |
| `:notify` | `{:notify, topic, payload}` | `Phoenix.PubSub.broadcast` (fire-and-forget) |
| `:effect` | `{:effect, mfa_or_fun, args}` | Side-effect fire-and-forget (caller wraps in try/rescue) |
| `:effect_returning` | `{:effect_returning, mfa_or_fun, args, bind_as: :name}` | Value-returning side-effect; result available to later effects via `{:ref, :name, [path]}` |
| `:saga` | `{:saga, %SagaRunner.Saga{}}` | Hand a linear saga to `Ezagent.SagaRunner` for forward + best-effort compensation |
| `:terminate` | `{:terminate, :self | URI.t()}` | Schedule a Kind termination AFTER reply lands |
| `:halt` | `{:halt, reason}` | Short-circuit; remaining effects skipped; SnapshotStore never sees the would-be new slice |

Ordering is normative: within each phase effects fire in declared order. Across phases the buckets execute in the fixed Runtime order above.

#### 6.0.3 Minimal Behavior — new contract example

```elixir
defmodule Ezagent.ActionSet.EntitySend do
  use Ezagent.ActionSet      # — new contract opt-in

  action :send,
    args:        %{recipient: :uri, body: :string},
    returns:     %{ok: :boolean},
    caps:        [:send],
    modes:       [:cast],
    description: "Send a message to another entity."

  # Required by `use Ezagent.ActionSet` — every declared action MUST
  # have a matching `def handle_<action>(args, ctx)`. Enforced at
  # compile time (raises CompileError otherwise).
  def handle_send(%{recipient: r, body: b}, ctx) do
    {:ok, %{ok: true},
     [
       {:set, :sends, ctx[:read].(:sends, 0) + 1},
       {:dispatch, %Ezagent.Cmd{
          target: r,
          action: :receive,
          args:   %{from: ctx[:caller], body: b},
          ctx:    %{caller: ctx[:self_uri], reply: :none}
        }},
       {:notify, "entity:#{ctx[:self_uri]}:sends", %{recipient: r}},
       {:emit, :message_sent, %{recipient: r}}
     ]}
  end
end
```

What plugin authors NEVER touch:

- `slice` as a structure — read via `ctx[:read].(key, default)`, mutate via `{:set, ...}` effect
- snapshot policy — framework-decided (every N events + on-terminate; see `Ezagent.SnapshotStore`)
- `Ezagent.EventLog` / `Ezagent.SnapshotStore` / `Ezagent.StateRebuilder` / `Ezagent.EventSubscriber` / `Ezagent.SagaRunner` directly — they are framework-internal (grep gate enforces; see SPEC §11)
- `Ezagent.Invocation.dispatch/1` from inside a handler — emit a `{:dispatch, %Cmd{}}` effect instead
- `Phoenix.PubSub.broadcast` — emit a `{:notify, topic, payload}` effect instead

#### 6.0.4 OQ decisions adopted

The SPEC's open questions resolved as follows (see SPEC §8 for full rationale):

| OQ | Decision |
|---|---|
| **OQ-1** Resource URI scheme | `resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>` — workspace segment mandatory (MED-1 codex closure) |
| **OQ-2** Pattern enforcement | Compile-time via `pattern: {:resource, :hot}` Kind macro arg + `:cold` default; checked by `@before_compile` |
| **OQ-5** Multi-Behavior-per-Kind action namespace | Flat with compile-time collision check (no prefix) |
| **OQ-6** Worker spawn pattern | `:hot_resource` (default `:ephemeral` + opt-in periodic) for ExternalMirrorWorker etc. |
| **OQ-8** Snapshot data migration | StateRebuilder lazy-on-first-load (Router calls `rebuild/1` on KindRegistry miss, NOT at app boot) |

#### 6.0.5 Framework machinery (plugin-invisible)

| Module | Owns | Plugin authors |
|---|---|---|
| `Ezagent.Router` | dispatch pipeline (§6.0.1) | call from adapters only; never from inside Behaviors |
| `Ezagent.EventLog` | `invocations` table append-only (Phase 1B Subagent B); event_name + payload + caller + workspace_uri + trace_id | NEVER import; emit via `{:emit, ...}` effect |
| `Ezagent.SnapshotStore` | per-Kind state snapshots; framework-decided every-N + on-terminate | NEVER import; framework writes on slice change |
| `Ezagent.Kind.StateRebuilder` | rebuild Kind state from latest snapshot + (Phase 2+) event fold; lazy-on-first-load (OQ-8) | optional `rebuild_from_snapshot/1` callback for custom semantics; default works for most Kinds |
| `Ezagent.SagaRunner` | stateless linear saga with best-effort compensation | hand a `%Saga{}` to `{:saga, _}` effect; don't call directly |
| `Ezagent.EventSubscriber` | declarative event-driven cross-Kind reactions; `use Ezagent.EventSubscriber` macro | declare subscriber + `handle_event/2` returning the SAME effect vocabulary; framework re-enters Router |
| `Ezagent.Kind.Runtime` | in-process dispatch flow inside a Kind GenServer; bucket execution order | not directly callable; runs as part of `Ezagent.Kind.Server` |

#### 6.0.6 LegacyBehaviorAdapter — DELETED (Phase 3 PR #464)

For git archaeology purposes: `Ezagent.LegacyBehaviorAdapter` existed in Phase 1 (PR #451) and Phase 2 (PR #462) as a dispatch-equivalent (NOT replay-equivalent) bridge from the new `Cmd` / handler-effects pipeline to legacy `invoke/4` Behaviors. Phase 3 (PR #464) **deleted the adapter** + **retired `invoke/4` to `@optional_callbacks`** once every concrete Behavior had migrated. The `@callback invoke/4` declaration is kept in `Ezagent.ActionSet` only so a stale Behavior referencing it surfaces a precise CompileError rather than a silent dispatch failure. No runtime path consults `invoke/4` post-Phase-3.

If you find a tutorial / blog post / forensic note referencing `Behavior.invoke/4` as the dispatch entry point, it predates 2026-05-28 and is stale.

#### 6.0.7 Lifecycle API — the SOLE developer surface (SPEC 2026-05-29, Phase A/B/C)

**`use Ezagent.Lifecycle` is the only developer-facing way to author a Behavior.** The `use Ezagent.ActionSet` + hand-rolled `state_slice/0` / `init_slice/1` surface described in §6.0 is now **INTERNAL ENGINE only** — the Lifecycle macro compiles down to it (R10-3). The §11 naming principles + the Phase C grep gates (`mix ezagent.check_invariants.lifecycle`) HARD-fail CI if a developer-tier file re-introduces the old surface.

R/B/K (Router / Behavior / Kind) are the **internal engine**; Lifecycle is the **public API**. A plugin or domain author never writes `use Ezagent.ActionSet`, never declares `state_slice`, never implements `init_slice` / `invoke/4` / `post_init` / `handle_continue` / `on_ready` / `reconcile_after_load`.

**Two-container state model** (the core idea — kills the cold-restart bug class by construction):

| | `state` | `transients` |
|---|---|---|
| Persisted? | YES — framework auto-snapshots | NEVER — no serialization path exists |
| Holds | domain data (members, conversation, config, caps) | PIDs, refs, ETS handles, ports, subprocess handles, monitor refs, cached connections |
| Built by | `create/1` (first-ever) + `{:set, k, v}` effects | `activate/2` — rebuilt EVERY start; `{:set_transient, k, v}` effects |
| Read via | `ctx.read.(key, default)` (or `ctx[:read]` — kept) | `ctx.transients[key]` |
| Survives restart? | YES (durable) | NO — `activate` rebuilds from `state` (+ external SoT) |

A transient **cannot** be accidentally persisted (no serialization path) and **cannot** be forgotten on restart (`activate` is the ONLY place it is built, and `activate` runs on every start — fresh spawn AND cold-load).

**The lifecycle hooks** (all optional except `handle_<action>` for declared actions):

| Hook | When | Returns | Purpose |
|---|---|---|---|
| `create(args)` | FIRST-EVER existence (gated by the `ever_created` `kind_snapshots` column, OQ-1) | `{:ok, state}` | build initial PERSISTENT state; NO transients |
| `activate(state, ctx)` | EVERY process (re)start — fresh, supervisor-restart, AND cold-load — runs PRE-`:ready` | `{:ok, transients}` \| `{:ok, transients, state}` (reconcile) | (re)build ALL transients; self-heal/orphan-reap; reconcile DB-projection state |
| `handle_<action>(args, ctx)` | one per declared `action` | `{:ok, result, [effect]}` | UNCHANGED effect grammar (§6.0.2) + `{:set_transient, ...}` (OQ-2) |
| `handle_signal(message, ctx)` | non-action GenServer msgs (`:DOWN`, PubSub, self-deferred mailbox) — successor to `handle_kind_message/3` (OQ-3) | effect list | mutate state/transients off a signal |
| `activated(state, ctx)` | AFTER the `ReadyGate` flips (POST-`:ready`) — rare; rename of `on_ready` (OQ-5) | `{:ok, transients}` | reachability broadcasts that invite peer `:call` round-trips |
| `pre_handle(action, args, ctx)` | BEFORE the matched handler | `:cont` \| `{:cont, args}` \| `{:halt, result}` \| `{:error, reason}` | cross-cutting authz / arg-rewrite |
| `post_handle(action, result, effects, ctx)` | AFTER the handler, before effects execute | `{:ok, result, effects}` \| `:cont` | audit / effect injection |
| `deactivate(reason, ctx)` | graceful stop, entity PERSISTS (OTP terminate; best-effort) | `:ok` only | side-effecting external cleanup; CANNOT mutate persisted state (F5) |
| `destroy(reason, ctx)` | PERMANENT deletion; framework clears `state` + the ever-created marker (best-effort) | `:ok` | cleanup that must also be self-healed in the next `activate` |

**§10 binding rules** baked in: R10-1 self-deferred (`send(self(), …)`) boot work goes in `activated`/`handle_signal`, NOT `activate` (which is pre-`:ready`). R10-2 `{:set,…}` + `{:set_transient,…}` are pure pre-commit map reductions — only `state` is snapshotted; a `transients` change never triggers a snapshot write. R10-3 the engine `Ezagent.ActionSet` contract STAYS (the macro's compile target). R10-4 the snapshot WIPE cutover is a verified ordered sequence (stop all nodes → deploy → delete `kind_snapshots` → restart).

Minimal Lifecycle Behavior:

```elixir
defmodule Ezagent.Lifecycle.Counter do
  use Ezagent.Lifecycle

  action :bump, args: %{}, returns: %{count: :integer}, caps: [:bump], modes: [:cast]

  def create(_args), do: {:ok, %{count: 0}}
  # No transients → activate may be omitted (the macro injects a no-op).

  def handle_bump(_args, ctx) do
    n = ctx.read.(:count, 0) + 1
    {:ok, %{count: n}, [{:set, :count, n}]}
  end
end
```

The `state_slice` snapshot-compat hatch: `use Ezagent.Lifecycle, state_slice: :legacy_key` + a `# lifecycle:state_slice_override` marker comment (the Phase C gate sanctions only marked overrides). See SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §2 / §3 / §9.

### 6.1 Legacy Behavior callback (retired — `@optional_callbacks` only)

```elixir
defmodule Ezagent.ActionSet do
  # — superseded by §6.0 new contract.
  # Retained here purely as @optional_callbacks for grep-ability +
  # legacy-callsite CompileError surfacing. No runtime path consults
  # invoke/4 post Phase 3 (PR #464).
  @callback actions() :: [atom()]
  @callback state_slice() :: atom()
  @callback init_slice(args :: map()) :: map()
  @callback invoke(action :: atom(), slice :: map(), args :: map(), ctx :: map()) ::
              {:ok, new_slice :: map()}
            | {:ok, new_slice :: map(), result :: term()}
            | {:ok, new_slice :: map(), stream :: Stream.t()}   # :call_stream
            | {:error, reason :: term()}
end
```

### 6.2 `@interface` — 强制 schema 声明

每个 Behavior **必须**声明 `@interface`:

```elixir
@interface %{
  <action_atom> => %{
    args:    %{ <field> => <type_spec> },
    returns: %{ <field> => <type_spec> },
    errors:  [<atom>],
    modes:   [<mode>]
  }
}
```

Type spec 用 Elixir-style atom/tuple notation(`:string`、`:integer`、`{:tuple, :integer, :integer}`、`{:list, :string}`、`{:option, :string}`、`:map`、`:uri`、`%{<field> => <ty>}`)。v0 用 compile-time 简单 check;runtime 强校验 deferred 到 v0.2+。

Phase 2 加 `:uri` primitive(Decision #92):匹配 `%URI{}` struct,**拒绝裸字符串**。Chat 的 `@interface` 用它声明 `sender: :uri`、`mentions: {:list, :uri}` 等典型 URI 字段。这与 `Ezagent.Ecto.URI` 自定义 Ecto type 配合,实现 URI 跨进程/跨持久化层始终是 struct,字符串只出现在 dump/load 的边界。

`@interface` 是所有 adapter 的生成源:

| Adapter | 从 `@interface` 生成 |
|---|---|
| CLI(Optimus) | `$cli movable move --x 1 --y 2` parser |
| Slash | `/move 1 2` parser + help text |
| HTTP / REST | `POST /api/agents/{id}/behaviors/movable/actions/move` + OpenAPI yaml |
| MCP | tool exposed to Claude Code / Python clients |
| LiveView(未来) | form schema |
| ExUnit | `mix ezagent.gen.test` 模板 |
| Invocation.dispatch | args validation |

`@command` tag 在 v0.2 描述过,v0.3 **删除**——它就是 `@interface.modes` 列表里有 `:call` 加上该 Behavior 出现在 CLI/Slash registry 里;不是新概念。

### 6.3 Standard Behavior library

`ezagent_core` 不强制依赖任何具体 Behavior。但 Ezagent 提供一组**标准 Behavior**,分布在 `ezagent_domain_*` 和 `ezagent_plugin_*` 里。

**Post-2026-05-28 (Phase 1-4 migration完成)**:每个 Behavior 通过 `use Ezagent.ActionSet` 声明,用 `action :foo, args: %{...}, returns: ..., caps: [...]` 宏 + `def handle_foo(args, ctx)` 处理器 + effect 返回(§6.0)。`state_slice/0` + `init_slice/1` + `required_caps/0` + `cap_subjects/0` + `interface/0` 由宏在 `@before_compile` 自动派生,plugin 作者不再手写。`invoke/4` callback 是 `@optional_callbacks`(Phase 3 PR #464 后无 runtime 路径调用),保留只为 grep + 撞墙 CompileError。

#### Domain Behaviors (load-bearing — 不能卸载)

下表为 2026-05-26 时点 `find apps/ezagent_domain_*/ -name '*.ex' -exec grep -l '@behaviour Ezagent.ActionSet'` 的实际产出 — 运行时 SoT 仍是 `Ezagent.BehaviorRegistry.list_all/0`,本表只作 orientation。

| Domain | Behavior 模块 | 用途 |
|---|---|---|
| `ezagent_domain_instance_message` | `Ezagent.ActionSet.Chat` | Entity-Entity Message 接收 + 路由(session 内消息流的主 Behavior;`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex`) |
| `ezagent_domain_instance_message` | `Ezagent.ActionSet.Template` | Template lifecycle(`:fork` / 材料化) |
| `ezagent_domain_instance_message` | `Ezagent.ActionSet.Publisher.SessionImpl` | Publisher 的 Session-specific 实现(slice-change 流的下行 sink) |
| `ezagent_domain_identity` | `Ezagent.ActionSet.Identity` | principal_id、display_name、cap 管理(grant/revoke) |
| `ezagent_domain_identity` | `Ezagent.ActionSet.ApiKeys` | API key issuance + revocation |
| `ezagent_domain_identity` | `Ezagent.ActionSet.UserCredentials` | `:set_password`(PR #356 拆分) |
| `ezagent_domain_identity` | `Ezagent.ActionSet.UserTokens` | `:mint` / `:list` / `:revoke` token lifecycle(PR #356 拆分) |
| `ezagent_domain_identity` | `Ezagent.ActionSet.WorkspaceUserAdmin` | `:create_user` 特权 action carve(PR #356 codex r1 CRIT 修复)— 注意 carve 后落在 `domain_identity` 不是 `domain_workspace` |
| `ezagent_domain_workspace` | `Ezagent.ActionSet.Workspace` | `:add_member` / `:remove_member` / `:list_members` |
| `ezagent_domain_pty` | `Ezagent.ActionSet.Pty` | PTY 子进程驱动(底层 `:ex_pty`) |
| `ezagent_domain_external_mirror` | `Ezagent.ActionSet.ExternalMirror` | bind/unbind 外部目标的 facade Behavior |
| `ezagent_domain_external_mirror` | `Ezagent.ActionSet.ExternalMirrorWorker` | per-binding Worker Kind 的 `:publish` Behavior |
| `ezagent_domain_external_mirror` | `Ezagent.ActionSet.Publisher` | slice-change 流订阅入口(binding 通过 `subscribe_from/3` 订阅) |
| `ezagent_core` | `Ezagent.ActionSet.Lifecycle` | 注册到 Session / Agent — terminate / spawn 状态机 |
| `ezagent_core` | `Ezagent.ActionSet.Routing` | 注册到 routing 作用域的 Kind — routing rules 编辑 |
| `ezagent_core` | `Ezagent.ActionSet.Presence` | LV 在线状态 |
| `ezagent_core` | `Ezagent.ActionSet.Sandbox` | 受控 sandbox 操作 |
| `ezagent_core` | `Ezagent.ActionSet.Notifications` | cap-only(`dispatchable?/0 → false`)— `:subscribe` cap subject;Boot 时为每个新建 User 默认授予自己 URI 上的 cap |

#### Plugin Behaviors (可选)

| Plugin | Behavior | 用途 |
|---|---|---|
| `ezagent_plugin_feishu` | `EzagentPluginFeishu.Behavior.UserBinding` | feishu_open_id ↔ user URI 绑定(PR #355 case study — per-Kind chokepoint;模块位于 `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/user_binding.ex`) |
| `ezagent_plugin_feishu` | `EzagentPluginFeishu.Behavior.FeishuAllow` | cap-only — 授权 session 被 Feishu adapter bind |
| `ezagent_plugin_echo` | `Ezagent.ActionSet.Echo` | 注册到 echo-flavor Agent — 测试 / 参考 stub |
| `ezagent_plugin_curl_agent` | `Ezagent.ActionSet.CurlAgent` | 注册到 curl-flavor Agent — HTTP API agent |
| `ezagent_plugin_np` | `Ezagent.ActionSet.NpAgent` | 注册到 NpAgent 测试 agent flavor |

**`ezagent_plugin_cc` 不导出 Behavior**:CC 集成走 Template Class(`Ezagent.Template.CcAgent`)+ `Ezagent.PluginCc.Channel` 通道,**不通过 Behavior 模块**。cc-flavored agent 在 `entity://agent/<workspace>/cc_<name>` 形态下注册,但其 chat-routing 落在共享的 `Ezagent.ActionSet.Chat`(在 Agent Kind 上注册的 `:receive` action)。

完整 Behavior list 维护在 `Ezagent.BehaviorRegistry.list_all/0` 运行时 ETS — 是 SoT。

**OSProcess 的例子**(原 v0.2 `os-process` Process impl 的归位):

```elixir
defmodule Ezagent.ActionSet.OSProcess do
  use Ezagent.ActionSet   # post-2026-05-28 new contract

  action :spawn,
    args:    %{cmd: :string, args: {:list, :string}, env: :map},
    returns: %{pid: :integer},
    caps:    [:spawn],
    modes:   [:call]

  action :write_stdin,
    args:    %{data: :string},
    returns: %{},
    caps:    [:write_stdin],
    modes:   [:cast]

  action :kill,
    args: %{signal: {:option, :atom}}, returns: %{}, caps: [:kill], modes: [:call]

  action :status,
    args: %{}, returns: %{running: :boolean, pid: :integer}, caps: [:status], modes: [:call]

  def state_slice, do: :os_process
  def init_slice(_), do: %{erlexec_pid: nil, os_pid: nil, exit_code: nil}

  def handle_spawn(%{cmd: cmd, args: args, env: env}, _ctx) do
    {:ok, pid, os_pid} = :exec.run([cmd | args],
      [:stdout, :stderr, :stdin, :monitor,
       env: env |> Map.put("EZAGENT_SPAWN_TOKEN", new_token())])
    # stdout/stderr 经 erlexec message → Kind.Server handle_info → :notify effect
    {:ok, %{pid: os_pid},
     [
       {:set, :erlexec_pid, pid},
       {:set, :os_pid, os_pid}
     ]}
  end

  # … handle_write_stdin / handle_kill / handle_status …
end
```

**关键不变式**:外部进程的生命周期严格绑定 Kind GenServer。

- Kind GenServer 是 erlexec port 的 owner
- GenServer `terminate/2` **必须** kill 外部进程(否则孤儿)
- erlexec 启动带 `:monitor` 选项,外部进程死了 GenServer 收到 `{'EXIT', os_pid, _}` → 决定重启或上报
- `EZAGENT_SPAWN_TOKEN` 注入子进程 env,防野生 worker 绑回
- Per-boot orphan cleanup:`Application.start/2` 扫一次 `/tmp/esr-worker-*.pid` 杀掉残留

`Ezagent.ActionSet.Pty` 同构,只是底层是 `:ex_pty`。

### 6.4 三条 Behavior 设计纪律

1. **永远不依赖其他 Behavior** — 跨 Behavior 数据通过 `ctx` 传(典型:`ctx.caller`)
2. **state_slice key 用 Behavior 模块名做命名空间** — 避免 plugin 之间偶然碰撞
3. **不可读其他 slice** — 想要跨 Behavior 协调,定义新 Behavior + 新 action,显式编排

---

## 7. CapBAC

### 7.1 模型

- **粒度**:Behavior × action 级。持有 `cap(Kind, Behavior, action)` 即可在该 Kind 上调用该 Behavior 的某 action。多 action 的 Behavior 当前(2026-05-26)在 `Capability` 上仅匹配 kind+behavior+instance+workspace,**没有 action 轴** — 多 action Behavior 用"特权 action 单拆 Behavior"模式 (e.g. `Ezagent.ActionSet.WorkspaceUserAdmin.:create_user` 从 `Workspace` 拆出 — PR #356 codex r1 CRIT 修复)
- **携带方式**:Push。Caller 在 `ctx.caps` 装 `MapSet<Capability>`
- **校验点**:Kind instance,Invocation flow **step 5.5** — `Ezagent.Kind.holds_cap?/3` chokepoint(三参数 dispatcher,内部走 Kind 的可选回调 `holds_cap?/2` 或 `Ezagent.Kind.default_holds_cap?/2`)(PR-CC-2-v2, 2026-05-25)
- **校验函数**:dispatcher 对 `Behavior.required_caps()[action]` 中每个 cap 模板调一次 `Ezagent.Kind.holds_cap?(entity_uri, kind_module, needed_cap) :: boolean()`;Behavior 通过 `required_caps/0` 声明所需 cap 模板,Kind 通过(可选)`holds_cap?/2` 回调或缺省的 `Ezagent.Identity.list_caps_for/1` + `Capability.matches?/2` 决定 caller 是否持有该 cap (Behavior × Entity 边界关切)

> **Implementation**:`MapSet` + struct,~30 LOC。**不用第三方 ACL 库**。

#### Chokepoint 边界关切 (PR-CC-2-v2, 2026-05-25)

cap 检查是 **Behavior × Entity 边界关切**,**严格只在 dispatch step 5.5 发生一次**。LV `handle_event` / controller / Behavior body 内的 `Capability.matches?/2` 调用全部被 `cap_check_only_at_chokepoint_test.exs` invariant 禁止(生产代码,定义 chokepoint 自身除外)。LV 的"前置 cap 检查"(用来藏按钮)只允许作为防御性 hint,**不能**是权威源 — 权威源永远是 dispatch step 5.5 跑过的 `Ezagent.Kind.holds_cap?/3` 返回。

#### Behavior `required_caps/0` + `cap_exempt_actions/0`

每个 Behavior 实现 `required_caps/0 :: %{required(action :: atom()) => Ezagent.Capability.t()}` — 每个 action 对应**单个** cap 模板(不是 list):

```elixir
@impl Ezagent.ActionSet
def required_caps do
  %{
    send:  Ezagent.Capability.cap(:session, __MODULE__, :send),
    join:  Ezagent.Capability.cap(:session, __MODULE__, :join),
    leave: Ezagent.Capability.cap(:session, __MODULE__, :leave)
  }
end
```

若某 action 不需 cap-gate(只读 inspection / `:status` probe 等),Behavior 通过可选 `cap_exempt_actions/0 :: [atom()]` 显式声明 — 编译时 `:ezagent_plugin_check` 验证 `keys(required_caps) ∪ cap_exempt_actions == actions`。`dispatch_uses_required_caps_struct_test.exs` invariant 验证 `Ezagent.Kind.Runtime` 实际 consult `behavior_module.required_caps()` + `Ezagent.Kind.holds_cap?` + `Ezagent.ActionSet.workspace_scoped?` 在 step 5.5 / 5.6,并要求生产 Behavior 都实现 `required_caps/0`。

#### 构造帮手:`Capability.cap/3` 和 `cap/5`

`Ezagent.Capability` 暴露两个构造帮手:

- `cap(kind, behavior, action)` — 通用模板,instance/workspace 留 `:any`
- `cap(kind, behavior, action, instance, workspace_uri)` — 具体 cap

action 字段当前(2026-05-26)在 `matches?/2` 中**不参与比较** — 见 docs/futures/todo.md "Capability struct lacks an action axis"。作为过渡,新加的 Behavior 把特权 action 单拆成专用 Behavior(`WorkspaceUserAdmin.:create_user` / `UserCredentials.:set_password` / `UserTokens.:mint`/`:list`/`:revoke` / Feishu `UserBinding`/`SessionBinding`),以保证 cap 持有者只能调用预期 action。SPEC 级的 action 轴变更跟踪在 todo.md 中。

### 7.2 Scope 三档

```elixir
instance: URI.t()                       # 限定到具体实例
instance: :any                          # 该 Kind 的所有实例
instance: {:within_session, session_uri}  # 同 session 内的所有实例(n×n 友好)
```

n×n 场景:Session 内的 agents 默认互通,逐条 grant 太碎,用 `{:within_session, session_uri}` 一次性覆盖。跨 session / 跨域仍走显式 grant。

### 7.3 默认 capability

| 场景 | 默认 cap |
|---|---|
| Plugin 注册 KindType 时声明 default_caps | scope 必为 `:self`(最小权限) |
| Creator 创建实例 | 自动获得该实例所有 Behavior 的 cap(全权) |
| Session 内 agent 加入 | 自动获得 `{:within_session, session_uri}` 的标准 cap 集 |
| User 创建(任意路径:LV / `mix ezagent.user.create` / Feishu bind) | 自动获得 `Ezagent.Entity.User.default_caps()` 返回的结构性基线 cap;当前是 `kind=:session behavior=:any instance=:any granted_by=system://bootstrap`(Decision #133, Phase 6 PR 27)。**`:any` 是循环依赖妥协**(`ezagent_domain_identity` 不能引用 `ezagent_domain_instance_message` 的 `Ezagent.ActionSet.Chat` 模块),不是"默认 cap 该用通配符"的 idiom。`Ezagent.Domain.Identity.Users.create/3` prepend 到 caller caps;`EzagentPluginFeishu.BindingPolicy.apply/2` 对 pre-PR-27 user 在 bind 时 idempotent 补齐 |
| 其他获取方式 | 必须显式 grant(v0 不支持 delegation) |

`:self` 在 grant 时立即解析成具体 URI(**grant-time resolution**)——cap 内容凝固不变。

> ⚠️ **本表的 `User.default_caps()` 行已 superseded**(见 §7.7 + `capbac.md` §6):per-session refactor 后 `default_caps(workspace_uri)` 返回 **`[]`**,fresh user 不再持任何 standing session cap;session 参与(`:send`/`:join`)在 join 时由 session owner per-session grant。此处保留仅为历史 context。

### 7.4 Push → Token 迁移路径

v0 Push;未来 Token(macaroon / biscuit / signed JWT)。**迁移成本极低**:

```elixir
# v0
ctx.caps  :: MapSet<%Ezagent.Capability{}>
# 验证: Enum.any?(ctx.caps, &Ezagent.Capability.matches?(&1, needed))

# vN
ctx.token :: %Ezagent.Token{}
# 验证: Ezagent.Token.verify(ctx.token, needed, signing_key)
```

只换 step 5.5 的 verifier,Invocation flow / Behavior / Kind 全不动。

### 7.5 不做(v0)

- ❌ Delegation(持有者转授他人)
- ❌ Attenuation(部分授权)
- ❌ Revocation graph

### 7.6 System principals — bootstrap admin + closed dispatch-principal allowlist (PR-CC-1, 2026-05-25)

Ezagent 的 cap 系统有**两类**系统 principal,概念上分开但都不可 revoke:

1. **User Kind admin singleton** = `Ezagent.Entity.User.admin_uri()` = `entity://user/system/admin`(SPEC v3 3-segment)。系统首次启动时 `Ezagent.Bootstrap` 创建,持 all-caps(`%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any, granted_by: "system://bootstrap"}`)。`Identity.admin?/1` 唯一对这个 URI 返 true。这是**用户身份层**的 admin。
2. **System dispatch principals** = `Ezagent.SystemPrincipal.Catalog` 内 14 个 `system://<name>` URI(`system://bootstrap`、`system://boot-reconciler`、`system://chat-router` 等)。每个配套专属 cap 声明,用于系统内部 dispatch 流(boot 期 reconciler / chat fan-out router / template materialize / 等),**不是用户身份**。这是**dispatch principal 层**的 admin,由 PR-CC-1 引入封闭化散见的 ambient authority 模式(Behavior body 里假装是 user admin 的隐式提权)。

**PR-CC-1 (2026-05-25) 的核心变更**:把以前 Behavior body 里散布的"以 admin 身份做事"模式(`URI.parse("system://bootstrap")` 内联合成 + 用合成 URI 拿 `admin_caps()`),收敛到 `Ezagent.SystemPrincipal.Catalog` 封闭 allowlist。每个 system dispatch principal 拿到**结构性收窄的 cap**,而不是全 wildcard。

#### `Ezagent.SystemPrincipal.Catalog` — 14 个 system principal 的封闭 allowlist

Catalog 是 `ezagent_core` 内 14 个 `system://<name>` URI 的封闭枚举(`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`),每个 URI 配套该 principal 持有的 cap 集 + 用途描述:

```elixir
defmodule Ezagent.SystemPrincipal.Catalog do
  def entries do
    [
      {"system://bootstrap", [bootstrap_wildcard()]},
      {"system://boot-reconciler", [Capability.cap(:session, ExternalMirror, :any)]},
      {"system://chat-router", [bootstrap_wildcard()]},      # 开放 plugin 集 :receive fan-out
      {"system://chat-reply",  [bootstrap_wildcard()]},      # 同上
      {"system://worker-publish", [Capability.cap(:external_mirror_worker, ExternalMirrorWorker, :publish)]},
      # ... 9 more — system://template-materialize, system://orchestrator-tools,
      # system://session-internal, system://agent-internal, system://workspace-loader,
      # system://lv-anon-mount, system://lv-loader, system://test-bootstrap, system://mix-task
    ]
  end

  def member?(uri), do: ...
  def caps_for!(uri), do: ...  # 不在 catalog 抛
  def uris, do: ...
end
```

`Ezagent.SystemPrincipal`(`system_principal.ex`)是 Catalog 的 runtime 封装,暴露 `ensure/1`(幂等 spawn principal 为 User-shape Entity 让 dispatch 看到正确 cap 集)+ `caps/1`(legacy 兼容入口,PR-CC-2b 之后替代为 cap-snapshot 契约)。

**结构性不变式**:

- `no_wildcard_system_principals_test.exs`(`apps/ezagent_core/test/invariants/`) — 验证 Catalog 内**非 bootstrap、非 mix-task、非 chat-router/chat-reply 的 system principal 不得持有 full-wildcard cap**。仅这 4 个 URI 由部署契约 / 开放 plugin fan-out 结构性需求允许 wildcard;其他 10 个必须是窄 cap。这是数据层 invariant — 它**不是** grep 内联 URI 合成的 gate(那是另一回事,由 SystemPrincipal 模块边界 + code review 把关)。
- `Identity.admin?/1` 仍只对 `Ezagent.Entity.User.admin_uri()`(即 `entity://user/system/admin`)返 true — 这是用户身份层的 admin singleton,与 Catalog 中的 dispatch principal **完全两回事**。

#### Bootstrap admin 的 all-cap 不可 revoke

**`entity://user/system/admin` 的 all-cap 不可 revoke**。`Ezagent.Capability.revoke/2` 在 step 1 检查 subject 是不是 `Ezagent.Entity.User.admin_uri()` + cap_is_all — 若是,拒绝。**集中在 `revoke/2` 路径里检查,不允许调用方加 if 绕过**。理由:bootstrap principal revoke 会让系统永远无法授权——自锁死。这个检查是**架构 invariant**,不是 policy(policy 可以变,invariant 不能)。

未来多 user 场景:管理员通过 `entity://user/system/admin` 创建普通 user,授予部分 cap;`entity://user/system/admin` 自身不能被普通 user 影响(普通 user 没有该 URI 上的 `Identity.:grant_cap` cap)。

#### Workspace-scoped principal (PR-CC-2-v2, 2026-05-25)

`Behavior.workspace_scoped?/0` 在 dispatch **step 5.6** 强制执行 workspace 隔离 — 默认 `true` (per-tenant Kind)。返回 `false` 的 Behavior 跨 workspace 可调用 (e.g. system-scoped 配置读取)。`workspace_sot_test.exs` invariant 验证 workspace URI 段是权威 (而非 WorkspaceRegistry — registry 是 cache,URI 段才是 SoT)。

### 7.7 Grant 模型:ISSUE → STORE → VERIFY(cbac-done-right Phase-3,landed main `fa72d36ba` 2026-07-12)

§7.1 描述的是"caller 在 `ctx.caps` 携带 cap,step 5.5 检查"的 **dispatch-side** 模型 —— 那部分不变。**变的是 grant 本身**:一个 grant 不再是"一次 issuer→grantee 的 dispatch 直接写 grantee 的 `:caps` slice",而是三个可分离步骤,权威从 **issuer → artifact**,存储只走 **grantee 自己**。`granted_by` = issuer。

- **ISSUE — `Ezagent.Cap.issue/3`**:grantor 载入自己的 authority、跑完整 grant 授权(`CapabilityRegistry.authorize_grant/3`)、成功后 stamp `granted_by`=issuer 产出一个 artifact。**不向 grantee 转移 authority**。四个授权 tag(`{:held_by}`/`{:admin}`/`{:rule}`/`{:genesis}`)不变,`Ezagent.Identity.Grant` 仍是唯一 grant/revoke constructor(内部经 `Cap.issue`)。
- **STORE / absorb**:grantee 自存 —— `create/1` self-store(keyed entity lifecycle 读自己 pre-issued artifacts via `Cap.verified_set/1`)或 `:vm_internal` `absorb_cap` cast(`handle_absorb_cap/2` 只收 `:vm_internal` caller)。same-BEAM/same-node,无 cross-node absorb transport。
- **VERIFY — `Ezagent.Cap.verify/1`**:total + fail-closed,只在 ≤5 个 reviewed load/store 边界跑;Phase-3 查 provenance format(entity-scheme `granted_by`),是 Phase-4 签名验证的 stand-in(seam 换 body 不动 caller)。**(⚠ 已被 Path A 取代,2026-07-18 修正:`Ezagent.Cap.verify/1` 已**下线**;born-signed 存储过滤现走 `Cap.storable_for?`/`verified_set`,dispatch 侧密码学验签现走 `Cap.Verifier`/`Authority.verify_current` —— 见 §7.8。不要再当作 "provenance-format stand-in / crypto 待做"。)**
- **`RecipeCapBinding`**:agent 存在前 pre-issued recipe caps 的 durable home(`issue_and_upsert/4`);persistence 从不向 grantee dispatch cap 写。
- **I12 paradigm-lock**(`cap_self_store_paradigm_lock_test.exs`)禁 issuer→grantee dispatch;~16 legacy grant driver shrink-only ratchet;recipe/orchestrator/workspace 三 cold-agent cutover zero-tolerance。dispatch 侧 `cap_issued` runtime bypass 只由 chokepoint 在 `Cap.issue` 成功后 stamp(N1 `cap_issued_bypass_trust_keys_test.exs` pin)。

**scope(Phase-3 历史框架)**:single-BEAM / trusted-node。**(⚠ 2026-07-18 修正:"crypto = Phase-4 待做" 已过时 —— per-Kind ed25519 签名 + 严格验签已作为 **Path A** 落地(PR #1457,merged 2026-07-18)。cap 现在 **born-signed + strict-verify**;`issue/3` 让 target Kind authority 签名,dispatch 侧 `Cap.Verifier` 强制验签,`verify/1` 已下线。cross-node transport 与 in-VM-恶意防护 = **Path B**,仍 deferred。见 §7.8。)** **current source of truth**:`.claude/skills/ezagent-developer/references/capbac.md` §4.5–§4.6;GLOSSARY Decision #162/#164 + §2 "ISSUE / STORE / VERIFY" + "Cap authority & signing(Path A)" 条。

### 7.8 Capability authority & signing — Path A born-signed strict-verify(landed main,PR #1457,merged 2026-07-18)

> **状态(current — 读这段,别再复述过时说法):cap 是 born-signed + 严格验签的。** 不要再假设 "cap 验证是 permissive / 还有 dual-read / cap-signing 严格版还没做 / crypto 是 Phase-4 待做"。§7.7 描述的 Phase-3 ISSUE→STORE→VERIFY *流程* 仍在,但它的 **VERIFY 机制已换成真密码学**——`Ezagent.Cap.verify/1`(那个只查 provenance-format 的 stand-in)**已下线**。

**每个 target Kind 是它自己的签名 + 验签 authority**,用它**自己的 per-Kind ed25519 key**;key 材料住在一个 framework-owned compartment,永不进 slice / snapshot / handler ctx / event / log / 通用 admin listing。外部 caller 只拿到 capability artifact,拿不到 key material。

- **Authority compartment** — `Ezagent.Cap.Authority`(`apps/ezagent_core/lib/ezagent/cap/authority.ex`)。live 的 authority struct 是 `Kind.Server` 私有 top-level state(`@derive {Inspect, except: [:private_key]}`,`@opaque`);durable custody 是**独立 top-level 表** `kind_cap_authorities`(`Ezagent.Ecto.KindCapAuthority`,`apps/ezagent_core/lib/ezagent/ecto/kind_cap_authority.ex`)—— append-only、按 `generation` 记录、one-active-per-URI、`private_key` `redact: true`,无 delete API。**key 不在 env var**(旧 `EZAGENT_SIGNING_SEED_V1` master-seed 方案随 #1457 退役,prod 代码 + config 0 引用),**也不在 `kind_snapshots`**。**Genesis 是单一 admin-pinned root**:`genesis/2` 首次为一个 Kind 建 authority 时先播种 `entity://user/system/admin` 的 authority,`regenesis/3` 要求 presenter == `admin_uri()`,否则 `:admin_required`。
- **Sign at issue(born-signed)** — `Ezagent.Cap.issue/3`(`cap.ex`)授权 issuer 后,请求**具体 target Kind 的 authority** `Authority.sign/2` 对不可变 grant intent 做 ed25519 签名(`key_id` = per-Kind public key 的 sha256 指纹)。cap **一出生就带签名**。`granted_by` 仍是 real-entity issuer(承 #154/#162 provenance 不变)。
- **Storage filter(结构性,非授权决定)** — `Ezagent.Cap.storable_for?/2` + `verified_set/2`(`cap.ex`)。只有 born-signed(非空 `signature` + `key_id`)且 receiver-bound(`grantee_uri == receiver`)的 artifact 能进 cap store;**unsigned / legacy artifact 在存储时即被丢弃**。malformed / tampered 的签名 artifact 可能 opaque 地留在 rest,但**永远无法授权**——因为中央 verifier 拒它。
- **Verify at dispatch(crypto,strict)** — `Ezagent.Cap.Verifier`(`apps/ezagent_core/lib/ezagent/cap/verifier.ex`)是**唯一** dominates 每个 Kind handler invocation 的 framework verifier。对一个 **cap-gated** action,`verify_cap` **仅当**同时满足 (a) `Authority.verify_current(cap, presenter)` 密码学验签通过(签名对当前 per-Kind authority 有效 + `key_id` 匹配 + 绑定 authenticated presenter)且 (b) 匹配 required shape 时才接受;unsigned / malformed / tampered / retargeted / wrong-key 一律 **fail loud**(`:invalid_cap_signature` / `:missing_cap` / `:presenter_required`)。**没有 soft / permissive 分支。**
  - 与 cap-gated 并列的是一个**固定的 `@non_cap_actions` allowlist**(`Agent/User.Receive :receive`、`IdentityAdmin` 的 `absorb_cap`/`persist_caps`/`store_cap`/… store ops、socialware `:snapshot`/`:history`、session admission actions)—— 每个都有自己的 in-handler predicate,是一个 interim 的**结构性拆分**,不是 soft fallback。即模型是 "**cap-gated action 走严格验签 + 一个显式的 non-cap allowlist**",**不是** "每个 action 都要一张签名 cap"。
- **legacy-unsigned fallback 已删除** — `capability.ex:282`(codex r4 SPEC option-B):pre-SPEC 缺 `:action` 的 legacy admin cap 不再被识别,operator 必须经 `Identity.grant_cap` 重新 grant(会写 `action: :any`)。

**威胁模型 = Path A(reviewed-code)。** 已经在 BEAM 里恶意执行的代码**明确 out of scope**——所有被 load 的代码(含 community plugin)在 load 前都经过 review(见两模块 moduledoc:"Malicious code already executing in the BEAM is explicitly out of scope")。Path A 防的是:accidental forgery、review 漏掉的架构违规、external-ingress caller-spoofing。**签名 ≠ 撤销**:cap-signing 防 forgery / tamper / retarget / issuer-spoof,**不**做 revocation —— revocation 是独立线(epoch target-generation + delete_user cascade)。

**Path B —— 隔离 signer domain(external signer / sidecar / HSM)+ `Cap.issue` issuer-URL authentication —— 是 DEFERRED / roadmapped**,不是 "现在待做 / 必需"。它防的是 **in-VM 恶意代码**(从进程里抽 seed / 冒充 issuer),给 "未经 review 的 3rd-party plugin 在 BEAM 内跑" 那天用。旧的 v11 "isolated central signer / 单一 CapStore / one-shot re-sign" spec(2026-07-15)**就是 Path B**,在 Path A 满足当前需求后 **superseded**。**不要把 Path B 描述成 pending / required-now。**

---

## 8. Plugin 模型

### 8.1 Plugin = OTP application(no DSL,纯 convention)

Plugin 是一个标准 OTP app:

```elixir
# apps/esr_plugin_cc/mix.exs
def application do
  [
    mod: {EsrPluginCC.Application, []},
    env: [
      esr_kinds:               [Ezagent.Session.CC],
      esr_behaviors_attached:  []                # cross-cutting,见 §8.2
    ]
  ]
end

# apps/esr_plugin_cc/lib/esr_plugin_cc/application.ex
defmodule EsrPluginCC.Application do
  use Application

  def start(_type, _args) do
    Ezagent.KindRegistry.register_type(Ezagent.Session.CC, default_caps: [...])

    Supervisor.start_link([Ezagent.Session.CC.Supervisor],
      strategy: :one_for_one,
      name: EsrPluginCC.Supervisor)
  end

  def stop(_state) do
    Ezagent.Plugin.drain(:ezagent_plugin_cc)
    :ok
  end
end
```

> **Implementation**:**`Application`** + **`Supervisor`**(OTP);drain 检查定时任务可走 **`Oban`**。

### 8.2 两种 Plugin 模式

**Mode A: Self-contained** — Plugin 注册自己的 Kind(例 `esr_plugin_cc` → `Ezagent.Session.CC`)

**Mode B: Cross-cutting** — Plugin attach Behavior 到他人 Kind:

```elixir
def start(_, _) do
  Ezagent.BehaviorRegistry.attach(
    target_kind: Ezagent.Entity.Agent,
    behavior:    Ezagent.ActionSet.AuditLog,
    on_attach:   :rehydrate
  )
  Supervisor.start_link([], strategy: :one_for_one)
end
```

### 8.3 Plugin lifecycle 状态机

| 操作 | Registry 动作 | 已运行 instance 影响 |
|---|---|---|
| `register_type` (Mode A) | 注册 KindType | 无 |
| `attach` (Mode B) | 注册 `{kind, action} → behavior` | broadcast rehydrate |
| `detach` (Mode B 卸载) | 移除 `{kind, action}` 映射 | 保留 slice,dormant |
| `unregister_type` (Mode A 卸载) | 移除 KindType | DynamicSupervisor 整棵 drain → stop |

**卸载语义**:drain till `instance_count == 0`,才允许 stop。Plugin Supervisor 状态多一个 `:draining`,期间 `start_child` 全部拒绝。

> **Implementation**:rehydrate broadcast → **`Phoenix.PubSub`**;drain 状态机自写,基于 `DynamicSupervisor.which_children/1` 轮询。

### 8.4 Plugin discovery

**无中心化 registry**。`Ezagent.Plugin.discover/0` 扫 `Application.loaded_applications/0`,过滤出 `:env` 中带 `:ezagent_kinds` 或 `:ezagent_behaviors_attached` 的 application。

> **Implementation**:**`Application.loaded_applications/0`** + **`Application.spec/2`**(OTP)。

### 8.5 Cross-cutting attach 五条规则

| Q | 答案 |
|---|---|
| 已存在实例 vs 新建实例 | 两者都覆盖,broadcast rehydrate |
| 已存在 principal 自动 grant cap | 不自动;plugin 提供 migration 命令(`mix ezagent.plugin.grant <plugin>`) |
| Action 名冲突 | Hard fail,plugin 启动报错 |
| Behavior 之间能依赖吗 | 不能;跨 Behavior 数据通过 `ctx` |
| Detach 时 slice 怎么办 | 保留作为 dormant data,重装后继续可读 |

### 8.6 命名 convention

```
:ezagent_plugin_<name>   ↔  EsrPlugin<Name>  ↔  apps/esr_plugin_<name>/
```

---

## 9. Templates — 双层模型(Class + Instance)

V0.4 把 v0.3 单层 Template 升级为**双层模型**——区分"开发者写的 instantiate 代码"和"用户存的具体配置数据"。这条分离的发现来自 grill 现有 esr 的 Workspace 用法:`workspace://esr-dev` 是用户编辑的命名预设(folders/agent/settings/env),不是模块代码;但它需要被 `/session:new` 消费来 instantiate 实际 session。

```
┌──────────────────────────────────────────────────────────────────┐
│  Template Class    (模块级,开发者写)                            │
│    e.g. Ezagent.Session.Feishu2CC.Template                           │
│    "这类 session 如何 instantiate" 的代码                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              │  instantiate(data, opts)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Template Instance (运行时 Resource Kind,用户创建)              │
│    e.g. workspace://esr-dev                                      │
│    携带具体预设数据(folders/agent/settings/env)                │
│    用户编辑、命名、可寻址                                         │
└──────────────────────────────────────────────────────────────────┘
```

### 9.1 Template Class — 模块级

每个 Template Class 是个实现 `Ezagent.Kind.Template` behaviour 的模块:

```elixir
defmodule Ezagent.Kind.Template do
  @callback validate(instance_data :: map()) :: :ok | {:error, [violation()]}
  @callback instantiate(instance_data :: map(), opts :: keyword()) ::
              {:ok, URI.t()} | {:error, term()}
  @callback list_instances(class_id :: String.t()) :: [URI.t()]
end

defmodule Ezagent.Session.Feishu2CC.Template do
  @behaviour Ezagent.Kind.Template
  
  def validate(%{folders: folders, agent: agent} = data) do
    # 检查 instance_data 形状是否符合本 Class 的期待
    cond do
      not is_list(folders) or folders == [] -> {:error, [:folders_required]}
      not is_binary(agent)                   -> {:error, [:agent_required]}
      true                                   -> :ok
    end
  end

  def instantiate(instance_data, opts) do
    # 用 instance_data 起一个 Feishu2CC session
    # ...
  end
end
```

### 9.2 Template Instance — 运行时 Resource Kind

Template Instance 是用户创建的、命名的预设数据,**本质就是一个 Resource Kind 实例**(§3.1)。它没有 Principal、没有外部进程、没有消息流——它是"被指代的配置数据"。

**Workspace 是 Template Instance 最重要的现存示例**:

```elixir
defmodule Ezagent.Resource.Workspace do
  use Ezagent.Kind,
    type_name: :workspace,
    subclass: :resource,
    persistence: {:snapshot, :on_change}
  
  # state slice 直接对应用户编辑的字段
  defstruct [
    :uri,        # workspace://esr-dev — 稳定身份
    :name,       # "esr-dev" — 显示名(可改,不影响 URI)
    :owner,      # user URI
    :folders,    # [folder_uri] — 有序,folders[0] = canonical cwd
    :agent,      # default agent_def
    :settings,   # %{} — 点命名 config map
    :env,        # %{} — 注入 session 的环境变量
    :transient,  # bool
    :location    # 存储位置
  ]
  
  # 标准 Behavior 集:
  # - Ezagent.ActionSet.WorkspaceFolders  (add-folder / list-folders / remove-folder)
  # - Ezagent.ActionSet.WorkspaceMetadata (rename / edit / describe / set-default)
  # - Ezagent.ActionSet.WorkspaceBindings (bind-chat 通过 RoutingRegistry)
  # - Ezagent.ActionSet.WorkspaceRepos    (import-repo / forget-repo)
end
```

#### 为什么 Workspace 必须是独立 Resource Kind,不能展开成 tuple

按 §3.1.1 "shared referent needs identity" 原则,Workspace 被**至少 5 类引用者**按身份指向(每类都按 UUID 指,不是按 tuple 内容):

1. **Cap 持有者** — `cap(workspace://esr-dev, ...)` 需要稳定 subject URI
2. **运行中 session** — `SessionBindings` 维护 `(workspace_uri ↔ session_set)` 双向实时映射
3. **User 默认值** — `user.default_workspace_uri`,resolve.ex 第 3 级 fallback
4. **Repo 路径发现** — `RepoRegistry`:`repo_path → workspace` 映射
5. **Plugin 运行时配置** — `Config.resolve("plugin_x", [:user_uri, :workspace_uri])` 按 workspace 分层

把 Workspace 展开成 tuple `(folder_uris + agent_def + settings)` 意味着 5 类引用者各持一份 tuple 副本:
- 编辑就要 fan-out 到所有副本——这是补发 1 描述的"静默 divergence" bug 类
- 双向 `session ↔ workspace` 映射变成 `session ↔ tuple`,**反查不可能**("哪些 session 在用 esr-dev?"无法回答)

**所以 Workspace 必须独立存在**,但它**很薄**——没有外部资源、没有消息流,GenServer 操作时短暂活跃,操作完 `:on_change` 落盘。这符合 §3.1.1 Resource 薄形态。

### 9.3 `validate/1` 作为 instance data 的契约

Template Instance 跟 Template Class 之间**不绑定**——同一个 `workspace://esr-dev` 可以被多个 Class 消费(`Ezagent.Session.Feishu2CC.Template` 起 Feishu session、`Ezagent.Session.CC.Template` 起本地 CC session,都消费同一份 workspace 数据)。

衔接靠**契约**:任何 Class 想消费某个 Instance 的数据,**必须 `validate/1` 通过**——Class 通过 `validate/1` 声明"我接受什么形状的 instance data"。

```elixir
# /session:new 流程:
def new_session(workspace_uri, class_module) do
  with {:ok, instance_data} <- Ezagent.Resource.Workspace.read_state(workspace_uri),
       :ok <- class_module.validate(instance_data),
       {:ok, session_uri} <- class_module.instantiate(instance_data, ...) do
    # session 起来了,session bindings 写入 RoutingRegistry
    Ezagent.RoutingRegistry.put(SessionBindings, workspace_uri, session_uri)
    {:ok, session_uri}
  end
end
```

`validate/1` 是 v0.3 已有的 callback,**双层 Template 没有引入新概念**,只是把它的角色明确成"instance data 契约"。Class 跟 Instance 独立存在,通过契约衔接——零新 mechanism。

### 9.4 现存的双层混淆 case — `session_template` 子系统(833 LOC)

现有 esr 的 `session_template/` 子系统(实测 833 行)**已经混淆了这两层**——它的 registry 支持 `register(name, template, source: :operator)`,`source: :operator` 意味着运营时能注册一个。也就是说现有 session template 里**一部分是代码定义的(Class)、一部分是运营注册的(Instance)**,挤在一个 registry 里。

V0.4 双层模型正好把它们解耦:
- 代码定义的 → Template Class(模块,装在 plugin 里)
- 运营注册的 → Template Instance(Resource Kind 实例,SQLite 持久化)

**这不是"未来扩展",是 v0 现在就该拆**——`session_template/` 子系统在迁 v0 时直接套用双层模型。

### 9.5 Future extraction — Agent / Tool Preset

**不假装它存在,但留 framing 口子**。现有 esr 里 agent 配置内嵌在 Workspace 的 `agent` + `settings` 字段(`agent: "cc"`, `settings: %{"cc.model" => ...}`),**还不是独立 Template Instance**。

未来如果用户需要独立编辑、命名、跨 workspace 复用的 agent 预设(`agent_preset://my-claude-opus-config`),按双层模型扩展即可——再加一个 `Ezagent.Resource.AgentPreset` Kind 即可,Class 端各 agent 实现自己的 `validate/1`。Tool preset 同理。

V0.4 spec **不创建** AgentPreset / ToolPreset Kind,仅留下 framing 兼容性——双层模型天然支持未来扩展。

### 9.6 Socialware definition ≠ Template Kind

Socialware unification(2026-06-26/28)引入的 **socialware definition 不是一种 Template Kind** —— 它是一个 **opaque `socialware:<name>` ConfigObject**(L2 definition data,sibling of the recipe on the same `ConfigStore`/`ConfigObject` substrate),**不是** spawnable Template Kind。

- **存处**:`Ezagent.Socialware.DefinitionRegistry`(`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex`,moduledoc "Definitions live at `socialware:<name>` with ConfigObject key `\"socialware\"`")。`<kind>:<name>`(recipe:/socialware:)是 ConfigStore-internal opaque subject,**不在** 6 个 Kind URI scheme 集合内(`entity session template resource workspace system`,`apps/ezagent_core/lib/ezagent/plugin.ex:88` `@core_schemes`)。当前 template spawn 只支持 `agent` 和 `session` type;`template://.../socialware` 会暗示一个不存在的 hidden Template Kind。
- **对称物**:recipe —— `Ezagent.Agent.Recipe` 同样是 `recipe:<name>` ConfigObject(key `"recipe"`),不是 Template Kind。两者是 ConfigStore 上的 sibling opaque subjects。
- **SessionTemplate 的角色**:SessionTemplate 是 **plugin-composition** —— 它持一个 `installs: [{socialware-ref, seed-overrides}]` 字段(`Ezagent.Socialware.Installation.installs_from_template/1`),命名 *which* socialware-defs 装到 session;它 **不** 是 socialware definition 本身。Socialware definition 承载 bases/shape/members/routing_rules/adapters/visibility_policy;SessionTemplate 只持 generic composition + lineage。
- **install relation**(landed P4):`Ezagent.Socialware.Installation`(`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`,`@install_key_prefix "install:"`)写 per-session ConfigObject record + 把 socialware 的 bases+shape thread 进 Session 的 `:kind_base` union。

老 `:public_view` SessionTemplate boolean field 已删除(split 为 install relation + `visibility_policy.web_anon_access`);`Ezagent.Socialware.PublicView` 保留为 compat facade。详见 `docs/together/2026-06-26/specs/socialware-unification.md` §2.3-§2.4 + GLOSSARY.md §2 "Install" / "Definition" 条目。

---

## 10. 持久化分层

四类东西,走不同机制,**不可混淆**:

| 类型 | 内容 | v0 存储 | 未来升级 |
|---|---|---|---|
| **A. 配置 / 定义** | KindType 注册、Plugin 装载、Template Class 内容、**plugin 运行时配置** | Ecto + SQLite | 不变 |
| **B. 实例存在性** | instance URI ↔ KindType 映射 | Ecto + SQLite | 不变 |
| **C. 实例状态** | Kind GenServer state(`:caps`, slices,包含 Template Instance 数据如 Workspace) | **Snapshot 到 SQLite**(`:map` field) | 不变(append-only Message stream 已具备 ES 的好处,详见 §1.3) |
| **D. 调用流水 / 审计** | 谁在何时调了什么 | Ecto append-only | 加 archival pipeline |
| **E. 失败诊断队列** | 失败 case + **unroutable** 落地的 bounded FIFO | Ecto + OldestFirst evict | 不变 |
| **F. Message stream** | append-only message log(业务事实层) | Ecto + SQLite(JSON via `:map` field) | 升 ES 后变成 event stream |
| **G. 文件附件** | binary blobs(图片/文档/语音) | SQLite BLOB(<10MB)或 S3 | 不变 |
| **H. Routing entries** | RoutingRegistry 持久化(见 §5.4.8) | Ecto + SQLite | 不变 |

**Plugin 运行时配置归属 A 类**(详见 §10.5):Feishu app credentials、chat-to-workspace bindings 等,plugin 自己用 Ecto 读写,跟 KindType 注册同等级。

> **Implementation 全部基于 Phoenix-adjacent 生态**:
> - **`Ecto`** + **`Ecto.SQL`** + **`ecto_sqlite3`** — schema / migration / query / driver
> - **BEAM 原生 timer**(`Process.send_after/3`)— snapshot 定时 / audit batch flush / DLQ evict;**不引入 Oban**


### 10.1 C — Snapshot 策略(v0)

```sql
CREATE TABLE kind_snapshots (
  uri          TEXT PRIMARY KEY,
  kind_type    TEXT NOT NULL,         -- 稳定 type_name(:agent / :workspace 等)
                                       -- 不存模块名字符串(避免改名 staleness)
  state        TEXT NOT NULL,
  version      INTEGER NOT NULL DEFAULT 0,
  updated_at   TEXT NOT NULL
);
```

**为什么用 `kind_type` 不存模块名字符串**(§1.2 差异 2 推论):

模块名字符串(`"Elixir.Ezagent.Entity.Agent"`)在 rename 模块时变成 orphan 引用,下次 `init/1` 用 `String.to_existing_atom` 会炸——**代码身份和数据耦合**。

用稳定 `type_name`(`:agent` / `:workspace` 等)作为间接层:
- `KindRegistry` 维护 `type_name → current_module` 映射(plugin 启动时注册)
- snapshot 写时存 `type_name`,读时 KindRegistry 查最新 module
- 模块改名只需 plugin 的注册代码改一处,SQLite 数据不动

```elixir
# Plugin 注册时声明 type_name:
defmodule Ezagent.Entity.Agent do
  use Ezagent.Kind, type_name: :agent, ...
end

# KindRegistry 自动维护映射,plugin 作者不需要写额外代码
```

写时机三选一(Kind 自己声明):

```elixir
use Ezagent.Kind, persistence: {:snapshot, :on_change}              # 关键长期 entity
use Ezagent.Kind, persistence: {:snapshot, periodic: 30_000}        # 高频可丢秒
use Ezagent.Kind, persistence: {:snapshot, :on_terminate}           # Session 类
use Ezagent.Kind, persistence: :ephemeral                            # 测试用
use Ezagent.Kind, persistence: :external                             # 状态在外部
```

GenServer `init/1`:从 snapshot 表读最新 state,无记录则用 `init_slice` 初始化。

**`:on_change` 的精确语义**:**slice 值真变了才写**,不是"invoke 后都写"。

dispatch step 8(Appendix A)收到 `{:ok, new_slice, result}` 后,Kind GenServer 用 `new_slice != old_slice` 判断 dirty——变了才落 snapshot。理由:

- BEAM map 是 immutable,值比较快(`==` 实际是 `=:=`,有 hash cache 时接近 O(1))
- `:introspect` mode 的 read-only invoke 应该跳过 snapshot
- Behavior 返回 `{:ok, slice}`(同 reference)或 `{:error, _}` 直接跳过
- 用户写 Behavior 时不需要管 "dirty 标记",**纯函数 + 不可变数据自然给出正确语义**

`:periodic` 是定时 flush(包含未变的 slice 也写——确认 timestamp);`:on_terminate` 是 GenServer terminate/2 时写一次(`:normal`/`:shutdown` 写,`:kill` 等可能丢)。

### 10.2 D — Audit Log

异步写,不阻塞 invoke。链路:

```
:telemetry.attach("esr-audit", [:ezagent, :invoke, :stop],
  &Ezagent.Audit.handle_event/4, nil)

  ↓ handler 只做:
  GenServer.cast(Ezagent.Audit.Writer, {:write, audit_event})
  ↓ ~微秒返回
继续 invoke flow,不阻塞

Ezagent.Audit.Writer (GenServer):
  - 内部 batch 累积
  - 每 100ms,或 batch ≥ 500,flush 一次到 SQLite invocations 表
  - mailbox > 10k 时,后续 cast 自动 backpressure(改 sync call)
```

**实施细节**:

- ~30 LOC GenServer,跟 `Ezagent.Scheduler` 共用一套 BEAM 原生 timer
- 表索引:`(caller, target, inserted_at)` + `(target, inserted_at)`
- BEAM crash 时 in-flight batch 丢——audit 不是关键路径,可接受
- 归档(冷数据移 S3)v0 不做,落到 §17.8 deferred

```sql
CREATE TABLE invocations (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  trace_id      TEXT,
  caller        TEXT NOT NULL,
  target        TEXT NOT NULL,
  action        TEXT NOT NULL,
  args          TEXT NOT NULL,    -- JSON
  result        TEXT NOT NULL,    -- JSON
  duration_us   INTEGER NOT NULL,
  authz         TEXT NOT NULL,    -- granted | denied
  exception     TEXT,             -- nil 或 exception info JSON
  inserted_at   TEXT NOT NULL
);
CREATE INDEX ON invocations (caller, target, inserted_at);
CREATE INDEX ON invocations (target, inserted_at);
```

### 10.3 E — Dead Letter Queue

三种失败 case 落地:Behavior 异常、外部进程崩溃、Invocation 超时。bounded 10k,OldestFirst evict。供运维查询。**不混入 audit log**(D 是成功+失败的全量;E 只是失败的可重放队列)。

### 10.4 F — Message stream

每条 Message envelope(§3.5)进系统时,**写一次 `messages` 表**(append-only):

```sql
CREATE TABLE messages (
  uri          TEXT PRIMARY KEY,              -- message URI(可被 ref 引用)
  session_uri  TEXT NOT NULL,                 -- 所属 session
  sender       TEXT NOT NULL,                 -- Entity URI
  mentions     TEXT NOT NULL DEFAULT '[]',
  body         TEXT NOT NULL,                -- {text, attachments, ...}
  ref          TEXT,                          -- ^reply-to
  inserted_at  TEXT NOT NULL
);

CREATE INDEX ON messages (session_uri, inserted_at);
CREATE INDEX ON messages (sender);
```

**`visibility` 字段(rename landed)**:`Message.visibility :: :external_visible | :internal`(verified `apps/ezagent_core/lib/ezagent/message.ex:20,119-120`;migration `20260628001000_rename_operator_only_visibility_to_internal.exs`)。旧 `:customer_visible | :operator_only` 已 rename:`:internal` = all-info superset(held turn output、operator/management unfiltered read);`:external_visible` = audience-visible。Per-message visibility 是 real revocation primitive(`external_feed.ex`)。详见 GLOSSARY.md §2 Message 条目 + Decision #155。

**Message stream 跟 Invocation audit (D) 不混淆**:
- D 记**所有 Invocation**(管理操作 + Message 投递),弱 schema,运维角度
- F 记**Message 实体本身**,只在 Message identity-create 时写一次,中转转发不重复写,业务角度

LiveView dogfood IM 渲染 message stream UI 时,SELECT from F;routing 内部转发用 F 的 URI 引用同一条 Message,不是复制。

### 10.5 G — 文件附件(landed:Uploads + FsResolver + DownloadToken)

外部 IM(Feishu/Slack)消息可含图片、文档、语音、视频。**Landed 设计(Decision #155 red line 4):blob bytes NEVER inline in Postgres。** Bytes 落在 host filesystem(`EZAGENT_HOME/uploads/<ws>/<name>`,ws-partitioned)或 S3-compatible object-storage;Postgres 只存 `resource://<ws>/uploads/<name>` URI ref + 一个 MAC-signed `DownloadToken`(S3-presigned-URL style bearer token)。

```
1. Feishu webhook 推 message,带 file_key
2. Python feishu adapter 调 Feishu API 下载文件内容(bytes)
3. adapter 调 Ezagent.Uploads 写 bytes 到 Home.path("uploads")/<ws>/<name>(disk)
   (或 S3-compatible object-storage)
4. Ezagent.Uploads 返回 resource://<ws>/uploads/<name>  URI ref(存进 Postgres,NOT bytes)
5. adapter 构造 %Message{body: %{text: "...", attachments: [resource_uri]}}
6. Message 在 Ezagent 内层层中转,attachments 字段只是 URI 引用,不重复 binary
7. consumer 要读 bytes 时 mint 一个 DownloadToken(MAC-signed,绑 ws-scoped URI),
   拿 token 解出 FsResolver 解析的物理路径/S3 key 取 bytes —— 永远不为 bytes 本身 mint
```

**Verified landed substrate(`origin/main`):**

| 模块 | 路径 | 职责 |
|---|---|---|
| `Ezagent.Uploads` | `apps/ezagent_core/lib/ezagent/uploads.ex` | upload chokepoint;moduledoc:"Attachments are addressed as `resource://<ws>/uploads/<name>` … bytes live at `Home.path(\"uploads\")/<ws>/<name>` — ws-partitioned" |
| `Ezagent.Uploads.DownloadToken` | `apps/ezagent_core/lib/ezagent/uploads/download_token.ex` | moduledoc:"S3-presigned-URL style: a MAC-signed bearer token that encodes the full ws-scoped `resource://<ws>/uploads/<name>` URI" |
| `Ezagent.Resource.FsResolver` | `apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex` | 把 `resource://` URI 解析到物理 fs 路径 / S3 key |

Consumers mint a token for the stored URI,never for bytes(e.g. `conversation_data.ex` 给 attachment URI mint token,不传 bytes)。

> ⚠️ **本节历史版本描述过一个 `<10MB → SQLite BLOB` 的 `attachments` 表 with a `data BLOB` column。** 那个设计 **从未 landed**(或已被 superseded),且会 **violate** Decision #155 red line 4(blob-never-inline)。当前 landed 代码 regardless of size 都把 bytes 存 disk,Postgres 只持 URI ref + token。见 SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §4.5(STALE-DOC anti-pattern,now fixed)。可选 arch-gate(§6.3 of the SPEC):fail if any migration 引入 `:binary`/`BLOB` column on an `attachments`/`uploads` table(scoped to attachment/upload tables + content-bearing column names only —— 合法的 `state_binary` / token hash binary 列不在此列)。

### 10.6 A 类 — Plugin 运行时配置

属于持久化类型 A,**plugin 自己用 Ecto 管理**——core 不预定义 schema,plugin 在自己的 Application.start 里 `Ecto.Migrator.run/3` 加表。例:

```elixir
# ezagent_plugin_feishu 的 schema
defmodule EzagentPluginFeishu.AppConfig do
  use Ecto.Schema
  schema "feishu_app_configs" do
    field :app_id,        :string
    field :app_secret,    :string         # 加密存
    field :webhook_token, :string
    field :default_workspace_uri, :string
    timestamps()
  end
end
```

运维通过 plugin 自己暴露的 admin Behavior 改这些配置(走完整 CapBAC + audit),不是直接改 SQLite。Hot-reload 由 plugin 自己实现(`Phoenix.PubSub.subscribe("config:updated")` 等模式)。

**为什么不用 `Application.spec/2` env**:`:env` 是**编译期静态**——运维改 Feishu app credentials 时不可能 recompile + restart 全系统。类型 A 持久化提供运行时可变性。

> **Cross-ref**:reusable / forkable / content-addressed 的定义(recipe、socialware definition、responsibility assignment)优先住 L2 ConfigObject(`recipe:<name> / socialware:<name>`,见 §9.6 + GLOSSARY §2 "Definition")。本节 A 类 plugin-owned Ecto 表是 plugin *runtime* 配置(app credentials 等),跟 L2 definition data 是不同 home —— definition 是 cross-instance reusable 的 config-as-data,runtime 配置是 per-plugin operational secret。

### 10.7 feishu-cc 切片参考表(v0 第一个垂直切片)

v0 的第一个端到端验证场景是 feishu-cc 链路(Feishu 群聊 → Ezagent session → CC agent)。这条链路需要 **3 张 RoutingRegistry 表**作为参考实现——其他 plugin 可按同模式扩展:

| Table | key 形状 | value 形状 | owner plugin | key 类型 | 写语义 |
|---|---|---|---|---|---|
| `ChatRouting` | `{chat_id, app_id}` | `session_uri` | `ezagent_plugin_feishu` | **unique** | `put_new`(撞 key reject) |
| `PrincipalMapping` | `feishu_user_id` | `user_uri` | `ezagent_plugin_feishu` | **unique** | `put_new` |
| `SessionRules` | `session_uri` | `{matcher_data, receivers}` | session orchestrator plugin | **duplicate** | `put`(append,一 session 多 rule) |
| `SessionBindings` | `workspace_uri` | `session_uri` | session orchestrator plugin | **duplicate** | `put`(一 workspace 多 session) |

**注意 `SessionRules` 和 `SessionBindings` 都是 duplicate-key** —— 一个 session 多条 rule、一个 workspace 多个 session 引用,所以用 `put` 不用 `put_new`(呼应 §5.4.2 的 unique vs duplicate-key 区分)。前两张是 unique-key,用 `put_new`。

**关于反查**:`SessionBindings` 在使用上有反向查询需求(`session_uri → workspace_uri`,用于 "session 关闭时通知它绑定的 workspace")。RoutingRegistry 的单向 `key → value` 模型接不住——v0 解决方案是**显式声明反向索引表**:

```elixir
Ezagent.RoutingRegistry.declare_table(
  name: SessionBindings,
  duplicate_keys: true,
  owner: :ezagent_session_orchestrator,
  reverse_index: SessionBindingsReverse   # 自动维护 session_uri → workspace_uri
)
```

`reverse_index` 是 `declare_table` 的可选参数。维护反向索引由 RoutingRegistry 自动做(每次 `put` 同时写两边),不依赖 plugin 作者纪律。如果某张表确实不需要反查,不声明 `reverse_index` 即可(零成本)。

```elixir
# Plugin declare:
Ezagent.RoutingRegistry.declare_table(
  name: ChatRouting,
  duplicate_keys: false,         # unique key
  owner: :ezagent_plugin_feishu
)
Ezagent.RoutingRegistry.declare_table(
  name: SessionRules,
  duplicate_keys: true,           # duplicate key
  owner: :ezagent_session_orchestrator
)

# 用法:
Ezagent.RoutingRegistry.put_new(ChatRouting, {chat_id, app_id}, session_uri)
# → :ok | {:error, {:already_registered, existing_uri}}

Ezagent.RoutingRegistry.put(SessionRules, session_uri, {matcher, receivers})
# → :ok(append,N 条 rule 共存)
```

未来其他 plugin(Slack adapter 等)按同模式各自声明类似 `ChatRouting` 表(`{slack_channel, team_id} → session_uri`),互不干扰。

### 10.8 4-carrier-layer taxonomy(artifact-kind 轴,正交于 3 code tiers)

> **Source of truth:** `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0 + Decision #155 (GLOSSARY.md §1)。本节是摘要;normative 定义 + anti-pattern verdicts + red lines 见该 SPEC。

每个 ezagent artifact 落在四 carrier layer 之一。四层是 **artifact-kind + storage-home + anti-leak rule** 轴,**正交于** 3 code tiers(core/domain/plugin,§3 + `.claude/skills/ezagent-developer/references/three-tier-structure.md`)—— 3 tiers 管 **code-dependency direction**,4 carrier layers 管 **artifact kind + storage home**。一个 plugin 可同时发 L1 code + L2 seed definitions。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 4 — EZAGENT_HOME files        (host-side runtime files)                │
│   creds, kanban-boards.json mapping, logs, PTY pid-files, upload bytes      │
│   NOTHING queryable by the BEAM as typed state; files the host OS owns      │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 3 — Runtime state data        (Postgres kind_snapshots slice + blobs) │
│   per-agent/session DYNAMIC instance state: kanban task list, messages,     │
│   turn state, membership, settlement. The live slice.                      │
│   ► Blob sub-rule: binary bytes (video/attachments) → object-storage/fs     │
│     (EZAGENT_HOME or S3); Postgres stores ONLY a URI ref + signed download  │
│     token. Blob NEVER inline in Postgres. (§10.5)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 2 — Definition data           (Postgres ConfigObject; static/reusable) │
│   config-as-data: recipe, socialware-definition, responsibility role_name,  │
│   shape config, persona, adapters, visibility_policy.                       │
│   ► Business semantics LIVE HERE and ONLY here.                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 1 — Code plugin               (apps/ezagent_plugin_*; compiled in)     │
│   Behavior.Kanban etc. shape MECHANISM; Orchestrator.Tools; Surface render. │
│   NO business words. Generic, reusable.                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**6 anti-leak red lines(Decision #155):**

1. **Business concepts → L2 (definition DATA) ONLY。** Salesperson / customer-service-flow / board-semantics / persona / autoservice 住 L2 ConfigObject data value,never in L1 code / core / agent modules / L3 schema。
2. **Business mechanism ≠ business semantics。** 需要的 code mechanism 是 L1 plugin(如 `Behavior.Kanban` 的 board/task mechanism),但 business semantics(which columns / which stages)是 L2 data。Only generic mechanism 是 code。(Known partial leak:`Behavior.Kanban` 仍 hardcode 9-stage product chain at `kanban.ex:37-38` —— target 是 move to L2 data。)
3. **加新 socialware 不得改 `ezagent_core`。** 新 socialware = L2 definition +(可选)L1 plugin for novel mechanism。Core 不动。(Anti-pattern 4.6 — FIXED;`Ezagent.Socialware.DefinitionRegistry` 在 `domain_session` 不在 core。)
4. **Blob NEVER inline in Postgres。** Bytes → L4;Postgres → URI ref + signed `DownloadToken` only。(§10.5 landed design;`Ezagent.Uploads` + `DownloadToken` + `FsResolver`。)
5. **`socialware` 是 substrate name,不是 business concept。** Core 可命名 socialware substrate(tables、registry seam),不得命名 business-app concepts。NP-2 layer-vocabulary lint(`ezagent.check_invariants.lifecycle`)是 enforcement seam。
6. **Fixture NOT a concept。** autoservice / loom / 命名部署是 configured instance(L2 seed + L3 instance),不入 concept taxonomy / config schema。

**"new thing goes in which layer?" judgment rule** —— 见 SPEC §3(top-down decision flowchart;compound deliverable 先 decompose,each atomic artifact has exactly one home)。

---

## 11. 可观测性

三层独立,**不混用**:

| 工具 | 用途 |
|---|---|
| **`:telemetry`** | 事件 / 指标 |
| **`Logger`** | 文本日志 |
| **`OpenTelemetry`** + **`opentelemetry_telemetry`** | 分布式追踪 |

**事件命名 convention**:`[:ezagent, <area>, <event>]`,`<area>` ∈ `:invoke / :authz / :plugin / :lifecycle / :persistence`。

Phoenix 框架本身就大量使用 `:telemetry`(`[:phoenix, :endpoint, ...]`、`[:phoenix, :channel_joined, ...]`),平行共存。开发期用 `Phoenix.LiveDashboard` 同时看两边(LiveDashboard 是开发依赖,不算"上 LiveView 做产品"——它是 Phoenix 内置工具)。

---

## 12. Transport Adapter Pattern

**所有外部入口是 Adapter**。Adapter 做两件事:解析外部输入 → 构造 `%Invocation{}`;渲染结果回外部协议。Adapter **不允许有业务语义**。

### 12.1 Phoenix transport stack

```
┌────────────────────────────────────────────────────────────┐
│                   Phoenix.Endpoint                          │
│                                                             │
│   ┌──────────┐    ┌────────────────┐    ┌───────────────┐ │
│   │  Plug    │    │ Phoenix.Socket │    │  custom Socket │ │
│   │ (HTTP)   │    │      (WS)      │    │ (e.g. stdio)   │ │
│   └────┬─────┘    └────────┬───────┘    └───────┬───────┘ │
│        │                   │                     │         │
│   ┌────▼──────────┐    ┌───▼─────────────────┐ ┌▼──────┐  │
│   │ WebhookPlug   │    │  InvokeChannel      │ │ MCP   │  │
│   │ AdminAPI Plug │    │  (agent: / session: │ │ Socket│  │
│   └───┬───────────┘    │   / channel: ...)   │ └──┬────┘  │
│       │                └────────┬─────────────┘    │       │
└───────┼─────────────────────────┼─────────────────┼───────┘
        │                         │                  │
        └─────────────┬───────────┴──────────────────┘
                      ▼
              %Ezagent.Invocation{}
                      ▼
                  dispatch
```

### 12.2 两个 Phoenix Socket

```elixir
# ezagent_web/endpoint.ex
socket "/socket", Ezagent.Web.UserSocket    # 通用 WS:Python adapter / 浏览器 / Next.js / CLI 长连接
socket "/mcp",    Ezagent.Web.MCPSocket     # MCP 协议特化(framing 不同)
```

**不需要 5 个 Socket**(dev review 指出的 v0.2 leakage)。所有 WS client 用一个 `/socket`,通过 Channel topic 区分语义。

### 12.3 Channel topic 命名约定

| Topic | 语义 | 谁可订阅 |
|---|---|---|
| `agent:<id>` | Agent inbound | 有相应 cap 的 principal |
| `session:<id>` | Session inbound | 同上 |
| `channel:<id>` | ExternalChannel inbound | 同上 |
| `<uri>:events` | Outbound 事件流(只读) | 有 subscribe cap |
| `<uri>:_internal` | 内部 topic(plugin 自约定) | 同 OTP app 强约定 |
| `presence:<kind>` | Phoenix.Presence | admin only |

**Channel 业务逻辑模板**(`@interface` 自动生成):

```elixir
defmodule Ezagent.Web.InvokeChannel do
  use EzagentWeb, :channel

  def join("agent:" <> id, _params, socket) do
    case Ezagent.Invocation.dispatch(%Invocation{
      target: URI.parse("agent://#{id}"),
      mode: :subscribe,
      ctx: socket_to_ctx(socket)
    }) do
      :ok -> {:ok, assign(socket, :uri, "agent://#{id}")}
      {:error, :unauthorized} -> {:error, %{reason: "forbidden"}}
    end
  end

  def handle_in(action, params, socket) do
    result = Ezagent.Invocation.dispatch(%Invocation{
      target: URI.parse(socket.assigns.uri <> "/behavior/.../#{action}"),
      mode: :call,
      args: params,
      ctx: socket_to_ctx(socket)
    })
    {:reply, result, socket}
  end

  def handle_info({:ezagent_event, event}, socket) do
    push(socket, event.name, event.payload)
    {:noreply, socket}
  end
end
```

### 12.4 External adapter as subprocess — 两种 driver 关系

Ezagent 的 transport adapter 在 subprocess 层有两种 driver 关系,**对称但不同**:

#### A. Ezagent-driven(Feishu / Slack 等)

Ezagent 主动通过 `Ezagent.ActionSet.OSProcess` 拉起 subprocess。subprocess 启动后建立到 Ezagent 的 WS 连接,双向桥接外部协议。

```
[Feishu server]
    │
    │ WS(Feishu 协议)
    ▼
[Python feishu_adapter.py]   ← Ezagent.ActionSet.OSProcess 拉起
    │
    │ WS to Ezagent.Web.UserSocket on /socket
    ▼
[InvokeChannel "session:feishu-cc/..."]
    │
    ▼
%Ezagent.Invocation{}  ─→  dispatch
    │
    ▼
[reply via ctx.reply = {:phoenix_channel, "session:..."}]
    │
    ▼ Python adapter 收到 push
[Python adapter]
    │
    │ WS frame(Feishu 协议)
    ▼
[Feishu server]
```

适合场景:**Ezagent 知道要接入哪些外部 IM 服务**,启动时主动拉起对应 adapter。Feishu/Slack/WhatsApp 等等。

#### B. External-driven(Claude Code Channel)

Ezagent 被动接受外部驱动的 subprocess 连入。subprocess 由**别的 host 进程**(如 Claude Code)拉起,启动后 WS 连进 Ezagent。

```
[Claude Code (user 启动)]
    │
    │ --channels plugin:esr-channel
    ▼
[esr-channel (Python MCP server)]  ← Claude Code 拉起,stdio
    │
    │ WS to Ezagent /cc_channel(主动连接)
    ▼
[Ezagent.Web.CCChannelSocket]
    │
    ▼
[绑定到 agent://cc-<instance>]
```

适合场景:**Ezagent 不知道何时何处会有 CC 实例启动**,被动等连入。Channels 协议要求 Bun/Python plugin 必须由 CC 用 `--channels` 启动,所以 Ezagent 不能 driver。

#### 两种 driver 的 Ezagent-side 实现差异

| 维度 | Ezagent-driven (Feishu) | External-driven (CC Channel) |
|---|---|---|
| Subprocess 由谁拉起 | Ezagent (`OSProcess.spawn`) | 外部 host(CC `--channels`) |
| Subprocess 生命周期 | Kind GenServer 持有 erlexec port | 不归 Ezagent 管 |
| WS 连接发起方 | subprocess → Ezagent | subprocess → Ezagent(同方向) |
| Subprocess 重启 | Ezagent 监督 + 重拉 | 外部 host 决定 |
| 身份验证 | OSProcess 启动时注入 token | WS connect 时验 token |

WS 连接发起方都是 subprocess,**Ezagent 始终是 server side**——这是统一的。差异只在 subprocess 谁拉起。

### 12.5 `ctx.reply` 路由表

`Ezagent.Invocation.reply(ctx, result)` 根据 `ctx.reply` 字段路由:

| reply 形式 | 渲染动作 |
|---|---|
| `{:phoenix_channel, topic}` | `Phoenix.Channel.broadcast` 到该 topic |
| `{:phoenix_pubsub, topic}` | `Phoenix.PubSub.broadcast` |
| `{:plug_conn, conn}` | `Plug.Conn.send_resp` JSON |
| `{:stdio_pipe, port}` | 写 erlexec stdin 或 stdio framing |
| `{:mcp_response, request_id}` | MCP response packet |
| `{:caller_inbox, pid}` | `send(pid, {:ezagent_reply, ...})` — 内部 Elixir 调用回邮 |
| `:ignore` | 不回复(`:cast` mode 用) |

### 12.6 入口拒绝(不是所有 inbound 都变 Invocation)

某些 raw 事件(健康检查 ping、OPTIONS、协议握手、签名校验失败)在 Plug/Channel **内部直接 200 OK 或拒绝**,不进 dispatch。判断标准:**这条入口对应到一个 URI 吗?** 不对应,就在 adapter 内部处理。

### 12.7 View — Adapter 的对称面(outbound 渲染)

Adapter 是 inbound(外部 → Invocation)。**View 是 outbound**(Invocation / Message → 外部协议渲染)。每个 transport 注册一个 View module。

```elixir
defmodule Ezagent.View do
  @callback render(invocation :: %Ezagent.Invocation{}, ctx :: map()) :: iodata() | map() | nil
end
```

**View 是通用 Invocation 渲染器,不只 Message**——任何 Invocation 都可以注册渲染。Message 是 default 走 message-bubble 渲染,其他 Invocation(`/set-default`、`/invite`)可以渲染成 inline button、command echo、系统消息卡片等等,**取决于 transport 的能力**。

```elixir
defmodule Ezagent.View.LiveView do
  @behaviour Ezagent.View

  # Message → 气泡
  def render(%Invocation{args: %Ezagent.Message{} = m}, _), do: render_bubble(m)

  # /set-default → inline button
  def render(%Invocation{
    target: %URI{path: "/behavior/session_routing/set_default"} = uri,
    args: args
  } = inv, _), do: render_routing_change(uri, args, inv.ctx)

  # generic fallback → 系统通知小条
  def render(%Invocation{} = inv, _), do: render_generic(inv)
end
```

#### Render hint(可选)

`@interface` 可声明 `render_hint`,提示各 View 用什么形态渲染:

```elixir
@interface %{
  set_default: %{
    args: %{agent: :string},
    modes: [:call],
    render_hint: %{
      liveview: :inline_button,
      cli:      :command_echo,
      feishu:   :system_card
    }
  }
}
```

View 实现可以读 hint 决定渲染策略;没读到也行(fallback to generic)。**hint 是建议,不是强制**。

#### View 跟 routing 不耦合

Chat Behavior 收到 message 后做两件事(独立):
1. 用 routing rules 算出 receivers,逐个 dispatch Invocation
2. PubSub.broadcast 到 `<session_uri>:events`,触发各 transport 的 View 渲染

**View 不感知 routing,routing 不感知 View**——它们都从 `<session_uri>:events` 这个 PubSub topic 拿数据,各自独立处理。

> **Implementation**:`Ezagent.View` behaviour 定义 + view registry + render dispatch 总共 **~30 LOC**。各 transport 自己实现 View module(在自己 plugin 内,不进 ezagent_core)。

### 12.8 Claude Code Channel adapter — 唯一的 MCP 集成

Ezagent **不**内置通用 MCP server——内嵌 BEAM agent 直接调 Elixir API,Python/Bun adapter 走 WS,都不需要 MCP。**唯一的 MCP 集成**是 Claude Code Channel adapter,因为 Channels 是 Anthropic 给 Claude Code 的官方"外部事件 push"机制,**是 Ezagent 跟运行中 CC session 通信的唯一可靠方式**(pty stdin、文件 watch、CLAUDE.md 都太脆弱)。

#### 12.8.1 Channel = MCP server + 1 capability(Phase 1b 协议层洞察)

**Phase 1b 实证发现**(Decision #86):Claude Code Channels 协议**不是独立的通信协议**——它是 MCP 协议的一个扩展 capability。一个 Claude Code "channel" **就是一个普通的 MCP server**,只多了三件事:

| 协议 element | 位置 | 方向 |
|---|---|---|
| `capabilities.experimental['claude/channel'] = {}` | MCP `initialize` response | 声明这是 channel-capable server |
| `notifications/claude/channel`(JSON-RPC notification,no id) | server → claude(stdout 写) | 让 claude TUI 渲染 `<channel source="...">CONTENT</channel>` |
| 标准 MCP tools/call(如 `reply` tool) | claude → server | claude 调 tool 反向通信 |

整个 channel 跑在 **MCP stdio** 上(`--dangerously-load-development-channels server:<name>` 或 `--mcp-config`),跟普通 MCP server 完全同构。没有独立 WebSocket、没有 channel-specific framing、没有 channel-specific 认证(channel 协议本来有 sender allowlist 机制,但 Ezagent 用 CapBAC 取代,Channels protocol 那部分不实现)。

**v0.3 §12.8 的错误假设**:之前章节假设 channel 需要独立通信协议 + 独立 channel-server 进程 + Phoenix.Socket / WebSocket 作为 wire。**这个认知错误现已纠正**(Phase 1b 实证 + Channels reference 文档读后)。

**对比"普通 MCP"的 framing**:

| 普通 MCP | Channel-enabled MCP |
|---|---|
| Claude 主动调 tool(pull) | 同 + server 主动 push notification 进 session |
| 一次性 request/response | 长连接,事件流(stdin/stdout 长保持) |
| Tool 暴露给 LLM 用 | 同 + 在 LLM context 出现 `<channel source="xxx">` |
| 用于"赋予 LLM 能力" | 同 + 用于"通知 LLM 外部发生了什么" |

Channel 是**双向**的:server push notification 进 session 让 claude 看到外部事件;claude 调 server 暴露的 tool 反向通信(`reply` tool 是常见的 reply pattern)。底层 wire 仍然是 MCP stdio,**不是独立协议**。

**关于 LOC 对比的诚实表述**:Phase 1b `ezagent_plugin_cc_bridge_v1_prototype` 的 **minimum bidirectional channel ~250 LOC Python**。老 esr `cc_channel_runner`(973 LOC)和 cc-openclaw `channel_server`(4164 LOC)的代码量**不是纯 channel 协议层**——它们包含 channel 之外的功能(多 session 管理 / persistence / permission relay / production-grade error handling / 跨平台兼容 等等)。直接拿 4164 vs 250 对比是**不公平的**——这两个系统不止做 channel 一件事。

公平的对比是**协议层 surface**:
- 错误认知(v0.3 §12.8 假设):channel 需要独立协议 + 独立 server 进程 + WebSocket wire → 大量 framing/lifecycle 代码
- 纠正后(Phase 1b 实证):channel = MCP + 1 capability + 1 notification method → 普通 MCP server + ~3 处增量

**协议层简化是真的**(错误假设引起的过度工程);**LOC 比较的简化幅度**是模糊的(取决于 prior art 还做了什么 channel 之外的事)。

参考:<https://code.claude.com/docs/en/channels> 和 <https://code.claude.com/docs/en/channels-reference>

#### 12.8.2 Plugin 形态——单 plugin 两侧组件(基于 MCP 协议层简化)

整个 CC Channel 集成是**一个 plugin deliverable**:`ezagent_plugin_cc`。**两侧都跑标准协议**——Python 侧是普通 MCP server(stdio),Elixir 侧通过 HTTP / SSE 跟 Python plugin 通信(不是 Phoenix.Socket WebSocket)。

代码库结构:

```
ezagent_plugin_cc/                      ← 一个 git repo / release
  ├── elixir/                               ← Ezagent side(OTP app)
  │   ├── lib/ezagent_plugin_cc/
  │   │   ├── application.ex
  │   │   ├── bridge_server.ex              (GenServer:管理 bridge_id ↔ session 映射,push 队列)
  │   │   ├── announce_controller.ex        (Plug:接收 Python 来的 `/announce` 和 `/reply` HTTP POST;`/events_sse` 提供 push stream)
  │   │   └── instance_registry.ex          (CCInstanceConnection RoutingRegistry table)
  │   └── mix.exs
  ├── python/                               ← CC side(MCP server)
  │   ├── esr_channel/
  │   │   ├── __init__.py
  │   │   ├── mcp_server.py                 (普通 MCP server,stdio;声明 `claude/channel` capability)
  │   │   ├── notification_pump.py          (从 Ezagent /events_sse 拉 server-push,转 `notifications/claude/channel`)
  │   │   ├── reply_tool.py                 (MCP tool: claude 调 reply → POST 到 Ezagent /reply)
  │   │   └── config.py                     (读 Ezagent endpoint + bridge_id + token)
  │   └── pyproject.toml
  └── README.md
```

**Ezagent Elixir 侧 ↔ Python MCP server 的 wire 选择**:**HTTP/SSE**(Phase 1b 实证选择,Phase 5 实施时可重新评估)。理由:
- HTTP/SSE 比 Phoenix.Socket WebSocket 简单一个数量级(不需要 ChannelSocket + Channel module + Heartbeat / Reconnect 抽象)
- Server push 一侧用 SSE,Reply 一侧用普通 HTTP POST,各自最小协议
- Python `requests` / `httpx` 标准库支持,无需特殊 client 库
- 工程师 Phase 5 brainstorm 时如果发现 SSE 不够用(例如需要 bidirectional binary frame),再切回 WebSocket

**实现语言:Python 优先**(可复用 Phase 1b 实证的 `ezagent_plugin_cc_bridge_v1_prototype/python/`);Bun 也可,但 Python 跟 `ezagent_plugin_feishu` 一致,运维心智更统一。

#### 12.8.3 数据流(MCP stdio + HTTP/SSE)

**方向 1: Ezagent → CC**(向 Claude Code 推 message,push 模型)

```
[Ezagent routing 算出 receiver = agent://cc-allen-小满]
    │
    │ dispatch Invocation
    │   target: agent://cc-allen-小满/behavior/chat/receive
    │   args:   %Message{sender, body, mentions, ref}
    ▼
[CCChannelBridge Behavior (cross-cutting attached to Agent Kind)]
    │
    │ Phoenix.PubSub.broadcast("esr:cc_channel:to_claude:<bridge_id>", message)
    ▼
[Ezagent.PluginCc.AnnounceController.events_sse — SSE subscriber]
    │
    │ HTTP chunked SSE: data: {"content": "...", "meta": {...}}
    ▼
[Python MCP server: notification_pump.py]
    │
    │ 写 JSON-RPC notification 到 stdout:
    │   { "jsonrpc": "2.0",
    │     "method": "notifications/claude/channel",
    │     "params": { "source": "esr-channel", "content": "...", ... } }
    ▼
[Claude Code TUI(MCP client)]
    ← 渲染 <channel source="esr-channel" ...>CONTENT</channel> 进 LLM context
```

**方向 2: CC → Ezagent**(Claude 回复,通过标准 MCP tool)

```
[Claude Code session]
    → Claude reasoning 后调 `reply` tool
    │ JSON-RPC request 到 Python stdin:
    │   { "method": "tools/call", "params": {"name": "reply", "arguments": {...}} }
    ▼
[Python MCP server: reply_tool.py]
    │
    │ HTTP POST /api/cc-channel/reply
    │   {"bridge_id": "...", "text": "..."}
    ▼
[Ezagent.PluginCc.AnnounceController.reply]
    │
    │ build %Invocation{
    │   target: <原 session URI>/behavior/chat/receive,
    │   args:   %Message{sender: agent://cc-allen-小满, body, ref: <原 message URI>},
    │   ctx:    %{caller: agent://cc-allen-小满, caps, ...}
    │ }
    │ dispatch
    ▼
[Ezagent Message routing — 走标准 §5.5 路径]
```

整套路径里 "channel" 的语义是**MCP server 多发一个 notification + 暴露 1+ tools**,完全被 wrap 在 plugin 内,**Ezagent core 不感知**——它只看到 `agent://cc-xxx` 这个 Entity 通过某种 transport 接入,跟 Feishu user 接入同形。

**关键不变式仍然成立**:
- inbound message 走 `Ezagent.Invocation.dispatch/1`(Decision #75)— Python `reply_tool.py` POST 后,Ezagent Elixir 侧构造 Invocation 走 dispatch
- `ctx.caller = agent://cc-xxx` Entity 走 CapBAC 检查(§7,Decision #29)
- 不裸 `PubSub.broadcast` 到 inbound topic — outbound push 走 PubSub broadcast 到 SSE subscriber(这是 "broadcast 给不确定旁观者"的合法用法,符合 §5.7.6)
- **`notifications/claude/channel` 的 `meta` 字段 schema = `Record<string, string>`**(Decision #132, Phase 6 PR 26)——Anthropic channels-reference spec 强制约束,non-string value(list / map / nested object)让 claude TUI 整条 notification silently drop,**没有错误返回**。任何写 `meta` 的代码路径必须只用 string 值;结构化数据放 `content`(文本 breadcrumb)或走 `tools/call` 显式拉取。可选 `meta.file_path: <abs-path>` 字符串(单文件场景,仿 cc-openclaw 约定),由 claude `Read` tool 拉取内容。CI gate:`apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings"

#### 12.8.4 身份验证——单层鉴权,不用 channels sender allowlist

Channels 协议默认的 sender allowlist + pairing flow(`/telegram:access pair <code>`)**完全不用**。理由:Ezagent 已经有 CapBAC 系统,不需要重复鉴权。

**单层鉴权**:

1. **Python plugin 启动时**:读 config(`bridge_id` + `esr_token`),所有 HTTP request 带 token header
2. **Ezagent Elixir 侧 announce_controller 验 token**:验证后把 `bridge_id` 绑定到 `agent://cc-<instance>` URI,记录到 `CCInstanceConnection` table
3. **每条 inbound Invocation**(由 `reply_tool` POST 触发):走 §5.5 step 5.5 cap check——`ctx.caller = agent://cc-<instance>` 是否持有相应 cap

Python plugin config:

```python
# esr_channel/config.py
{
  "esr_url": "https://esr.local",      # HTTP (not WS)
  "esr_token": "<secret>",
  "bridge_id": "allen-小满-bridge-7f3a",
  "cc_instance_id": "allen-小满"
}
```

Ezagent Elixir 侧:

```elixir
defmodule Ezagent.PluginCc.AnnounceController do
  use Plug.Builder
  plug :verify_token

  def announce(conn, %{"bridge_id" => bid, "cc_instance" => instance_id}) do
    with {:ok, agent_uri} <- verify_and_resolve(conn, instance_id),
         :ok <- Ezagent.RoutingRegistry.put_new(CCInstanceConnection, instance_id, agent_uri) do
      send_resp(conn, 200, Jason.encode!(%{bridge_id: bid, status: "connected"}))
    else
      {:error, {:already_registered, existing}} ->
        # 撞 key——同一个 instance_id 已经有活连接(可能是孤儿/重连/配错)
        # 显式 reject,不静默 shadow(防 §1.2 差异 1 描述的 silent bug)
        Logger.warning("CC channel announce rejected: #{instance_id} already connected as #{inspect(existing)}")
        send_resp(conn, 409, Jason.encode!(%{error: "already_connected"}))
      _ ->
        send_resp(conn, 401, Jason.encode!(%{error: "unauthorized"}))
    end
  end
end
```

**为什么 `put_new` 而不是 `put`**:`put` 是 last-writer-wins,在 unique-key 表上会静默 shadow——第二个 connect 覆盖第一个,旧连接的 PING/PONG 还正常但 Ezagent 不再路由给它,**用户看得到系统输出但发的东西全部蒸发**(现有 esr 真实事故 `mcp-transport-orphan-session-hazard.md`)。

`put_new` 撞 key 显式 reject(返回 409),让重复连接**大声失败**而不是静默接管。如果旧的真死了,KindRegistry 的 monitor + 定期 health check 会清掉它,新连接重试即可。

**Channels 协议要求的 sender allowlist / pairing 流程,Python plugin 故意不实现**——它信任 HTTP token 验证后的 bridge 已建立的事实。

#### 12.8.5 多 CC 实例

一个 Ezagent 节点可同时连多个 CC 实例(Allen 的工作流:一个 worktree 一个 CC,5 个并行)。每个 CC 各自带 `--dangerously-load-development-channels server:esr-channel`,各自 Python plugin 通过 HTTP/SSE 连同一 Ezagent:

```
[CC instance allen-小满]  ─stdio─> [Python plugin #1] ─HTTP─┐
[CC instance feature-a]   ─stdio─> [Python plugin #2] ─HTTP─┼─→ [Ezagent /api/cc-channel/*]
[CC instance feature-b]   ─stdio─> [Python plugin #3] ─HTTP─┘
```

`CCInstanceConnection` 表(由 `ezagent_plugin_cc` 在 `RoutingRegistry` 注册):

```
{cc_instance_id: "allen-小满"} → agent://cc-allen-小满
{cc_instance_id: "feature-a"}  → agent://cc-feature-a
```

Ezagent 推 message 给 `agent://cc-allen-小满` 时,通过这张表找到对应连接(`bridge_id`),向对应 SSE stream broadcast push event,该 Python plugin 收到后 emit `notifications/claude/channel` 给它 stdio 上的 CC instance。

#### 12.8.6 跟 `ezagent_plugin_cc` 的关系

Ezagent 有两种 "CC 接入方式":

| Plugin | 接入方式 | 适用 |
|---|---|---|
| `ezagent_plugin_cc` | 本地 pty 拉起 claude binary | Ezagent 节点本机跑 CC,纯本地 |
| `ezagent_plugin_cc` | Channel 桥接外部 CC session | 跨机器接入(开发者笔记本上的 CC) |

**两者独立 plugin**,可同时装。生产部署常见两种都开——内部 dogfood 用 pty,远程开发者通过 channel 接入。

---

## 13. 命名约定

```
Ezagent.<Category>.<KindType>            — Kind 声明
Ezagent.<Category>.<KindType>.Server     — 单实例 GenServer
Ezagent.<Category>.<KindType>.Supervisor — DynamicSupervisor

Ezagent.ActionSet.<Name>                  — Behavior 模块

:ezagent_plugin_<name>                   — OTP app atom
EsrPlugin<Name>                      — Plugin 模块前缀
apps/esr_plugin_<name>/              — Umbrella 目录

:ezagent_behavior_<name>                 — 标准 Behavior 单 plugin(注册一个 Behavior)
:ezagent_adapter_<name>                  — 单侧 transport adapter(例:ezagent_adapter_cli)
:ezagent_plugin_<name>                   — 复合 plugin,可能含多组件(例:ezagent_plugin_cc 含 Elixir + Python 两侧)
:ezagent_web_<name>                      — Phoenix 入口(例:`ezagent_web`,Endpoint/Socket/Plug/auth boundary;`ezagent_web_liveview` 已 absorbed —— admin/world LiveView surface 现住 `ezagent_plugin_world`,`ezagent_web` 持 Phoenix entry + `home_live`)
```

### 13.1 Plugin 示例区分

实际 plugin 集的命名样例:

| Plugin | 类型 | 内容 |
|---|---|---|
| `esr_behavior_identity` | 单 Behavior | 注册 `Ezagent.ActionSet.Identity` |
| `esr_behavior_os_process` | 单 Behavior | 注册 `Ezagent.ActionSet.OSProcess`(底层 `:erlexec`) |
| `esr_behavior_pty` | 单 Behavior | 注册 `Ezagent.ActionSet.Pty`(底层 `:ex_pty`) |
| `esr_behavior_chat` | 单 Behavior | 注册 `Ezagent.ActionSet.Chat` |
| `esr_adapter_cli` | 单侧 adapter | CLI 工具,从 BehaviorRegistry 自动生成命令 |
| `ezagent_web` | Phoenix 入口 | Endpoint/Socket/Plug/auth boundary + `home_live`(`ezagent_web_liveview` 已并入此 + `ezagent_plugin_world`) |
| `ezagent_plugin_world` | 复合 plugin | world Conversation surface(`Ezagent.World.ConversationActions`/`ConversationData`)+ kanban UI + admin/world LiveView surface |
| `ezagent_plugin_kanban` | 复合 plugin | `Behavior.Kanban`(board/task mechanism)+ `kanban_manager` role recipe |
| `ezagent_domain_socialware` | domain | socialware substrate:`ExternalMirror`/`PublicView`(compat facade)/`anon_user`/`chat_feed`/`external_feed` |
| `ezagent_plugin_cc` | 复合 plugin | 注册 `Ezagent.Session.CC`,通过本地 pty 拉 claude binary |
| `ezagent_plugin_cc` | 复合 plugin | 含 Elixir adapter + Python channel server 两侧,桥接外部 CC |
| `ezagent_plugin_feishu` | 复合 plugin | 含 Elixir adapter + Python feishu bot |

---

## 14. ezagent_core 模块布局

```
ezagent_core/
└── lib/
    ├── esr/
    │   ├── uri.ex                # URI parser + scheme registry          (~25 LOC,cap 35)
    │   ├── invocation.ex         # %Invocation{} + dispatch + reply      (~95 LOC,cap 120)
    │   ├── interface_validator.ex # @interface schema 递归校验器          (~35 LOC,cap 50)
    │   ├── idempotency.ex        # bounded ETS dedup(LRU)               (~20 LOC,cap 35)
    │   ├── message.ex            # %Message{} struct + identity helpers  (~25 LOC,cap 35)
    │   ├── message_store.ex      # append-only Message persistence + 7-dim query (~50 LOC,cap 70)
    │   ├── capability.ex         # %Capability{} + matcher               (~30 LOC,cap 40)
    │   ├── behavior.ex           # @callback contract                    (~15 LOC,cap 25)
    │   ├── kind.ex               # `use Ezagent.Kind` macro                  (~90 LOC,cap 130)
    │   ├── kind_registry.ex      # URI → pid + type_name → module        (~40 LOC,cap 55)
    │   ├── behavior_registry.ex  # {Kind, action} → Behavior             (~50 LOC,cap 70)
    │   ├── routing_registry.ex   # external_key → URI(s) + put_new       (~60 LOC,cap 80)
    │   ├── ready_gate.ex         # ETS 三态 ready 表                     (~20 LOC,cap 30)
    │   ├── pending_delivery.ex   # not-ready 窗口 buffer + flush         (~25 LOC,cap 40)
    │   ├── routing/
    │   │   └── matcher.ex        # 组合子 + Message-field matcher + DSL   (~85 LOC,cap 110)
    │   ├── view.ex               # View behaviour + render dispatch      (~30 LOC,cap 40)
    │   ├── kind/
    │   │   ├── template.ex       # @callback contract                    (~15 LOC,cap 25)
    │   │   └── snapshot.ex       # snapshot load/save (kind_type-keyed)  (~40 LOC,cap 55)
    │   ├── plugin.ex             # discover/0 + drain/1 + attach/1       (~80 LOC,cap 110)
    │   ├── telemetry.ex          # event helpers                         (~20 LOC,cap 30)
    │   ├── audit/
    │   │   └── writer.ex         # async batch flush GenServer           (~30 LOC,cap 45)
    │   └── scheduler.ex          # Process.send_after wrapper            (~40 LOC,cap 55)
    └── ezagent_core.ex
```

### LOC budget

| 指标 | 数值 |
|---|---|
| Target 总和 | **~920 LOC**(v0.4 round-2 review:`message_store.ex` 之前漏在 §14 清单外,补进来 +50 LOC;原 870 是不含它算出的) |
| Hard ceiling per module | 列在每行 `cap` 后(target + 40% buffer) |
| 复杂度警戒线 | 任何模块超过 cap,触发**设计 review**——大概率是漏抽象,不是逻辑必要 |
| 全局警戒线 | 总和超过 **1150 LOC**(实测合计,而非各模块 cap 之和),触发架构 review:看是不是该把某些功能 spin off 成 plugin |

**关于 "各模块 cap 之和 > red line" 的说明**:每模块 cap 的总和会超过 1150(实际约 1285),这是**预期的**——cap 和 red line 是两个独立信号:

- **每模块 cap** = "单个模块的复杂度异常天花板"(防止某个模块膨胀到吞掉整个系统的认知负担)
- **red line** = "整个 ezagent_core 实测合计的集合触发器"(防止整体超出 thin glue 定位)

所有模块同时用满 cap 不太可能(意味着每个都达到异常上限);更常见的形态是大部分模块在 target 附近,少数偶尔触 cap,合计在 920 ± 100 范围。**实测合计**才是 red line 的指标。

**为什么 v0.4 比 v0.3 多 ~325 LOC**:
- `invocation.ex` 70→95(arg validation + 7-case reply 表实测)
- `kind.ex` 40→90(`use Ezagent.Kind` 宏生成完整 GenServer + snapshot 集成 + ReadyGate 接入)
- `matcher.ex` 50→85(11 个 constructor + 递归求值器 + DSL + plugin register + `to_string/1`)
- 新模块 `interface_validator` / `ready_gate` / `pending_delivery` / `idempotency` / `audit/writer` 共 ~130 LOC
- `message_store.ex` ~50 LOC(v0.3 漏列;v0.4 round-2 review 工程师发现的缺口)

**dev review 的 LOC 实测论证扎实**:现有 esr `handler_router + handler` 116 行只覆盖了 dispatch 的"调 Python worker"一条窄路径,不含 arg validation、不含 7-case reply 表;9 个 registry 共 1722 行也佐证了核心模块的真实复杂度。v0.3 的 475/595 是欠校准,v0.4 round-1 校准到 870 但仍漏 `message_store.ex`,round-2 补足到 920。

**为什么强调 LOC budget**:`ezagent_core` 的承诺是 "thin convention layer + glue"。一旦 core 膨胀,plugin 边界会模糊,新人也得读大量 core 才能写第一个 plugin。**保持 core 小 = 保持心智成本可控**。920 LOC 还在"几个工程师一天能通读"的范围,red line 1150 是真实 ceiling。

Plugin 不在此 budget 内——plugin 想多大都行,但应该自己有内部模块边界纪律。

#### 14.x Phase 3-4 + Phase 4-completion 实测校准

到 Phase 4-completion 闭包,**总实测 12,037 LOC across 8 apps**(v0.4 ezagent_core target 920 不再适用 — 现在是 umbrella 形态)。按 app 拆解:

| App | 实测 LOC | 主要内容 |
|---|---|---|
| ezagent_core | 5,841 | dispatch / Registry/3 / Audit / ReadyGate / Idempotency / PendingDelivery / Snapshot real + Writer / Workspace(Kind+Behavior+Store+Loader+facade)+ SpawnRegistry + TemplateRegistry + Routing(Matcher 5 leaf + 3 combinators + Resolver + RuleStore + RoutingRegistry) + Identity + Users + Capability(+ Parser) + Cap real check + check_invariants Tasks + mix ezagent.* tasks(6 个)|
| ezagent_cli | 870 | Optimus auto-derive: TreeBuilder + Coercion + Dispatch + Formatter + FacadeRegistry + Mix.Tasks.Esr |
| esr_plugin_chat | 1,146 | Chat Behavior + 4 actions + Agent/Session Entity + DefaultRules + 2 routing tables + GenericSession Template |
| ezagent_plugin_echo | 144 | Echo Behavior + Entity(Phase 1 demo,稳定不动)|
| ezagent_plugin_cc_bridge_v1_prototype | 450 | MCP bridge Phase 1(v1_prototype 保留;Phase 5 重写但 cc-pty plugin 现在覆盖了使用场景)|
| ezagent_plugin_cc | 417 | Template Class + PtyServer + Application(wraps shell script via PTY; auto-confirm dialog) |
| ezagent_web | 1,486 | Phoenix Router + Endpoint + Controllers(login + cc-bridge announce + SSE)+ Plug.RequireUser + `home_live` |
| ~~ezagent_web_liveview~~ | ~~1,683~~ | **已并入** `ezagent_plugin_world`(world/admin LiveView surface:Conversation + kanban UI)+ `ezagent_web`(Phoenix entry)。旧 `ezagent_plugin_liveview` 名由 `lv_cli_parity` invariant enforce 不存在 |
| ezagent_plugin_world | — | world Conversation surface(`Ezagent.World.ConversationActions`/`ConversationData`)+ kanban UI + admin LiveView surface(chat socialware 的 surface) |
| ezagent_plugin_kanban | — | `Behavior.Kanban`(board/task mechanism)+ `kanban_manager` role recipe(passive,per-instance mount on `Entity.Agent`) |
| ezagent_domain_socialware | — | socialware substrate:`ExternalMirror`/`PublicView`(compat facade)/`anon_user`/`chat_feed`/`external_feed`/`Installation` 调用点 |

**Phase 4-completion 增量(从 Phase 4d 到现在)**:~3,800 LOC across 9 PRs(Template + Snapshot + CLI + Multi-user prov + Multi-user UI + Matcher combinators + Routing LV editor + CC PTY + Routing consolidation)。所有 PR 都有 invariant test;主要架构 gate 数 = 5(plugin isolation workspace / snapshot restart / CLI auto-derive / routing consolidation no-leak / cc-pty Template Class via real plugin)。

**v0.4 target 与实测差距的根因**:
- v0.4 budget 只算"光纯逻辑 SLOC"(不含 `@moduledoc` / `@doc` / 空行 / 单行结构) — 工程师习惯写法多 40-60% 的注释/空行,等量逻辑实际 file 行数翻倍
- v0.4 budget 漏算了 `behaviour` 模块本身的 callback boilerplate(`Ezagent.Kind` / `Ezagent.ActionSet` 各 ~80 LOC 的 callback 声明 + typespec)
- v0.4 budget 漏算了 `mix ezagent.*` 任务(Phase 3-4 增加 4 个,共 ~250 LOC)— 严格说不是 ezagent_core 模块库,但放在 `apps/ezagent_core/lib/mix/` 下计入了

**结论**:v0.4 target 920 应理解为 "**纯逻辑 SLOC 的设计估算**",而不是 "file LOC 上限"。Phase 5 不建议追逐 920 数字本身;追的应该是:
1. **每个 lib/ 顶层模块是否仍 < cap**(单模块复杂度信号,实测合规)
2. **能否清晰描述每个模块的单一职责**(架构边界信号,Phase 4 invariant test 直接量化)

#### 14.y Phase 4 plugin-isolation 北极星的 LOC 维度

`Ezagent.SpawnRegistry`(86 LOC)+ `Ezagent.Workspace.{Store,Loader,Behavior}`(620 LOC)= **plugin 作者新增 Kind 不动 ezagent_core 的 LOC 代价**:0(全在 ezagent_core 一次性铺设)+ plugin 自己 register_spawn_fn 的 ~5 行。这是 Decision #66 / #70 / #88 的 LOC 兑现。

### Phase 3 实测校准(impl,2026-05-16)

**目前 ezagent_core/lib 实测 3,467 LOC,远超 v0.4 red line 1150**。诚实拆账:

| 来源 | 增量 LOC | 注释 |
|---|---|---|
| 原 v0.4 estimate(以 LOC-only,不含 moduledoc) | ~920 | 设计期估计 |
| 实测 v0.4 + comments / moduledoc(每模块 30-100 行) | ~1,400 | 现实是每个文件有详细 moduledoc + section comments |
| Phase 3 加 `routing/`(matcher 169 + resolver 86 + rule_store 132) | +387 | 完全新增,设计期没算 |
| Phase 3 加 `routing_registry.ex`(211 vs cap 80) | +131 | 比 cap 大,因为 3-table-family + owner-pid check 比 BehaviorRegistry 复杂 |
| Phase 3 加 `behavior/identity.ex` | +86 | Identity Behavior |
| Phase 3 加 `message_routing.ex`(关联表 schema) | +37 | #98 fix |
| `mix/tasks/ezagent.check_invariants.ex`(8 invariants + grep filters) | +319 | mix task,不计 lib |
| `audit.ex` 实测 178(cap 45) | +130 | telemetry handler + 4 build_row clauses + serialization |

**判断**:v0.4 budget 是从 "lib 行数(无 docs)" 视角估的,实测含 moduledoc/comments 3x 是正常。**Phase 3 跑完不动 §14 budget 数字**,因为:
1. 没有单文件超 1000 LOC(top: routing_registry.ex 211)— per-module cap 信号还有意义
2. 实测合计 3,467 跟 v0.4 估的 870 数量级差,但跟 "1,400 v0.4 实际 + Phase 3 增量 ~650 + audit/telemetry 增长 ~500 + dev moduledoc 增长" 加起来吻合
3. 真正的纪律 = **plugin 边界严** + **每个文件 single responsibility** — 而非 LOC 数字本身

**Phase 4 起新原则**:LOC budget 改为 "**每个 sub-system 总和 + 单文件 cap**" 双指标,sub-system = routing / audit / kind / message,而不是整个 ezagent_core 一个数字。Phase 4 spec 时确定。

---

## 15. Dependencies (mix.exs)

```elixir
defp deps do
  [
    # Phoenix transport layer (核心)
    {:phoenix,                "~> 1.8"},
    {:phoenix_pubsub,         "~> 2.1"},
    {:bandit,                 "~> 1.5"},
    {:plug,                   "~> 1.16"},

    # 数据 (核心) — SQLite for edge-deployable single-file storage
    {:ecto_sql,               "~> 3.12"},
    {:ecto_sqlite3,           "~> 0.17"},

    # 观测
    {:telemetry,              "~> 1.3"},
    {:telemetry_metrics,      "~> 1.0"},
    {:opentelemetry,          "~> 1.5"},
    {:opentelemetry_telemetry,"~> 1.1"},

    # HTTP client(plugin 调外部 API)
    {:req,                    "~> 0.5"},

    # JSON
    {:jason,                  "~> 1.4"}
  ]
end
```

**12 个生效依赖**(v0.2 是 16,v0.3 早期版本是 13)。

### 15.1 为什么 SQLite 而非 Postgres

| 维度 | SQLite | Postgres |
|---|---|---|
| 单文件部署 | ✅ `priv/esr.db` 跟 BEAM release 一起 | ❌ 独立进程 + 配置 |
| 边缘硬件(Raspberry Pi 级) | ✅ ~5MB | ⚠️ 100MB+ RSS |
| Docker image | 小,无外部依赖 | 大(需 postgres image) |
| 备份 | `cp esr.db backup.db` | `pg_dump` + 恢复流程 |
| 故障恢复 | 跟 BEAM 同生死 | DB 进程独立维护 |
| Federation 形态 | 每节点一 DB,share-nothing | 共享 DB,集群范式 |
| 写并发(WAL 模式) | ~10k writes/sec,够 Ezagent 边缘场景 | 高并发 MVCC |

**Ezagent 的定位是 federated edge nodes**——每个节点是个完整自治的 Ezagent,跟其他节点通过协议通信。SQLite 的 share-nothing 形态比 Postgres 的 shared central infra 更对得上这个定位。

### 15.2 移除的依赖

| 依赖 | 原用途 | 替代 |
|---|---|---|
| `:postgrex` | Postgres driver | 不需要,用 SQLite |
| `:oban` | snapshot 定时 / DLQ evict / audit archival 等 | **`Ezagent.Scheduler`** 用 `Process.send_after/3`,~15 LOC;DLQ evict 在 insert 时同步处理 |

**Deferred 到 v0.x+ 的库**:
```elixir
# {:horde,                          "~> 0.9"},    # 跨节点 Registry/Supervisor
# {:commanded,                      "~> 1.4"},    # Event Sourcing
# {:commanded_eventstore_adapter,   "~> 1.4"},
# {:req_s3,                         "~> 0.2"},    # 大文件附件存 S3,边缘节点通常不需要
```

### 15.3 Schema portability(不维护)

SQLite vs Postgres 语法差异在 spec 里**不存在**——v0 完全 SQLite。未来如果某个部署形态需要 Postgres,届时再讨论 portability。**现在 spec 不维护双轨**,避免"一点点不一样"的混乱。

具体 schema 写法(§10 详述):
- JSONB 字段:Ecto `:map` 字段类型,SQLite 自动 JSON 文本存储
- 数组字段:Ecto `{:array, :string}` 类型,SQLite 自动 JSON 数组序列化
- Timestamps:`utc_datetime` 类型,SQLite ISO 8601 文本存储
- 主键:`text` 字符串(用 URI),不用 `bigserial`

### 15.4 ezagent_core 不依赖,移到独立 plugin

- `:erlexec` → `esr_behavior_os_process`
- `:ex_pty` → `esr_behavior_pty`
- `:optimus` → `esr_adapter_cli`(CLI 参考实现,见 Appendix D)
- `:phoenix_live_view` → `ezagent_plugin_world` / `ezagent_web`(IM dogfood + admin/world LiveView surface;旧 `ezagent_web_liveview` 已并入,见 §13.1)
- `:phoenix_live_dashboard` → 开发期 dep,ezagent_web 应用层加

---

## 16. What's ours vs ecosystem

按 Phoenix-first 优先级排序:

| 概念 | 生态对应 | 优先级 | 自己写 LOC |
|---|---|---|---|
| WS / Channel transport | **`Phoenix.Socket`** + **`Phoenix.Channel`** | 1 | — |
| 同步 HTTP 入口 | **`Plug`** + **`Phoenix.Endpoint`** + **`Bandit`** | 1 | — |
| actor 间消息总线 | **`Phoenix.PubSub`** | 1 | — |
| 跨节点在线状态 | **`Phoenix.Presence`** | 1 | — |
| `:subscribe` mode | `Phoenix.PubSub` | 1 | — |
| Transport path 路由 | **`Phoenix.Router`** | 1 | — |
| 配置 / 定义 / audit | **`Ecto`** + **`Postgrex`** | 3 | — |
| Snapshot 持久化 (C) | `Ecto` + JSONB | 3 | ~40 helper |
| HTTP client | **`Req`**(plugin) | 3 | — |
| 后台调度 | **`Oban`** | 3 | — |
| Kind instance | **`GenServer`** | 2 | — |
| KindType.Supervisor | **`DynamicSupervisor`** | 2 | — |
| KindRegistry | **`Registry`** / **`Horde.Registry`**(v0.2+) | 2 | ~30 wrapper |
| BehaviorRegistry | **ETS** | 2 | ~50 |
| **RoutingRegistry** | **`Registry`**(duplicate_keys) | 2 | ~60 wrapper |
| Plugin = OTP app | **`Application`** + **`Supervisor`** | 2 | — |
| Plugin drain helper | (无) | — | ~20 |
| Plugin discover | **`Application.loaded_applications/0`** | 2 | ~80 |
| Telemetry 钩点 | **`:telemetry`** | 2 | ~20 helpers |
| Distributed traces | **OpenTelemetry** stack | 2 | — |
| os-process(被 plugin 用) | **`:erlexec`** | 4 | — |
| pty(被 plugin 用) | **`:ex_pty`** | 4 | — |
| CLI 渲染(被 plugin 用) | **`Optimus`** | — | — |
| URI parser | `URI` stdlib | 2 | ~25 |
| Invocation struct + dispatch + reply | (无) | — | ~70 |
| Capability struct + matcher | `MapSet` + 自写 | — | ~30 |
| Behavior `@callback` | `@behaviour` Erlang | 2 | ~15 |
| `use Ezagent.Kind` 宏 | (无) | — | ~40 |
| `Ezagent.Kind.Template` | `@behaviour` | 2 | ~15 |

**自己写代码 ≈ 920 LOC**。其余全部装配。

### 16.1 真正的创新只有五条

剥掉装配,核心创新都是**约定,不是组件**:

1. **URI 作为 system-wide operationId**(类比 OpenAPI)
2. **`@interface` 强制 schema 声明**,所有 adapter 从此生成
3. **Behavior 模块化 + state slicing 约定**
4. **Push-style CapBAC 在 Kind instance 鉴权**
5. **Plugin = OTP app + drain-then-stop 生命周期**

---

## 17. Deferred

显式不做的功能列表:

### 17.1 Next.js admin dashboard(LiveView 之外的另一条路)

LiveView 已经在 v0 内用作内部 IM dogfood 前端(见 §2.2),BEAM-native dashboard 的能力天然在手。Next.js 作为另一条选项保留:

- **触发条件**:出现"前端需要独立部署 / 跨域 / 大量 JS interactive 组件 / 设计师只熟悉 React"的需求
- **路径**:`esr_plugin_admin_next` 维护 React 代码,通过 AdminAPI(REST/JSON)与 Ezagent 通信
- **最终主用哪条**:看 dogfood 结果。两条并存也可。

### 17.2 Event Sourcing — **不做**(已决,见 §1.3 + Decision Log)

完整 Event Sourcing 不在 v0.x roadmap 上。理由(详见 Decision Log):

- append-only Message stream 已经具备 ES 的所有真实好处(不可变审计、message identity invariant、context replay 源)
- ES 的复杂度(Commanded + Postgres-only EventStore + aggregate 边界 + event versioning + CQRS)对 Ezagent 场景**没有匹配收益**
- Ezagent 的 schema 还在剧烈演化,event versioning 是过早承担的负担
- Agent 行为非确定(LLM),event replay 本身意义有限

未来如果出现金融/监管/合规场景需要严格 event replay,届时重新评估——但不作为 deferred,作为**已决不做**。

### 17.3 Federation — 独立 Ezagent 节点 + cross-node 协议(v0.x+)

每个 Ezagent 实例(SQLite + 单 BEAM)是**完全自治的边缘节点**。Federation 形态:

- **不共享数据库**——每节点一个 SQLite 文件,share-nothing
- **不共享 BEAM cluster**(`Node.connect`)——节点间独立,只通过应用层协议通信
- **Cross-node 消息协议**——大概率走 IRC s2s-style 协议(节点 A 把 message envelope 转发给节点 B,B 的本地 Session 处理),或 MCP-over-WS

主要决策点(留作未来 grill):
- Federated routing — 本地 RoutingRegistry vs 全局可见?跨节点 URI 怎么表达?
- Federated cap — 单节点 cap vs 跨节点信任链?Token 模型是不是这里的必要前提?
- Federated Message identity — Message URI 在跨节点中转时仍要 invariant,怎么保证?

v0 单节点,**所有 federation 设计推迟**。但 §10 的 share-nothing 持久化、§5.4 的 URI 寻址、§7 的 Push CapBAC 都已经为 federation 留好了接口——不需要重新设计,只需要加协议层。

### 17.4 Horde 跨节点 Registry(v0.x+,如果走 BEAM cluster 而非 federation)

如果某个部署不走 federation,而是传统 BEAM cluster(多节点共享 Registry):
- **`Horde.Registry`** + **`Horde.DynamicSupervisor`** 替换单节点 `Registry`
- pty Session 不能跨节点迁移(pty fd 是 node-local)→ 约定"pty Session 绑定单节点"

跟 17.3 是**两种不同形态**,大概率走 17.3(federation),不走 17.4。

### 17.5 Cap Token 化
- 方案:**Macaroon** / **Biscuit** 替换 `MapSet<Capability>`
- 触发条件:跨信任域调用

### 17.6 Cap delegation & attenuation
- 触发条件:出现真实"A 把部分权限授给 B"场景

### 17.7 `@interface` runtime 强校验
- v0 compile-time 简单 check;runtime 强校验 + ExUnit `@interface` property-based test gen

### 17.8 Cross-cutting plugin migration CLI
- `mix ezagent.plugin.grant <plugin>`,批量给已存在 principal 发新 cap

### 17.9 Event archival pipeline
- D / E 冷数据移 S3 通过 **Oban** 周期任务

### 17.10 Voice
- voice channel(WebRTC / SIP)— 独立 channel kind,不影响主架构

### 17.11 Bundle
- 显式不做。"一组 plugin + 默认 template 一键部署" = `mix release` profile + `priv/seeds/*.exs`;不发明新抽象

### 17.12 Routing 迁移分诊规则(给现有 esr → v0 迁移用)

现有 esr 的 9 个 registry 共 1722 行 routing 逻辑,**不一次性迁**。**逐个分诊**——问"v0.4 新模型是不是已经免费提供了这个"。

| 这段代码是 | v0 怎么办 |
|---|---|
| 旧架构偶然复杂度(新模型免费提供) | **不迁——蒸发**(例:slash_route registry 的 493 行,核心是手动注册路由 + overlay 合并,但 v0.4 Appendix D.3.4 说 slash 路由从 `@interface` 自动派生——那一大坨在新模型里根本不存在,剩 ~30 行真·prefix 匹配迁过来即可) |
| 真实业务逻辑 / 踩出来的行为边界 | **在新模型里重新表达**——旧代码当"必须保留的行为"规格,e2e scenario 当验收测试 |
| verbatim 值得保留的好设计 | 几乎没有 |

具体例:
- `slash_route/registry.ex`(493 行)→ **大部分蒸发**,剩 ~30 行真·prefix 匹配
- `chat_routing/registry.ex`(417 行)→ **拆两半**:attach/detach/current 翻译进一张 RoutingRegistry 表 + 一个薄 Behavior;搭便车的 default_workspace state 不跟着迁
- 其余 7 个小 registry → **大多蒸发**(thin wrapper,融进通用 RoutingRegistry)

**V0 范围建议**:别一次迁 9 个。**feishu-cc 垂直切片**只需 §10.7 的 3 张表(ChatRouting / PrincipalMapping / SessionRules),做出来跑通 e2e,模式立住了,其余等各自 plugin 上线时按同一模式重新表达。这样 v0 期工作量 = ~50 行新写 + e2e 复用,不是 1722 行重写。

---

## 18. 已决问题汇总 / 给实施者的参考

### 18.1 已决问题速查

本轮 grill 已经决定的问题列表(详见 Decision Log 对应编号):

| 主题 | 已决方案 | Decision # |
|---|---|---|
| Python adapter ↔ Ezagent 协议 | 三种 transport 全 first-class(WS / stdio / MCP via channel) | #36 |
| RoutingRegistry table 集合 | core 不预定义,plugin 自声明 | #37 |
| Routing 路径编辑与切换 | additive rules + matcher DSL | #41 |
| `:on_change` 触发时机 | slice 值真变了才写(`new_slice != old_slice`) | #59 |
| Audit log 写入策略 | 异步 — GenServer cast + batch + 100ms flush;BEAM 原生,不用 Oban | #60 |

### 18.2 测试策略(留给实施者决定)

供参考的方向,具体实施可调整:

- **Unit**:Behavior 是纯函数,**直接调 `handle_<action>(args, ctx)` 测**(post-2026-05-28 新合约),断言返回的 `{:ok, result, effects}` shape;无 mock。pre-Phase-3 的 `invoke/4` 测试模式见 §6.1。
- **Integration**:Kind GenServer + Registry + SQLite snapshot,真实数据库测
- **E2E**:full plugin loaded + `Phoenix.ChannelTest`(对 transport)、HTTP client(对 Webhook)
- **现有 31 个 e2e bash 的迁移**:推荐先迁核心 10 个 happy path,长尾留 v0.3.x

具体测试框架选择、CI 集成方式、覆盖率目标、性能基准等,由当前 Ezagent 实施同事按团队工程实践决定。

---

## Appendix A: Invocation Flow

```
Adapter           Ezagent.Invocation        Kind GenServer     Behavior       :telemetry
  │                    │                     │                │              │
  │ 1. dispatch(%I{})  │                     │                │              │
  ├───────────────────→│                     │                │              │
  │                    │ 2. parse URI →                       │              │
  │                    │    {kind, id, action}                │              │
  │                    │ 2.5 validate args                    │              │
  │                    │     against @interface               │              │
  │                    │ 2.7 idempotency check                │              │
  │                    │     if ctx.idempotency_key &&        │              │
  │                    │        Idempotency.seen?(key)        │              │
  │                    │     → {:ok, :duplicate_ignored}      │              │
  │                    │     else: Idempotency.record(key)    │              │
  │                    │ 3. ReadyGate.status(receiver_uri)    │              │
  │                    │    + mode-aware routing:             │              │
  │                    │    - :ready → KindRegistry.lookup    │              │
  │                    │    - :not_ready + :cast → buffer     │              │
  │                    │    - :not_ready + :call → fail-fast  │              │
  │                    │    - :unknown → {:error, :no_actor}  │              │
  │                    │ 4. GenServer.call/cast(pid, ...)     │              │
  │                    ├────────────────────→│                │              │
  │                    │                     │ 5. BehaviorRegistry.lookup    │
  │                    │                     │    → behavior_module          │
  │                    │                     │ 5.5 ⚑ AUTHZ GATE              │
  │                    │                     │    needed ∈? ctx.caps         │
  │                    │                     │ 6. slice = state[slice_key]   │
  │                    │                     │ 7. invoke(action, slice, ...) │
  │                    │                     ├───────────────→│              │
  │                    │                     │ 8. {:ok, new_slice, result}   │
  │                    │                     │←───────────────┤              │
  │                    │                     │ 9. put_in(state, ...)         │
  │                    │                     │    [snapshot if new_slice     │
  │                    │                     │     != old_slice]             │
  │                    │                     │ 10. :telemetry [:ezagent, ...]     │
  │                    │                     ├──────────────────────────────→│
  │                    │ 11. {:ok, result}   │                │              │
  │                    │←────────────────────┤                │              │
  │                    │ 12. Invocation.reply(ctx, result)    │              │
  │                    │     → 根据 ctx.reply 路由            │              │
  │←───────────────────┤                                      │              │
  │ (push / broadcast / HTTP response / ...)                  │              │
```

**关键 step 解释**:

- **Step 2.7 Idempotency**:adapter 在外部协议有 `message_id` 时填 `ctx.idempotency_key`(例:`"feishu:om_abc123"`)。`Ezagent.Idempotency` ETS 表 bounded 10k(LRU),`seen?(key)` 返回 true → 直接 `{:ok, :duplicate_ignored}`,不进 Kind。**Webhook 重试自动去重,不重复修改 state**。
- **Step 3 ReadyGate 路由**:`:cast` mode 到 not-ready actor 可 buffer(PendingDelivery);`:call` / `:call_stream` 不可 buffer——caller 同步阻塞等结果,buffer 会撞 `deadline_ms`,必须 `{:error, :not_ready}` fail-fast,让 caller 自己决定重试。
- **Step 9 Snapshot**:`new_slice != old_slice` 才写——slice 真变了才落 SQLite。BEAM 不可变 + 值比较自然给出正确语义,plugin 作者不需要管 dirty 标记。

**失败路径**:

| 失败点 | 行为 |
|---|---|
| step 2.5 args validation fail | `{:error, {:invalid_args, violations}}`(不进 Kind) |
| step 2.7 duplicate detected | `{:ok, :duplicate_ignored}` — **不是失败,是预期**,但 telemetry `[:ezagent, :idempotency, :hit]` 记一次 |
| step 3 receiver `:unknown` | `{:error, :no_such_actor}` + telemetry `[:ezagent, :dispatch, :no_actor]` |
| step 3 `:not_ready` + `:call` | `{:error, :not_ready}` — caller 应重试或放弃 |
| step 5 behavior not registered | `{:error, {:unknown_action, action}}` |
| **step 5.5 cap missing** | `:telemetry [:ezagent, :authz, :denied]` + `{:error, :unauthorized}` |
| step 7 behavior raises | caught;`[:ezagent, :invoke, :exception]`;state untouched;**写入 DLQ** |
| step 9 snapshot 写失败 | `[:ezagent, :persistence, :failed]`;state 已更新,下次 snapshot 追上 |
| Kind GenServer crash | DynamicSupervisor restart;init 从 snapshot 恢复;caller 收 `{:exit, _}` |
| **零匹配 routing**(§5.5.5) | `[:ezagent, :routing, :unroutable]` + DLQ 'unroutable' 队列 |

---

## Appendix B: Decision Log

按讨论顺序累积(v0.1 → v0.2 → v0.3 → v0.4 → impl):

| # | 决策 | 起源 |
|---|---|---|
| 1 | ❎ Mixin → ✅ Dispatch via Registry | v0.1 |
| 2 | URI + Verb + Args 三元组(verb 不进 URI) | v0.1 |
| 3 | Umbrella + `Ezagent.<Category>.<KindType>.{Server, Supervisor}` 命名 | v0.1 |
| 4 | Macro hygiene 问题 → Slice 隔离消解 | v0.1 |
| 5 | Plugin 卸载:drain till instance=0,then stop | v0.1 |
| 6 | Template:`Ezagent.Kind.Template` 通用 | v0.1 |
| 7 | Channel → ExternalChannel in Resource | v0.1 |
| 8 | CapBAC 粒度:Behavior 级 | v0.1 |
| 9 | CapBAC 携带:Push(未来 Token) | v0.1 |
| 10 | Plugin 默认 cap `:self`,Creator 全权 | v0.1 |
| 11 | ❎ Delegation / Attenuation(v0) | v0.1 |
| 12 | `:self` grant-time resolution | v0.1 |
| 13 | Command / Interface 是 tag,不是 subtype | v0.1 |
| 14 | A/B/D Ecto,C v0 Snapshot,v0.4+ ES | v0.1 |
| 15 | Plugin convention,不走 DSL | v0.1 |
| 16 | Plugin discovery 通过 `Application.spec :env` | v0.1 |
| 17 | Cross-cutting Behavior attach 五条规则 | v0.1 |
| 18 | "框架"心态退役,项目 = 约定 + 装配 | v0.1 |
| 19 | **Phoenix ecosystem first** | v0.2 |
| 20 | **ES 推迟到 v0.4+**,v0 用 Snapshot | v0.2 |
| 21 | **URI as universal operationId**(类比 OpenAPI) | v0.3 |
| 22 | **`@interface` 升为强制 schema**,`@command` tag 删 | v0.3 |
| 23 | **Adapter pattern 升为顶层**,所有外部入口都是 adapter | v0.3 |
| 24 | **`ctx.reply` 协议无关回复路由** | v0.3 |
| 25 | **Mode 加 `:call_stream`**,集合扩到 5 个 | v0.3 |
| 26 | **`erlexec` / `:ex_pty` 归位到 Behavior 内部**,不是顶层 Process impl | v0.3 |
| 27 | **删除 v0.2 的 Process trait/impl 抽象**,Kind = GenServer 是唯一执行模型 | v0.3 |
| 28 | **新增 RoutingRegistry**(第三种 Registry 家族,统一 n×n routing) | v0.3 |
| 29 | **`erlexec` / `:ex_pty` / `:optimus` 移出 `ezagent_core`**,独立 plugin | v0.3 |
| 30 | **CapBAC scope 加 `{:within_session, session_uri}`** | v0.3 |
| 31 | **Phoenix-as-transport,不是 fullstack**;LiveView 推迟,Next.js + AdminAPI 优先 | v0.3 |
| 32 | **2 个 Phoenix Socket**(`/socket` + `/mcp`),不是 5 个 | v0.3 |
| 33 | **Standard Behavior library** 作为独立 plugin 集合(`esr_behavior_*`) | v0.3 |
| 34 | **Bundle 概念砍**,`mix release` profile + seeds 即可 | v0.3 |
| 35 | **DLQ 单立类 E**,不混入 audit log | v0.3 |
| 36 | **三种 transport 都是 v0 first-class**(WS via `/socket`、stdio via OSProcess、MCP via `/mcp`)— 外部生态决定调用方式,不是选型 | v0.3 |
| 37 | **RoutingRegistry: core 不预定义任何 table**,全部由 plugin 自声明 | v0.3 |
| 38 | **LiveView 重新启用**作早期内部 IM dogfood 前端(`ezagent_web_liveview` plugin);不再延后。Next.js 留作 admin dashboard 的另一选项 | v0.3 |
| 39 | **`%Message{}` 是 `%Invocation{}` 的特化 args shape**(只在 Entity↔Entity 链路上使用),不是平行新概念 | v0.3 |
| 40 | **Message identity invariant**:Message 跨任意层中转其 sender/ref/body/mentions/inserted_at 不变,中转者只创建新 Invocation 携带它 | v0.3 |
| 41 | **Routing rules = additive rules**(`(matcher, receivers)` 独立可加,union)+ **Matcher DSL**(编译期产数据 AST,类似 Ecto.Query) | v0.3 |
| 42 | **View 是 Adapter 的对称面**——通用 Invocation 渲染器(不只 Message),`@interface.render_hint` 是可选提示 | v0.3 |
| 43 | **Behavior 名字精简**:`ChatRoom` → `Chat`,`ExternalProcess` → `OSProcess`,`PtySession` → `Pty` | v0.3 |
| 44 | **LOC budget 显式化**:ezagent_core target ~580 LOC,每模块 hard ceiling,任何模块超 cap 触发设计 review | v0.3 |
| 45 | **持久化 F (Message stream) + G (File attachments) 全部 Phoenix 生态原生**:Ecto + SQLite BLOB / S3 via `req_s3`;无新外部依赖 | v0.3 |
| 46 | **SQLite 是唯一数据库**(不双轨),Postgres 不出现在 v0 spec | v0.3 |
| 47 | **`:oban` 移除**:snapshot 定时 / DLQ evict / drain timer 改用 `Process.send_after/3`(~15 LOC `Ezagent.Scheduler`);BEAM 原生足够 | v0.3 |
| 48 | **Federation 形态 A 确认**(独立节点 + cross-node 协议),v0 不实现,但 share-nothing 持久化 / URI 寻址 / Push CapBAC 已为它留好接口 | v0.3 |
| 49 | **LiveView IM dogfood + CLI 写入 spec**(Appendix D),作为 reference 实现,让 spec 读者直观感受系统怎么用 | v0.3 |
| 50 | **Ezagent 不内置通用 MCP server**——内嵌 BEAM agent 直接调 Elixir API,Python adapter 走 WS;唯一 MCP 集成是 CC Channel | v0.3 |
| 51 | **CC Channel = Ezagent ↔ CC 桥** — 反向 MCP push 模型(不是 LLM pull tools);双向:CC reply 回 Ezagent routing | v0.3 |
| 52 | **`ezagent_plugin_cc` 单 plugin 含两侧组件**(Elixir adapter + Python channel server)统一发布 | v0.3 |
| 53 | **CC Channel 实现语言:Python 优先**(复用现有 esr 的 Python channel 实现),Bun 备选 | v0.3 |
| 54 | **Adapter driver 关系两种**:Ezagent-driven(Feishu/Slack,OSProcess 拉起)与 external-driven(CC Channel,CC 用 `--channels` 拉起) | v0.3 |
| 55 | **单层鉴权模型**:WS connect 验 token(身份)+ Invocation flow 验 cap(权限);Channels 协议的 sender allowlist / pairing 不使用 | v0.3 |
| 56 | **`ezagent_plugin_cc` vs `ezagent_plugin_cc` 独立 plugin**:本地 pty 拉起 vs 外部 channel 桥接,两者并存可同装 | v0.3 |
| 57 | **LiveView IM 不限于 dogfood**:v0 期内部 IM 验证 spec,v0 之后作为产品 web 入口持续存在,跟 Feishu/Slack/CC channel 并列 | v0.3 |
| 58 | **LiveView ↔ CLI 同构映射**:两侧 UI 都从 `@interface` 自动派生;`/agent:set-default A` ↔ `esr agent set-default A` 等价;新 Behavior 自动出现在两侧 | v0.3 |
| 59 | **`:on_change` 触发时机:slice 真变了才写**(`new_slice != old_slice`),不是 invoke 后都写。BEAM 不可变 + 值比较自然给出正确语义,用户无需管 dirty 标记 | v0.3 |
| 60 | **Audit log 异步写入**:`:telemetry` handler 只 `GenServer.cast` 到 `Ezagent.Audit.Writer`(微秒);Writer 内部 batch + 100ms flush;不阻塞 invoke,不用 Oban | v0.3 |
| 61 | **顶层 framing — Ezagent 是 router 不是 req/resp app**:失败默认静默,必须人工造可观测性;统一了 4 个 P1/P2 设计动作的共同根 | v0.4 |
| 62 | **顶层 framing — 持久化层存了代码引用**:用稳定 `type_name` 间接层而非模块名字符串;消除 rename → snapshot orphan 类 bug | v0.4 |
| 63 | **Plugin 判定原则:读什么数据,归哪里**——读 core 数据(`%Message{}` 等)→ core;读 plugin 专属 payload → plugin。比"业务/基础设施"二分更准 | v0.4 |
| 64 | **Resource Kind 薄形态明确化 + "shared referent needs identity" 原则**:被多方按身份引用的概念必须独立可寻址,不能展开成 tuple;Workspace 是代表性应用 | v0.4 |
| 65 | **RoutingRegistry 加 `put_new` 语义**:unique-key 表必须用 `put_new`(撞 key reject 不静默 shadow);duplicate-key 表(如 `SessionRules`)用 `put`(append 语义) | v0.4 |
| 66 | **三件 Reliability primitives 全部在 core**:`Ezagent.ReadyGate` / `Ezagent.PendingDelivery` / `Ezagent.Idempotency`,`use Ezagent.Kind` 宏自动接入,plugin 作者无法绕过 | v0.4 |
| 67 | **`Ezagent.deliver/2` 合进 `Ezagent.Invocation.dispatch/1`**:plugin 作者只学一个 API;`:cast` to not-ready 可 buffer,`:call` to not-ready 必须 fail-fast(caller 同步阻塞会撞 deadline_ms) | v0.4 |
| 68 | **零匹配路由 → telemetry + DLQ unroutable**:消息到达零个 receiver 是 Ezagent chat 系统的 bug,不能静默返回 [];必须显式可观测 | v0.4 |
| 69 | **双层 Template 模型**:Template Class(模块级,开发者写)+ Template Instance(运行时 Resource Kind,用户创建);Workspace 是 Instance 的代表性示例;`validate/1` 是契约 | v0.4 |
| 70 | **Workspace 保留为薄 Resource Kind**:不绑定到 Session/Entity,平行三个 Kind 子类;5 类引用者(cap/session bindings/user.default/repo registry/plugin config)证明它必须独立存在 | v0.4 |
| 71 | **Matcher 边界按"读 core 数据"画线**:组合子 + Message-field matcher 全部在 core(~85 LOC);未来 plugin-payload matcher(`feishu_card_type` 等)在 plugin。防止 audit/workflow plugin 依赖 chat plugin | v0.4 |
| 72 | **LOC 预算校准 595 → ~870**:dev review 实测论证扎实;invocation/matcher/kind 三个核心模块上调;新增 4 个模块(interface_validator/idempotency/ready_gate/pending_delivery);red line 提到 1100 | v0.4 |
| 73 | **feishu-cc 切片 3 张参考表入 spec**(§10.7):ChatRouting / PrincipalMapping(unique, put_new)+ SessionRules(duplicate, put);其他 plugin 按同模式扩展 | v0.4 |
| 74 | **Routing 迁移分诊规则**(§17.11):不一次性迁 1722 行;旧架构偶然复杂度蒸发(slash route 493 → ~30),真实业务逻辑重新表达;feishu-cc 切片优先 | v0.4 |
| 75 | **inbound 永远走 dispatch,绝不裸 `PubSub.broadcast`** — 升级为 §5.7.6 硬不变式;Phoenix.PubSub 不 buffer 没订阅者的 topic,裸 broadcast 在 register→subscribe 窗口会丢消息(事故 2.1 根因) | v0.4 |
| 76 | **Idempotency v0 语义:收到即记,不是成功才记**(§5.7.3)— 失败路径走 DLQ 兜底;事务化"成功才记"超出 v0 复杂度预算;真需要重试到成功用专门 retry policy | v0.4 |
| 77 | **Event Sourcing 不做** — 从 §17.2 deferred 改成已决不做;append-only Message stream 已具备 ES 真实好处,不需要承担 ES 复杂度 | v0.4 |
| 78 | **`SessionBindings` 作为 v0.4 第 4 张参考表**(§10.7,duplicate-key);RoutingRegistry 加 `reverse_index` 可选参数支持反查(workspace→session 正向 + session→workspace 反向) | v0.4 |
| 79 | **LOC cap 总和 > red line 是预期**:cap 是单模块异常天花板,red line 是实测合计触发器,两个独立信号(防止读者看到"自相矛盾") | v0.4 |
| 80 | **sub-step 是 /goal 内部 e2e gate,phase 才是 Allen review 单元**:行为正确性自动化(sub-step 完成跑对应 e2e flow + 单元/集成测试,绿才 tag)+ 架构判断人工(整 phase 完才 review)拆开;VERIFICATION.md 在 brainstorm 阶段先于 PLAN.md 写,作为 sub-step 之间契约 | v0.4 |
| 81 | **`user://admin` 是 bootstrap 默认 principal**,持 all-caps 不可 revoke(结构性 invariant 在 `Ezagent.Capability.revoke/2` 集中检查 — 见 §7.6);Phase 1-3c LiveView/CLI 默认 `ctx.caller = user://admin`,Phase 3d cap 真实化后仍持 all-caps;`Ezagent.Bootstrap` 首次启动检查 `users` 表空时创建 | v0.4 |
| 82 | **authz stub 带 `:stub_grant` telemetry 防代码层"顺手简化"**:Phase 1 dispatch step 5.5 authz_check/2 是显式 permissive stub(永远 grant + emit `:stub_grant`),带 `PHASE-3D-STUB: DO NOT REMOVE` 注释;Phase 3d in-place 替换为真实 cap 检查 + `:granted`/`:denied` telemetry;stub 阶段也可观测,gate 在路径里不变式不破 | v0.4 |
| 83 | **§14 LOC budget round-2 校准**:`message_store.ex` 之前漏在 §14 模块清单外,工程师 round-2 review 发现;补进清单(~50 LOC,cap 70),target 870 → 920,red line 1100 → 1150 | v0.4 |
| 84 | **Phase 1 采用路径 B(`@behaviour Ezagent.Kind` + 共享 `Ezagent.Kind.Server`)** 不用宏 — register→subscribe→announce_ready property 等价 Decision #66 但 means 不同;共享 Server 把 Kind 隔离从 compile time 推到 runtime,`Ezagent.Kind.Runtime.handle_dispatch/3` 必须 defensive 处理多 Kind state shape;Phase 1 接受 trade-off 因为只有 Echo 一个业务 Kind;Phase 2+ 若 state shape 假设冲突再评估切回路径 A 或两条并存(详见 §5.7.4) | impl |
| 85 | **`.claude/` 暂用 plain dir 不 vendor+submodule**(Phase 0 实施期决策)— 短期符合"少发明多装配"+ 镜像老 esr 实际结构;trigger 迁 vendor: (a) 出现 skill 需要 upstream 更新需求,或 (b) Phase 5 完成后整理 tech debt | impl |
| 86 | **CC channel 协议层简化:Channel = MCP server + 1 capability**(Phase 1b 实证)— v0.3 §12.8 之前假设 channel 是独立通信协议(独立 server 进程 + 类似 WebSocket 的 wire),Phase 1b 发现 Channels 是 MCP 协议扩展:`capabilities.experimental['claude/channel']` + `notifications/claude/channel` notification + 标准 MCP tools/call(`reply`)。Phase 1b `ezagent_plugin_cc_bridge_v1_prototype` minimum bidirectional ~250 LOC Python。**关于 LOC 对比的诚实表述**:老 esr `cc_channel_runner`(973 LOC)和 cc-openclaw `channel_server`(4164 LOC)的代码量**不是纯 channel 协议层**——包含多 session 管理 / persistence / permission relay / production-grade 错误处理 等非 channel 功能,直接拿 4164 vs 250 对比是**不公平的**;**协议层简化是真的**(纠正过度工程认知),但 LOC 比较的简化幅度取决于 prior art 还做了什么 channel 之外的事。Phase 5 `ezagent_plugin_cc` 走这条简化路径(v1_prototype wholesale replace 的 target),详见 §12.8 | impl |
| 87 | **`--dangerously-load-development-channels server:<name>` 需要项目根 `.mcp.json`**(per-operator,gitignored,通过 `git rev-parse --show-toplevel` 锚定)— 否则 claude 启动期 lookup 失败打印 warning;`--mcp-config <abs>` 只读 session-level,**不**满足 dev-channels lookup。`Ezagent.Bridge.V1Prototype.McpConfigWriter.write!/0` 同时写 session-level 和 project-level | impl |
| 88 | **K-path Behavior 模型**(Phase 2 落地 Decision #61)— 一个 Behavior 模块同时挂在多个 Kind 上,每个 Kind 通过 `BehaviorRegistry.register(kind, action, behavior)` 注册自己消费的 **action subset**(Chat: Session→send/join/leave, User+Agent→receive)。`Kind.behaviors/0` 从"action 路由权威"降级为"`init_slice` 用的列表",真正权威是 BehaviorRegistry per-Kind 表。User Kind 可以 `behaviors() = []` 但仍接收 `:receive` 分发。plugin isolation 北极星的核心原语 | impl |
| 89 | **`Ezagent.Kind.Server.handle_info/2` 统一 Behavior 消息转发器**(§5.7.4 新合约面)— 任何非 dispatch 入站(Process.monitor `:DOWN` / bridge `send/2` 回调 / 未来 timer tick)进 Kind.Server 单 mailbox,转发到每个 composing Behavior 的可选回调 `handle_kind_message(message, slice, ctx)`,返 `{:ok, new_slice}` 或 `:ignore`。Kind.Server 仍不感知任何业务 Behavior。Phase 2 Chat 用此 hook 实现 offline 状态机 + bridge→Agent reply 回路 | impl |
| 90 | **`ctx.kind_module` + `ctx.self_uri` 在 Kind.Runtime 注入**(§4 Invocation flow 增补)— 跨 Kind 的 Behavior(Chat 的 :receive 要分支 User vs Agent / Session 的 :send 要 broadcast topic 含自己 URI)需要这两个值,Phase 1 没有。Kind.Runtime.handle_dispatch/4 在 invoke 前单点 `Map.put` 注入,plugin 永远不手 plumb。`Invocation.ctx` type spec:这两 key runtime-injected,Behavior 内可见,adapter 构造时不填 | impl |
| 91 | **MessageStore 为聊天历史的单一真相源**(Phase 2 P2-D3)— Session.Chat slice 只持 ephemeral 在线状态(members/monitors/last_seen),offline 期消息不维护 pending queue;rejoin 通过 `MessageStore.in_session_since(session_uri, last_seen[uri])` 派生 replay 集,SQL `LIMIT 1000` 兜底。可派生的不独立维护 — 同 memory `feedback_converge_to_uri_list` | impl |
| 92 | **`InterfaceValidator` 加 `:uri` primitive**(§6.2 type-spec 语法扩展)— Chat 的 `@interface` schema 声明 `sender: :uri, mentions: {:list, :uri}` 等典型 URI 字段,validator 在 dispatch 边界要求 `%URI{}` struct,**拒绝裸字符串**。配 `Ezagent.Ecto.URI` 自定义 Ecto type 实现 URI 跨进程/跨持久化层都是 struct | impl |
| 93 | **`session://` URI scheme + 两条新 PubSub `:events` 通道**(§3.5 URI types + §5.7.6 topic taxonomy 扩展)— Phase 2 新增 `session://` 作为 Kind URI scheme(Session Kind 用)。`esr:session:<uri>:events` 用于 chat stream 订阅(消息/成员变更/online-offline)+ `esr:user:<uri>:events` 用于个人 inbox 通知。两个 topic 都是 §5.7.6 的 view fan-out 合法用法(已加入 `check_invariants` #1 allowlist) | impl |
| 94 | **Bridge↔Agent dual map**(v1_prototype 实现层模式,Phase 5 channel 重写时复用)— `Ezagent.Bridge.V1Prototype.Server` 同时维护 `bridge_to_agent: %{bridge_id => pid}` + `agent_to_bridge: %{agent_uri_str => bridge_id}`。出站(Agent.invoke(:receive) → claude)用 `bridge_for_agent/1`;入站(claude reply → Agent)用 `forward_reply_to_agent/2` 找 pid → `send/2`。模式本质:wire-id 和 business-URI 解耦,routing 层不感知 wire 协议 | impl |
| 95 | **RoutingRegistry 作第 3 个 Registry 家族 + owner-pid check**(Phase 3a 落地 Decision #28/#37/#65)— `Ezagent.RoutingRegistry` 跟 `KindRegistry` / `BehaviorRegistry` 并列;独有 owner-pid check(declare_table 时记 owner,只该 pid 能写)— admin 是运行时写 routing rules,不像 BehaviorRegistry 是 boot-only。Plugin X 不能 stomp plugin Y 的 routing table | impl |
| 96 | **Matcher AST 5 leaf + JSON serde**(Decision #41/#42/#70 落地)— `Ezagent.Routing.Matcher` 5 个 leaf(`mention/from/text_contains/text_matches/always`);plain tuple 形态无 macro;`to_json/1` + `from_json/1` 让 matcher 进 SQLite `routing_rules.matcher_data` 列。组合子(and/or/not)Phase 4+(P3-D3 决定单层规则 + 多条规则 additive 已覆盖 demo)| impl |
| 97 | **Resolver 双层 fan-out:cross-session 走规则 + in-session 走 members fall-through**(P3-D impl 决策 b)— `Chat.invoke(:send)` 先调 `Resolver.resolve/2` 拿 cross-session targets,再 always 加上 in-session members。Recursion guard:不 re-dispatch 到 current session。router 真正能"在 main 发的 urgent 消息同时落 oncall" | impl |
| 98 | **`message_routings` 关联表保 Decision #40 identity invariant + 多 session 持久化**(#P1-4 spec review 修复)— `messages.uri` 是 PK,Phase 3 D8 reply 可同时 target N session → PK 冲突。新 `message_routings` 复合 PK `(message_uri, session_uri)`:messages 保 1 行/uri,per-session 路由信息走 routings 表。MessageStore.write/2 transaction upsert messages + insert message_routings + 新加 sessions_for_message/1 给 ref 一致性 soft warn 用 | impl |
| 99 | **Identity Behavior in slice + admin_caps 注入 init_slice**(Phase 3d step 1 / Decision #24 落地)— admin_caps 从 module function 硬编码迁到 slice state;`Ezagent.ActionSet.Identity` 加 User Kind.behaviors;chat plugin spawn admin User 传 `extra_args: %{initial_caps: User.admin_caps()}`(per #B1 — kind_server_spec/4 加 extra_args 参数)。caps 现在在 `:sys.get_state(admin_user_pid).state.identity.caps` 可观测 | impl |
| 100 | **`Ezagent.Capability.cap_for_action/3` helper**(#P1-8)— dispatch step 5.5 需要的"action → cap_needed" 反查,签名加 `target_uri`(必填)以从中提取 `instance`(via Ezagent.URI.instance/1)。返 `%{kind, behavior, instance}` 喂 matches?/2 | impl |
| 101 | **Phase 3d hard flip:`:stub_grant` 永久死亡 + check_invariants #9 #10 invariant test gate**(P3-D6 落地)— authz_stub/4 整个删除,替换 authz_check/4(真 Capability.matches? + `:granted`/`:denied` telemetry)。`:stub_grant` atom 全 codebase 清空(audit.ex/telemetry.ex/admin_live.ex 全改 granted/denied)。runtime invariant test 是 #10 的语义 gate(grep 只是 tripwire,per `feedback_completion_requires_invariant_test`)| impl |
| 102 | **Reply 契约 D8:`{session_uris: [URI], text, ref?}`** — Python bridge `reply` MCP tool 三字段;session_uris 是 list;ref optional 支持 proactive reply。Agent.handle_kind_message 用同一 envelope dispatch chat/send per session_uri(identity invariant 配合 #98)。ref + session_uris 不一致 emit `[:ezagent, :chat, :reply_session_mismatch]` 但仍按 session_uris 路由(soft warn,信任 claude)| impl |
| 103 | **Bridge↔Agent floating (P3-D9 contract change) + LV @-dropdown 只列 session 成员**(real-claude e2e exposed)— bridge announce 改为 spawn Agent Kind 但不 join 任何 session(floating),admin 通过 LV "Add to session..." 显式拉入。配合 LV compose 区 @ agent dropdown 只列 current_session_uri 的 members,空时显 hint。multi-agent demo 暴露的 UX 问题(@ floating agent 后 message 静默 drop)的根本修复 | impl |
| 104 | **push_to_claude meta 必含 `"session"` 字段 + reply dispatch failure 可见**(real-claude e2e hotfix)— Chat.invoke(:receive) Agent 分支构造 push_to_claude meta 时必须包含 `"session" => URI.to_string(ctx.caller)`(源 session URI),claude 才能正确填 reply 的 session_uris。配 Chat.handle_kind_message dispatch chat/send 返 `{:error, _}` 时 emit `[:ezagent, :chat, :reply_dispatch_failed]` telemetry(以前静默 drop) | impl |
| 105 | **admin_live Phase 4a 用 Phoenix.Component 拆分(stateless)而非 LiveComponent**(Phase 4 D2 文档化 vs 实际落地差异)— D2 原话推 LiveComponent,但 admin_live 状态紧耦合(session 选择驱动 chat + members + sidebar),LiveComponent 的 `send_update` 跨组件协调比直接 parent assign 多绕一层。Phoenix.Component 拿到 file-boundary split(主目标 — 4b/c/d 新增 surface 进新文件不进 admin_live),不付协调成本。promote 到 LiveComponent 推迟到具体 surface 真需要 own state(4d Workspace member-picker 候选,但 4d 也仍单文件 LV)。详见 `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex` 文件顶部 moduledoc | impl |
| 106 | **Workspace Kind + Behavior lives in ezagent_core**(Phase 4b)— Workspace 是 cross-plugin 基础(plugin 用 Workspace 声明自己的 Kind 模板),放 plugin 会循环依赖。`Ezagent.Entity.Workspace` 平 `Ezagent.Entity.User`;`EzagentCore.Application.start` 注册 Workspace Behavior 的 9 个 action(第一次 EzagentCore 注册 Behavior,但 Workspace 是 cross-plugin 基础概念,例外合理)。`Ezagent.Workspace.Supervisor` DynamicSupervisor 也在 EzagentCore.Application children 第 ⑦ 项 | impl |
| 107 | **`Ezagent.ActionSet.Workspace.invoke(:instantiate)` 返回 children 数据不做 side-effects**(Phase 4 D5)— plugin isolation 在 boundary:ezagent_core 不知道哪个 plugin 拥有哪个 Kind 的 supervisor。`:instantiate` 返 `{:ok, slice, %{children: [{:member, URI}]}}` 纯数据;Loader walk + call `SpawnRegistry.spawn/1`。Decision #70 Workspace 薄 Resource 形态的运行时落地 — "薄"= 行为 declarative + actual effect 由调用者注入(DI at boundary) | impl |
| 108 | **`Ezagent.SpawnRegistry`:URI scheme → spawn fn 的 ETS 表(plugin DI 原语)**(Phase 4c)— plugin Application 在 `start/2` 调 `Ezagent.SpawnRegistry.register("agent", fn uri -> ... end)`。chat plugin 注册 `agent`/`session`/`user` 三个 scheme。Loader 看 `agent://cc-builder` 时 lookup scheme → call 注册的 fn,ezagent_core 永远不引用 `EsrPluginChat.AgentSupervisor`。`spawn/1` 先 `KindRegistry.lookup`(idempotent re-spawn safe)再 fall back ETS。`{:already_started, pid}` 透明 unwrap 为 `{:ok, pid}`。`EtsOwner` 拥有该表(与 ReadyGate/Idempotency 等并列第 ⑥ 张表)| impl |
| 109 | **Workspace 持久化分层:config 持久化(Store)≠ Kind state snapshot**(Phase 4 D7)— Workspace Kind `persistence/0` 仍 `:ephemeral`;config(members/templates/routing_rules)经 `Ezagent.Workspace.Store` 写 SQLite `workspaces` 表(JSON-text 列,SQLite 无 native JSON column);Loader 从 DB rehydrate live Kind 时把 config 灌进 init_slice。per-Kind state snapshot(运行时 slice 状态)是 Phase 5+ SnapshotStrategy framework 的事,推后。混淆这两个会让 restart 慢且脆 | impl |
| 110 | **Workspace facade dual-write 模式**(Phase 4c)— `Ezagent.Workspace.add_member/2` 等 mutation 先 `Store.update_members`(durable DB)再 `dispatch(:add_member)`(live Kind)。两步非事务:crash 后 Loader 在下次 boot 用 DB 状态重建 live Kind — **Loader 是 resync 真相**。read 走 live Kind only(`list_members` 等),DB 是 recovery snapshot,不是 read source。Phase 5 可能 wrap transactional path 但 v0 接受简单实现(失败恢复路径有 Loader 兜底) | impl |
| 111 | **Phase 4 plugin-isolation invariant test(D10 完成 gate)**— `apps/ezagent_core/test/integration/plugin_isolation_workspace_test.exs` 内联 `ProbeKind` + `ProbeBehavior`(**NOT in lib/**),运行时 `SpawnRegistry.register("probe", ...)`,持久化 Workspace declares `probe://invariant-N` member,`DynamicSupervisor.terminate_child` 模拟 restart(不是 `Process.exit` — `:one_for_one` 会立刻 re-spawn,模拟错),`Loader.load_all/0` re-spawn probe,断言 new pid alive。Per memory `feedback_completion_requires_invariant_test`:Phase 4 不可单凭 tests-pass + merge 宣完成 — 这是架构 gate。若该测试 break = plugin isolation broken,investigate before ship | impl |
| 112 | **Plugin Application 启动尾巴 call `Loader.load_all/0`**(Phase 4c boot 顺序约定)— Loader 必须 AFTER plugin 已注册 schemes 才能跑。`EsrPluginChat.Application.start` 在自身 bootstrap(register_chat_behaviors + admin User join + DefaultRules)完成、register_spawn_fns 注册 3 个 scheme 后,在 start callback 尾巴 call `Ezagent.Workspace.Loader.load_all/0`。当前依赖 Application 启动顺序(chat plugin 是最后启动的 plugin)。Phase 5 可能改为显式"all-plugins-ready" gate 或 release-time bootstrap script | impl |
| 113 | **`PHASE4-SPLIT-FIRST` marker 注释 + 兑现机制**(Phase 4 工程流程)— PR #8 在 `admin_live.ex` 顶部加 13-line 注释 block 声明"Phase 4 必须先拆分再加新功能";Phase 4a(PR #9)真拆;Phase 4d(PR #12)Workspace UI 不塞 admin_live 而是独立 `/admin/workspaces` route 验证 marker 起作用。模式:**pre-commit marker → 后续 PR 兑现 → closeout 验证**。可推广到其他"将要溢出"的模块(LOC red line 触发器之外的早期预警机制) | impl |
| 114 | **Template Class behaviour + TemplateRegistry**(Phase 4-completion PR 1 落地 Decision #64 双层模型 Class 半)— `Ezagent.Kind.Template` behaviour 3 callbacks(`template_name/0` + `validate/1` opt + `instantiate/3` MUST be idempotent);`Ezagent.TemplateRegistry` ETS scheme→Class registry,strict on duplicate(同名 Class 第二次 register error);plugin Application 在 start 调 `register/1`。`Ezagent.Workspace.add_template/3` fail-fast 通过 Class.validate;Workspace `:instantiate` 返 `{:template, ...}` children,Loader 调 SpawnRegistry(member)或 TemplateRegistry+Class.instantiate(template)。`Ezagent.Template.GenericSession` 是首个 concrete Class(chat plugin owns Session) | impl |
| 115 | **Snapshot per-Kind 真 r/w + 5 strategies finalized**(Phase 4-completion PR 2 替换 Phase 1 stub)— `Ezagent.Kind.Snapshot` 真 SQLite r/w via `:erlang.term_to_binary`(JSON 不行 — MapSet/URI/DateTime 丢失),`:safe` decode 拒未知 atom。5 策略全 live(`:ephemeral` / `{:snapshot, :on_change}` 同步 / `{:snapshot, :periodic, ms}` 异步 via `Ezagent.Snapshot.Writer` / `:on_terminate` GenServer.terminate hook / `:external` 跳过)。Q3 default:write 失败 log+telemetry+continue(不 crash Kind,let_it_crash 不适用 disk-full)。Q5 default:added Behavior 时 `Map.merge(fresh, loaded)` 让新 slice 取 fresh init。`Ezagent.Audit.@events` 加 `[:ezagent, :persistence, :restored / :written / :failed]`。`Ezagent.Entity.Agent` flip `:ephemeral → :on_terminate`(granted Identity caps 跨 graceful shutdown 保) | impl |
| 116 | **CLI 自动派生 via Optimus + FacadeRegistry**(Phase 4-completion PR 3 落地 Decision #58 LV↔CLI 同构)— 新 app `apps/ezagent_cli/`(Optimus 依赖隔离在 ezagent_cli,ezagent_core 不污染)。`EzagentCli.TreeBuilder` 启动时 walk `BehaviorRegistry.list_all/0` + `EzagentCli.FacadeRegistry` 构造 Optimus 子命令树;`EzagentCli.Coercion` 把 interface 类型(:string/:uri/:map/:atom/{:list, T}/{:option, T})map 到 Optimus parser;`EzagentCli.Dispatch` 把 parsed → `%Invocation{}` → reply receive;`EzagentCli.Formatter` 出 stdout + exit code(0/1/2/3/4)。**FacadeRegistry** 是 BehaviorRegistry 的对称 peer(Spec 02 Q-A option c)— plugin 注册非-action 操作(`workspace create` 创建 Kind,不是已有 Kind 的 action),`mix esr <kind> <op>` 跟 action 一样自动出现。**北极星 invariant**:fake `ProbeKind` 在 test/ 里(NOT lib/),BehaviorRegistry.register 后 `mix esr probecli do_thing --probecli X --x Y` 自动 work — **无对应 Mix.Tasks.* 模块** | impl |
| 117 | **Multi-user provisioning + login flow**(Phase 4-completion PR 4-5 落地 Spec 05 Part A)— `Ezagent.Users` 独立 SQLite 表(`uri / password_hash bcrypt / caps_json / enabled` etc),独立于 User Kind snapshot(Q-MU-2:provisioning config vs runtime state);`Ezagent.Capability.Parser` 字符串→ caps 文法(`kind.behavior@instance` + `*` admin-eq + comma-separated);`mix ezagent.user.create` + `ezagent.user.set_password` task;`EzagentWeb.SessionController` controller-rendered(NOT LV)`/login` form(避免 WS 依赖 in 认证边界);`EzagentWeb.Plugs.RequireUser` gate `/admin/*`;`Ezagent.Identity.list_caps_for/1` facade(self-grant Identity cap 解 chicken-egg)。`AdminLive.mount` 从 session cookie 读 caller URI + caps,`ctx/0 → ctx(socket)`;`chat_compose` 用 session caller 作 Message.sender。`:unauthorized` LV flash 友好化("You don't have permission for this action") | impl |
| 118 | **Matcher 组合子 and/or/not**(Phase 4-completion PR 6 落地 Decision #41 推迟项)— `Ezagent.Routing.Matcher` 加 3 个 AST tuple 节点 + 构造器(`all_of/1` `any_of/1` `negate/1`)+ Evaluator 递归(`Enum.all?` / `Enum.any?` / `not`)+ JSON serde 递归。`import Kernel, except: [match?: 2]` 解 Elixir 1.18+ shadowing warning。空 and = vacuously true,空 or = vacuously false。Backward compat:leaf-only DB 行不变。`negate` 命名避免 `Kernel.not/1` 碰撞 | impl |
| 119 | **CC PTY plugin(简化版,wrap shell script via PTY)**(Phase 4-completion PR 8/8a/8b/8c 北极星 end-to-end 验证)— **第一个非-chat plugin** 验证 plugin isolation 真 work。`apps/ezagent_plugin_cc/`:`PtyServer` GenServer 用 erlexec `:pty` + `:monitor` 包 `bash scripts/cc-bridge-attach.sh`,`Ezagent.PluginCc.Template` 实现 Spec 01 Template Class(class_name `"cc.pty"`),Application 注册到 TemplateRegistry;`Ezagent.AnsiStrip` 从老 esr 移植。**3 个关键 fix**:(a) `:stdin` 选项 — 否则 child stdin EOF,`read` 失败;(b) auto-confirm `--dangerously-load-development-channels` dialog — detect "Loading development channels" + "I am using this for local development" 在 ANSI-stripped 缓冲里,`:exec.send(pid, "1\r")`;(c) `:exec.winsz(os_pid, 40, 120)` — claude TUI 阻塞等 TIOCGWINSZ 直到收到 non-zero size(老 esr PR-24 同问题);(d) cc_pty Application.start 尾巴 re-run `Ezagent.Workspace.Loader.load_all/0` — chat plugin 早跑 Loader 时 cc.pty Class 未注册,需要 cc_pty 自己重跑(boot-ordering pattern,documented for cross-plugin 用) | impl |
| 120 | **Routing consolidation(4 leaks fixed + CI invariant)**(Phase 4-completion PR 9 落地 Allen 2026-05-16 "通信 routing 散落代码各处" 反馈)— (a) Resolver 加 `$session_members` magic 受体 token + `members` 第三参,DefaultRules.bootstrap seed `always() → ["$session_members"]` system_default 规则,**Chat.invoke(:send) 移除硬编码 fan-out — Resolver 是 SOLE 路由决策源**。LV `/admin/routing` 渲染 magic token 为 "(dynamic: members of current session)"。(c) migration 加 `source`("system_default" / "admin")+ `enabled` 列,`RuleStore.delete/1` 拒绝 system_default(`:cannot_delete_system_default`),`disable/1` 是 admin opt-out 路径,`bootstrap` 检查 `has_system_default?` 不再 "table empty"(admin 删除后重启不被覆盖)。(d) boot-ordering pattern documented(每 plugin Application.start tail re-run idempotent bootstrap;PR 8c 为模式先例)。(b) per-rule cap-check 显式推 Phase 5(synthetic RoutingAdmin Kind 是更大题)。**CI 防回归 invariant**:`routing_consolidation_invariant_test.exs` 7 tests,其中 "no rules + no members → no recipients" 是**结构 gate**:任何未来 reintroduce hidden fan-out 立即 fail | impl |
| 121 | **LV `ScrollOnUpdate` JS hook + chat message auto-scroll**(Phase 4-completion PR 9 §UI)— Phoenix.LiveView.stream 默认不 auto-scroll;新增 `ScrollOnUpdate` hook(`apps/ezagent_web/assets/js/app.js`)在 stream update 后**仅当用户当前在底部 120px 内**才 scroll-to-bottom(读历史时不被打断)。`admin/chat_window.ex` 的 `#messages` div 加 `phx-hook="ScrollOnUpdate"`。模式可推广到任何 stream-based feed surface | impl |
| 122 | **Phase 5 PR 1: Workspace LV 加 add-template 表单(hybrid form/JSON)**(2026-05-16)— `/admin/workspaces/<name>` 加 form mode(4 标准字段:class_name + agent_uri + system_prompt + greeting)+ JSON mode(完整 attrs map paste);submit 既写 Workspace.config.templates 又同步 fire `Class.instantiate` spawn Session。**operator 不再需要 mix ezagent.workspace.add_template** | impl |
| 123 | **Phase 5 PR 2: /admin/users LV(list / create / set-password)**(2026-05-16 P5-D2/D3)— UI 完整 CRUD;cap-edit 用 text input(`Capability.Parser` 解析 comma-separated)而不是 per-cap form;refuse `*` caps via UI(必须 mix --allow-allcaps);create 后 live-spawn User Kind via `SpawnRegistry.spawn/1` | impl |
| 124 | **Phase 5 PR 3: /admin/snapshots LV + mix ezagent.snapshot.{list,dump,clear}**(2026-05-16 P5-D4/D5)— read-only LV(table + Dump JSON modal + Clear button per-row),3 mix tools 是 LV 之外的脚本入口。`KindSnapshot.list_all/0` 按 updated_at desc 列所有 snapshot rows | impl |
| 125 | **Phase 5 PR 4: 每-rule cap-check via synthetic `Ezagent.Entity.RoutingAdmin` Kind**(2026-05-16 落地 Decision #120(b) defer 项 + P5-D6)— `routing-admin://default` 单例(persistence `:ephemeral`),`Ezagent.ActionSet.RoutingAdmin` 4 actions(add/delete/disable/enable);RoutingLive 不再直接 call `RuleStore`,改 `Invocation.dispatch` 走 CapBAC step 5.5;non-admin without `routing_admin` cap → `:unauthorized` + audit row。Behavior interface 用 `matcher_json: :map`(tuple 会被 InterfaceValidator 拒)— caller 预先 `Matcher.to_json/1`,Behavior 内部 `Matcher.from_json/1`(模式适用任何需要传 AST 跨 interface 边界的场景) | impl |
| 126 | **Phase 5 PR 5: MessageStore 反向分页 + LV "↑ Load older" 按钮**(2026-05-16 P5-D7/D8)— `MessageStore.older_than(session_uri, cursor, limit)` 用 `inserted_at` cursor(P5-D8:`id` 不保证 multi-node 单调,timestamp 是 canonical order);AdminLive `:oldest_cursor` 跟踪 currently-oldest 行,`load_older_messages` handler `stream_insert(at: 0)` prepend(并丢弃 `:messages` stream 的 `limit:` 否则 prepend 立即被 evict)。**`ScrollOnUpdate` hook 升级**:加 `beforeUpdate` capture first-child id;`updated` 比较——first-child 变化即 prepend → `scrollTop = grew` 让 newly-prepended 内容可见(否则 hook 把用户保持在底部就看不到新加载的旧 message)。**Spec gate test**:发 100 message → mount 看 51-100 → click reveals 1-50 + no duplicates → 再 click no-op | impl |
| 127 | **Receiver Kind contract for external integrations**(post-Phase-5 Plan B,2026-05-17,落地 Allen "feishu 实现 drift 了一条 work 但不是 arch-align 的路径" 反馈)— 任何 plugin 想把消息送出 Ezagent（HTTP/file/external），**必须**把外部目的地建模成 `<scheme>://<external_id>` Receiver Kind，实现 `Ezagent.ActionSet.Chat`(或等价 Behavior) 的 `:receive` action，通过 routing_rules 接收。**禁止** PubSub.subscribe + 直接外部写。理由:绕开 dispatch 等于绕开 CapBAC + audit + idempotency。**Drift defenses**:Layer 1 doc `docs/notes/plugin-receiver-kind-contract.md` + Layer 2 CI invariant `receiver_kind_pattern_test.exs`(grep plugin handle_info 中 chat_message + 外部写 API,fail) + Layer 4 SPEC_REVIEW checklist 项 + Layer 5 memory `feedback_plugin_external_integration_is_receiver_kind`。Reference impl: `apps/ezagent_plugin_feishu/`(`Ezagent.Entity.FeishuChat` + `EzagentPluginFeishu.Behavior.FeishuReceive`)| impl |
| 128 | **`in_session(session_uri)` matcher — 把路由规则范围限定到单一 session**(post-Phase-5 Plan B,2026-05-17)— 老 Matcher 集合(mention/from/text_contains/always 等)都是消息内容匹配,没有"消息来自哪个 session" 的概念。Feishu binding 需要"`session://main` 的消息送到 `feishu://oc_xxx`,但 `session://other` 不发"——globally-scoped 的 `always() → [feishu://oc_xxx]` 会全 session 都发。新 matcher `{:in_session, session_uri_str}` 读 `msg.session_uri` 字段。注意:**Chat.invoke(:send) 必须用 MessageStore.write 返回的 stamped_msg(带 session_uri)给 Resolver**,否则 in_session matcher 永远返回 false(Decision #129) | impl |
| 129 | **Chat.invoke(:send) 用 stored_msg 给 Resolver,不用原始 msg**(post-Phase-5 bug fix PR #46,2026-05-17)— `MessageStore.write` stamps session_uri on the returned struct;原代码把原始 msg(`session_uri=nil`)传给 Resolver,新 in_session matcher(Decision #128)永远 false。Fix: `case MessageStore.write(msg, session_uri) do {:ok, stored_msg} -> msg = stored_msg; ...`。这是 in_session matcher 引入后浮现的 bug——matcher 设计本身没问题,数据流上游忘了 stamp 同步 | impl |
| 130 | **CLI is distributed-Erlang RPC client to the running runtime,not HTTP**(post-Phase-5 第二次 pivot,2026-05-17 Allen)— `mix esr` 启动一个短暂的 short-name node,`Node.connect(ezagent_runtime@127.0.0.1) + :rpc.call(EzagentCli.Exec, :exec, [argv])`。runtime 端 `Ezagent.Runtime.configure_for_runtime!` 在 phx.server 启动时调 `:net_kernel.start([ezagent_runtime@127.0.0.1, :longnames])`。**单机假设**:CLI 永远只跟 local runtime 通信;远程操作通过 runtime↔runtime federation(Decision #48 形态 A,Phase 6+)。**不变式**:任何 LV 能做的事 CLI 必须能做,且**必须在同一 BEAM 里执行**(`apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs` 是 CI gate)。Cookie 在 `$EZAGENT_HOME/<profile>/runtime/cookie`,auto-mint,chmod 600 | impl |
| 131 | **PtyServer 通过 mcp.json 把 `agent_uri` 传给 Python bridge,不靠 env-var 链式继承**(post-Phase-5 PR #49,2026-05-17 Allen)— 老路径:PtyServer 把 `EZAGENT_AGENT_URI` 设到 erlexec 的 env list → claude 子进程继承 → Python MCP bridge 子子进程继承。任一环节 dropping env var 就 broken,且不可见(silent bare-bridge)。Fix: `McpConfigWriter.write!(agent_uri: ...)` 把 `EZAGENT_AGENT_URI` 写进 mcp.json 的 `env` 字段;claude 启动 bridge 时按 mcp config 设的 env 给它。**单一确定性传输**,operator-shell env 仍作为 fallback。模式可推广:任何要"PtyServer 喂参数给 Python/外部子进程"的场景,优先 mcp.json 而不是 env-var 链 | impl |
| 132 | **Channel `meta` schema 强制 `Record<string, string>`,非字符串值 silently drop**(Phase 6 PR 26,2026-05-18 Allen)— `notifications/claude/channel` 的 `meta` 字段由 Anthropic channels-reference spec 定义为 `Record<string, string>`,任何 non-string value(list / map / nested object)会让 claude TUI 整条 notification silently drop,**没有错误返回到任何一侧**。PR 14 把 attachment list 塞进 `meta.attachments` 违反了这条,inbound 链路坏了 3 周才发现。**Fix**:`apps/ezagent_domain_instance_message/lib/esr/behavior/chat.ex` Agent receive 分支只允许 string-valued meta keys;附件信息在 `content` 文本里以 breadcrumb 形式出现(`[attachment: type=file name=x]`);可选 `meta.file_path: <abs-path>` 字符串(仿 cc-openclaw `channel_server` 约定),由 claude `Read` tool 拉取实际内容。**Invariant test**:`apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings (no list/map smuggling)"——任何 PR 重新引入非字符串 meta value 必须挂 CI。**未来不变式**:扩展 channel adapter(v3, derivatives)时禁止把结构化数据塞 meta;结构化数据走 `content` 或 `tools/call` 显式拉取。详细 forensic record:[docs/notes/phase-6-architecture-closeout.md](docs/notes/phase-6-architecture-closeout.md) §2.3 | impl |
| 133 | **`Ezagent.Entity.User.default_caps/0` — 每个 user 创建时自动获得 `kind=:session behavior=:any` 基线 cap**(Phase 6 PR 27,2026-05-18 Allen)— Phase 6 前 `Ezagent.Domain.Identity.Users.create/3` 不注入任何默认 cap,Feishu 绑定路径 silently `:unauthorized`(SenderResolver 解析到 user URI 但该 user 没 `kind=:session` 任何 cap → CapBAC deny)。**Fix**:`Ezagent.Entity.User.default_caps/0` 返回 `[%Capability{kind: :session, behavior: :any, instance: :any, granted_by: system://bootstrap}]`;`Users.create/3` prepend 到 caller 提供的 caps;`EzagentPluginFeishu.BindingPolicy.apply/2` 在 bind 时 idempotent 重新 grant(MapSet 语义保证),覆盖 pre-PR-27 已创建 user。**关键 trade-off**:`behavior: :any` 而不是 `behavior: Ezagent.ActionSet.Chat`,因为 `ezagent_domain_identity` 不能反向依赖 `ezagent_domain_instance_message`(后者已经依赖前者,会循环)。这是**循环依赖的妥协,不是"默认 cap 该用通配符"的 idiom**。未来 plugin authors 看到 `:any` 不要 cargo-cult 到自己的 default cap——能用模块引用就用模块引用,narrower scope 永远更安全。**Drift defenses**:`apps/ezagent_domain_identity/test/esr/entity/user_test.exs` `describe "default_caps/0 (PR 27)"` 锁 invariants(包含 `kind=:session`、`granted_by=system://bootstrap`、不含 admin wildcard);docs/notes/phase-6-architecture-closeout.md §2.1 记录 forensic | impl |
| 134 | **`EzagentPluginFeishu.InboundDispatcher.do_dispatch` dispatch mode 从 `:cast` 改 `:call`,把 deny 错误同步回原 chat**(Phase 6 PR 27,2026-05-18 Allen "silent down 不可接受")— `Ezagent.ActionSet.Chat.@interface[:send]` 声明 `:send` 为 `:cast`(fire-and-forget,无返回值);但 Feishu inbound transport 现在 `mode: :call` dispatch,拿到 `{:error, :unauthorized}` 后 `Client.send_text(chat_id, "❌ Ezagent: 没有权限...")` + THUMBSDOWN react,让人类操作员看到失败原因而不是 silently drop。**关键设计点**:`Ezagent.Invocation.dispatch/1` 接受 caller 传入的任何 mode,`@interface` 的 mode 声明是**默认传输行为提示,不是硬契约**。Feishu transport 选择 :call 覆盖 :cast 是合法的——为获得错误回执路径。**未来 transport(Slack / Discord / email)**实现 inbound 时应复用这个 pattern:`mode: :call` + 解构返回 + 显式错误回执到原 channel。**不要做的事**:不要从别的 `:cast` call site 复制 mode 设置到 Feishu inbound;不要假设 `@interface` mode 是 transport 必须遵守的。**Drift defenses**:Decision Log 这条 + `EzagentPluginFeishu.InboundDispatcher` moduledoc + docs/notes/phase-6-architecture-closeout.md §2.2 | impl |
| 135 | **`Ezagent.WorkspaceRegistry` — 第 5 个 ETS Registry,session→workspace 反向 lookup**(Phase 7 PR 31 / IMPL-7-1)— `Ezagent.ActionSet.Chat.invoke(:send)` at chat.ex:116 调 `Ezagent.Routing.Resolver.resolve/3` 时丢了 workspace_uri 上下文(workspace-scoped routing rules 不 fire,Phase 6 PR 8 的 workspace 字段实际上没人喂)。**Fix**:新加 `Ezagent.WorkspaceRegistry`(`apps/ezagent_core/lib/esr/workspace_registry.ex`),`bind(session_uri, workspace_uri)` / `lookup(session_uri)` ETS-backed,跟 Kind/Behavior/Routing/Spawn/Template Registry 平级第五个。`Ezagent.Workspace.Loader.invoke_template` 在 spawn 每个 session 后调 `bind`。chat.ex:116 读 lookup 再传 `workspace_uri:` 给 `Resolver.resolve/4`。Unbound 返 `:error` → fallback `nil` → 跟 pre-PR-31 全局行为兼容(零 migration)。**为什么用 Registry 而不是改 Chat slice**:(a) `SpawnRegistry.spawn/1` URI-only Decision #65 不能破;(b) Chat slice 跟 workspace 概念正交;(c) 不需要 migration。**Drift defense**:invariant test `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs` 4 个用例驱动 production 路径,任何破坏 workspace 隔离的改动挂 CI | impl |
| 136 | **AgentTemplate + SessionTemplate 是 `Ezagent.Kind.Template` umbrella 下的两个 Template Class,不需要新命名空间**(Phase 7 PR 37+38 / D7-2)— Allen 2026-05-18 round 2 brainstorm 中纠正:`Ezagent.Kind.Template` 早就在 `apps/ezagent_core/lib/esr/kind/template.ex` 作为 umbrella behaviour 存在(callbacks `template_name/0`/`validate/1`/`instantiate/3`),Workspace 只是当前最大用户(`session_templates` map 引用 Template Class 名字)。新加的 **AgentTemplate**(`template://agent/<name>`)+ **SessionTemplate**(`template://session/<name>@<hash>`)都是该 umbrella 下的新 Template Class 实现,跟 `Ezagent.Template.CcChannelInstance` 和 `Ezagent.Template.GenericSession` 同级。**`template://` scheme** SpawnRegistry 注册一次,spawn fn 根据 URI.host 分派:`"agent"` → AgentTemplate Kind,`"session"` → SessionTemplate Kind。**关键反向决策**:之前考虑过把 AgentTemplate 改名 `AgentBlueprint` 避开 "template" 词冲突,实证是没冲突——`Ezagent.Kind.Template` 本就是 umbrella,SessionTemplate 是 template 的一种是天然的(Allen "Session Template 不是 template 的一种吗?")。**Drift defense**:GLOSSARY AgentTemplate / SessionTemplate / Template umbrella 三个条目清楚分层 | impl |
| 137 | **`Ezagent.Capability` instance 字段加 scope-tuple shapes,v0 "no delegation" 升 v1 bounded delegation**(Phase 7 PR 42 / D7-3,Ezagent v1 release marker)— Phase 7 之前 ARCHITECTURE §17.6 baseline "v0 不支持 delegation"。Phase 7 闭幕 = Ezagent v1 release(Allen "phase 7 结束后我们实际上进入了 v1,该加上了")。新加两种 instance shape:`{:within_session, session_uri}` 和 `{:spawned_by, principal_uri}`,在 `matches?/2` 通过 `instance_match?/2` 处理。**`:any` 仍然是唯一真正的通配符**;tuple shapes 只**收窄**,不**放宽**(orchestrator 持 `{:within_session, A}` cap 只能在 session A 内 grant_cap,不能扩到 session B)。**关键设计**:不在 CapBAC step 5.5 里 dispatch lookup 来 resolve lineage(会无限递归);PR 40 用一个独立的 ETS 注册表存 Agent.spawned_by lineage,`instance_match?` 单 ETS 读。PR 42 ship `{:spawned_by, _}` deny-by-default placeholder,PR 40 接 lineage 数据后转 real match。**Drift defense**:`apps/ezagent_core/test/esr/capability_test.exs` "scope-bounded instance tuples" describe block 6 个测试覆盖 within_session 通过/拒、prefix boundary、spawned_by 默认拒、kind 错配仍拒;`Ezagent.Capability` moduledoc + `t.instance` typespec 都声明新 shapes 是 first-class | impl |
| 138 | **Federation 显式从 Phase 7 scope drop,留 dev team 后续判断**(Phase 7 / D7-4)— Allen 2026-05-18: "Federation 可以完全不做,我后续再开"。Phase 7 是 Allen 亲手驱动的最后一个 phase + Ezagent v1 release,完整 handoff 给 dev team 假设(Allen 完全离开)。Federation(Decision #48 形态 A,runtime↔runtime cross-node)既不在 SPEC 也不在 PLAN,也不留 prep hook("in case")。Roadmap §9b non-goals 显式标记 "Federation — Allen reopens later"。**Drift defense**:Phase 7 任何 PR 引入 federation hook 应在 review 被拒(SPEC_REVIEW Layer 4 checklist 项) | impl |
| 139 | **EZAGENT_HOME DB 迁移从 opt-in 升 mandatory,`mix ezagent.bootstrap` 统一 install**(Phase 7 PR 33 / D7-5 + D7-9)— Allen 2026-05-18: "DB 迁移要做,因为后续我们要给开发团队提供一个准生产环境,数据库长期可用"。`mix ezagent.home.adopt_db` Phase 6 PR 1 已 ship 但是 opt-in;Phase 7 把它纳入 canonical install flow 经由 `mix ezagent.bootstrap`(`apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex`):home.init + deps.get + adopt_db + ecto.create/migrate + health-check 一条命令。pre-existing CI gate `repo_root_clean_test.exs`(Phase 6 PR 1)继续守 "repo 树里无 *.db"。**为什么不做 OTP release**(D7-9):Allen "暂时只需要简单的 run 脚本(或者 mix task)方便启动就可以了" + 没 federation 需求 → release 暂搁,dev team 后续自己 scope。**Drift defense**:V1.1 + V4.5 锁 bootstrap 端到端;`docs/onboarding/first-30-days.md`(PR 51 deliverable)把 bootstrap 写成 day-1 必跑 | impl |
| 140 | **`esr-developer` Skill 是 dev team 的 Allen 替身,而不是 docs 替代**(Phase 7 PR 50 / D7-6)— Allen 2026-05-18: "制作一个 esr skill,用于后续开发团队基于现有 esr 进行开发时辅助 LLM"。docs 会 decay(没人写就 stale),但 dev team 的 Claude Code agent 每次干活都会 invoke 这个 skill(skill activates on repo file open or `/esr-help`)拿当前 ground truth。Skill 内容 6 大类:invariants / 反 pattern(skill 主动拒绝)/ how-to(加 plugin/Kind/Behavior/Template Class)/ debug 处方 / project conventions / pointer index。**关键 fail-closed 反 pattern**:naked `PubSub.broadcast` 绕 dispatch、`admin_caps()` 当 goto、atom-shorthand cap behavior(应该 module ref 或 `:any`)、list/map value 塞 meta、`:cast` 用在需要 error feedback 的 inbound、generic channel 抽象覆盖 text + media、orchestrator 改 deterministic(D7-1 violation)、SessionTemplate fork 带 message history(D7-7 violation)、plugin unload(D7-8 violation)。**Drift defense**:V1.2(skill 自动激活)+ V5.2(skill 拒绝 anti-patterns)+ skill maintenance 写进 SPEC_REVIEW checklist 第 7 项("did this PR introduce a pattern... update SKILL.md") | impl |
| 141 | **SessionTemplate fork unit = configuration only(消息历史不带)**(Phase 7 PR 38 / D7-7)— Allen 2026-05-18 round 3: "A,只 fork 配置就可以"。SessionTemplate 存 agent_slots + routing_rules + orchestrator_template_uri 等配置;**不存** message history。**Fork** 通过 `Ezagent.Entity.SessionTemplate.fork(parent_uri@hash, new_name)` 创建新 template row(`parent_template_uri = parent_uri@hash`),立即实例化新 session(empty chat history)。**Merge-back** 经 orchestrator `update_template()` tool 写新 version_hash 到 parent name(需要 `template:write` cap);老 hash 的 in-flight session 继续用 snapshot 的 hash 不受影响。**为什么不做三向 merge**:消息层 conflict resolution 体量巨大 + Phase 7 scope cap(orchestrator 应该足够强,不需要 git merge);留 dev team v1.x+。**Drift defense**:invariant test `template_fork_lineage_test.exs` 锁 fork 必带 parent_template_uri 且老版本不变;orchestrator 自己 6 个 tool 不含 `fork`(fork 是 SessionTemplate registry 操作,不是 orchestrator verb,误命名会让 dev team 以为 orchestrator 能 fork 别人的 template) | impl |
| 142 | **Plugin runtime hot-install via `:application.load + ensure_all_started`,不做 unload**(Phase 7 PR 36 / D7-8)— Allen 2026-05-18: "plugin 我希望 runtime hot-reload"。`mix ezagent.plugin.install <path>` 把 plugin 的 ebin 加 code path、`:application.load/1` 读 .app 文件、`:application.ensure_all_started/1` 启 supervision tree(plugin 自己 `Application.start/2` 跑 register hooks)。**Concurrency**:Application controller 内部 serialize load/start;并发 install 同 app 第二次见 `{:already_loaded, _}` 当 success;不同 app 撞同名 template_name 由 `TemplateRegistry` strict duplicate 拒。**Mix.env() 陷阱**(写进 plugin authoring guide):plugin 的 `Application.start/2` 用 `Mix.env()` 拿到的是 BUILD-time env 不是 host runtime env;推荐 `System.get_env("MIX_ENV")` 或干脆别在 boot 用 env-dependent 逻辑。**不做 plugin unload**:活的 Kind instance lifecycle 管理复杂,留 dev team v1.x+。Production hot-deploy(OTP relup)同样不在 Phase 7 scope。**Drift defense**:V1.4 端到端测 + `Mix.Tasks.Ezagent.Plugin.Install` moduledoc 显式标 unload 不做(防 dev 假设对称 task 存在) | impl |
| 143 | **SessionTemplate versioning = git-style 不可变 SHA hash + 可变 tag overlay**(Phase 7 PR 38 / D7-10)— Allen 2026-05-18 round 3: "修改后的 session template 版本号更新(更新为一个新的 hash,类似 git 的方式,也可以打 version tag),不影响已经在运行的 session"。Every SessionTemplate row 的 URI 是 `template://session/<name>@<version_hash>`,`version_hash = SHA-256` over slice content(canonical encode,排除 timestamps + created_by)。同 config 同 hash(content-addressable)。`orchestrator.update_template()` 产 **新 row 新 hash**,**不覆盖** 老 row;tags 在另一个 `template_tags` registry 存 `(name, tag) → version_hash` 可重新指向。已实例化的 session **snapshot the resolved hash at instantiate time** 继续用之即使老 hash 后被覆盖。**为什么 content-address 不用单调整数**:相同配置自动 dedup;branching 自然(parent_template_uri 指特定 commit 不是漂移的 version 整数);跟 dev team git 心智模型对齐。**实现注意**:hash canonical encode 必须确定性—`:erlang.term_to_binary(slice, [:deterministic])` 或等价。**Drift defense**:invariant test `template_immutable_hash_test.exs` 锁 update_template 新 row 不影响老 row;tag 重指不动 hash row | impl |
| 144 | **CC channel `meta` schema(Decision #132)+ User.default_caps `:session:any` baseline(Decision #133)+ session→workspace `WorkspaceRegistry`(Decision #135)+ scope-tuple cap(Decision #137)— Phase 6/7 累计形成的"production-grade Ezagent v1"基本不变式集合**(Phase 7 closeout / cross-PR meta-decision)— Ezagent v1 release(Phase 7 闭幕)的 promise 不止是"功能完整",更是"这些不变式 in code + in CI + in skill 三层都守住":(a) channel meta 全 string(CI gate `chat_test.exs` "to_claude payload meta values are all strings");(b) 每个 user 创建必有 session.chat 基线 cap(CI gate `user_test.exs default_caps/0`);(c) session.send 调 Resolver 必带 workspace_uri 上下文(CI gate `workspace_isolation_test.exs`);(d) scope-bounded delegation 严格收窄不可放宽(CI gate `capability_test.exs` "scope-bounded instance tuples");(e) Feishu inbound deny 必回写到 chat 不 silent(CI gate `feishu_inbound_cap_denial_feedback_test.exs`);(f) v1 prototype 全删(CI gate `no_v1_bridge_after_cutover_test.exs`,PR 32 ship 后);(g) ws sidecar EOF reap(CI gate `sidecar_orphan_reap_test.exs`);(h) workspace 隔离 cross-PR 共识(workspace://A rule 不在 workspace://B 触发,CI gate `workspace_isolation_test.exs`)。**为什么单独立一条 meta-decision**:dev team 接手时这 8 条是"系统级别约定",不该任何单 PR 能 silently 破。`esr-developer` skill 把这条 + 它们对应的 CI gate 名字列在 Architecture invariants 区,新 dev 改任何这些 area 时 skill 主动 surfaces 风险 | impl |
| 145 | **Phase 9: workspace = deployment unit(URI SPEC v3 + cap workspace 维度 + dispatch isolation + tenant auth + 数据隔离 + Keycloak system workspace)— Ezagent 完整租户隔离 cross-PR meta-decision**(Phase 9 closeout 2026-05-21,14 PR 合并 #158-#171)— `docs/notes/workspace-as-deployment-unit.md` 定义的"30% gap"被关闭:workspace 从 Phase 8c 的"配置 bundle(members + session_templates + routing_rules)"升级到完整部署单元。**4 维度的隔离**(全部 in code + in CI + in skill 三层守住):(a) **URI 携带 workspace** —— SPEC v3:`entity/session/template/resource://<type>/<workspace>/<name>`,3-segment 强制,2-segment raise(CI gates: `entities_have_workspace_test.exs` + `all_per_tenant_uris_have_workspace_test.exs`);(b) **Capability 加 `workspace_uri` 字段** —— `@enforce_keys`,matcher `workspace_match?/2` 严格检查,cross-workspace cap = `workspace_uri: :any` 结构标记(CI gate `cap_has_workspace_test.exs`);(c) **Dispatch step 5.6 跨 workspace 隔离** —— caller workspace == target workspace OR caller 是 system 成员 OR cap workspace=:any,否则 `:cross_workspace_denied`(distinct from `:unauthorized`,inbound transport 差异化 surface;CI gate `cross_workspace_isolation_test.exs` —— 临时禁 5.6 → 2/6 测试失败,true gate);(d) **数据列 + 读写过滤** —— 6 张 per-tenant 物理表(messages/invocations/users/kind_snapshots/entity_tokens/entity_profiles)加 `workspace_uri` NOT NULL 列(SQLite ALTER COLUMN 不支持 → CREATE-NEW/INSERT-SELECT/DROP/RENAME 模式),`Ezagent.Persistence.scope_by_workspace/2` helper 统一读路径过滤,changeset 强制非空,grep gate 拒绝 nil 写入(CI gates: `per_tenant_tables_have_workspace_column_test.exs` + `no_nil_workspace_writes_test.exs`)。**Keycloak realm-admin 模型(§13)**:`workspace://system`(visible: false)是真实 workspace;成员通过**身份**而非 ad-hoc cap grant 持跨 workspace 权限(`Capability.cross_workspace?/2` arity-2 检 caller workspace == "workspace://system");admin 从 `entity://user/default/admin` 迁到 `entity://user/system/admin`;workspace 选择器**权限分支**(SPEC §6.4 amendment 3)—— system 成员 click → 上下文切换(no logout);普通 user click → 拒绝 + "登录到 X" 提示(不静默登出)。**Tenant-aware auth**:`SessionPrincipal.put/2` 同时写 `:current_entity_uri` + `:current_workspace_uri`,§6.5 invariant 强制 `current_workspace_uri == entity_workspace_uri(current_entity_uri)`(system 成员放宽);LiveAuth on_mount assigns 都进 socket。**Test pool 配置**(PR #165):Phase 9 把 dispatch concurrency 提到 pool 5 瓶颈以上 → 调到 20 + `queue_target: 1000` / `queue_interval: 5000`,根因不是"sandbox bug"是"集成测试 Repo concurrency 上升"。**为什么单独立一条 meta-decision**:Phase 9 14 个 PR 落地 1-2 周内不可能由单一 review 覆盖;dev team 接手时必须明白"workspace = deployment unit"不只是术语,是 4 个隔离维度的结构性约定,任何**单**PR 破任一维度就违反 V1 promise。`ezagent-developer` skill invariant 11 已扩展到所有 per-tenant scheme;新 invariant 13("跨 workspace dispatch 需要 system 成员身份或显式 cross-workspace cap")守住 PR-4 + PR-8 的合约。完整记录见 `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md` + 3 个 amendment + `docs/notes/phase-9-demo-2026-05-21.md`(7 截图 demo) | impl |
| 146 | **嵌套 shell:一个外层 shell 拥有通用 chrome,两个内层 perspective(workspace / admin)**(2026-05-22 V1 验收期,Allen)— UI 层曾有**两个平级 shell**:`ide_shell`(~13 个 workflow 页)+ `AdminSettingsShell`(7 个 config 页),各画各的 header,通用 chrome(avatar / 通知 / 搜索+⌘K)只活在 `ide_shell` 里 → 7 个 admin 页没有 avatar、收不到通知、按不了 ⌘K。Allen 的模型:一个 app 级 shell 拥有"每个用户永远需要的"东西,内层再分 workspace 视角(session/agent)和 admin 视角(挂 `workspace://system` 的全局 runtime 配置)。**重构后**(3 PR #208-#210):`AppShell.app_shell`(Tier-3,接 CmdK 一次)→ `IdeShell.ide_shell_outer`(Tier-2 外层 chrome,带 `perspective :: :workspace | :admin` 类型化 context 契约)→ `:body` slot 装 `workspace_shell` 或 `admin_shell`(Tier-2 内层)。旧 `ide_shell/1` + `AdminSettingsShell` 删除,通用 chrome 现在**只定义一次**。**为什么 Tier-3 `app_shell` 包装器**:命令面板是有状态 `LiveComponent`(Tier-3),展示 shell 是无状态 atom(Tier-2,UI Contract 的零-LV-依赖层)—— 把 LiveComponent 塞 Tier-2 违反契约;Tier-3 wrapper 是让两条规则同时成立的接缝,CmdK 在此**只接线一次**而非每个 LV 一次。两道 codex review(rescue + adversarial)把"CmdK 上移 Tier-2"等 BLOCKER 挡在实施前。同期 V1 UI 验收:`uri_picker` 组件 + `UriOptions`(caller-authorized 工作区作用域)替换 5 处裸 URI 输入,`@interface` 加 `description:` 键(CLI / CmdK / 未来 slash 共享的 action 描述单一源)。完整记录:`docs/superpowers/specs/2026-05-22-nested-shell-refactor.md` + `2026-05-22-v1-uri-pickers-and-cmdk.md` | impl |
| 147 | **Router / Behavior / Kind self-built architecture(SPEC PR #445,2026-05-28)— full plugin contract rewrite** — Allen 2026-05-28 10:30 directive "router, behavior, kind 三个" 是 core architectural insight:plugin authors 写 `handle_<action>(args, ctx)` 返 effects,**永不**见 slice 或 snapshot。SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` r3 定稿(1341 EN / 1329 ZH 行,8 OQs 全部 closed,r2 codex 7 HIGH + 4 MED + 2 LOW 全部 addressed,r3 基于 8 个历史 migration 的 GitHub PR 速度数据 recalibrated 进度估计)。3 个核心 primitives:**Router**(dispatch 入口 + cap + audit + idempotency,~200 LOC,peer of Behavior + Kind)、**Behavior**(per-action declarative contract via `use Ezagent.ActionSet` + `action/3` 宏 + `handle_<action>/2` 处理器 + effects 返回)、**Kind**(URI + lifecycle + 3 个 composition patterns:Session / Entity / Resource — Resource 分 `:cold_resource` default `on_change` / `:hot_resource` default `:ephemeral` + opt-in periodic,r2 HIGH-3 closure)。Effects 词汇 9 件:`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning`(with `bind_as:` + `{:ref, _, _}` substitution,r2 HIGH-1 closure)/ `:saga` / `:terminate` / `:halt`。Framework 8 个 plugin-invisible 模块:Router / EventLog / SnapshotStore(framework-decided every-N + on-terminate,**NOT** per-Behavior,r2 HIGH-3 closure)/ StateRebuilder(lazy-on-first-load per OQ-8) / SagaRunner(best-effort partial restore,**NOT** atomic rollback,r2 HIGH-5 closure)/ EventSubscriber(declarative,subscriber 用同一 effect 词汇)/ Caps.Engine / Kind.Host。**LOC 目标**:plugin 11,000 → ≤5,500(≥50% reduction)+ framework ~2,480 LOC(from ~5,000 scattered today)。**Acceptance**:10 CI-enforced criteria,含 7 grep-gates 防止 plugin 代码 regress 进 framework internals。**Drift defense**:SPEC §11 的 grep gates 永久绑死 plugin code MUST NOT import EventLog / SnapshotStore / StateRebuilder / EventSubscriber / Router internals | impl |
| 148 | **Phase 1 ship — Router + Behavior(new) + Kind + LegacyBehaviorAdapter primitives**(PR #451,2026-05-28)— SPEC §6 Phase 1 落地。新模块:`Ezagent.Router`(~140 LOC,wraps existing `Ezagent.Invocation.dispatch/1` + `Kind.Runtime.handle_dispatch/4` via `%Cmd{}` → `%Invocation{}` 翻译;Phase 1 keep additive,Phase 2 加 direct handler invocation)、`Ezagent.Cmd`(dispatch envelope struct,target + action + args + ctx;`action` 是 atom 不再编码在 URI 的 `?action=` query string —— SPEC §2.1 分离 identity 跟 intent)、`Ezagent.ActionSet` 加新合约面(`use Ezagent.ActionSet` + `action/3` defmacro + `apply_effects/2` pure bucketiser,§4.4 phase order: State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations)。**LegacyBehaviorAdapter**:Phase 1 + 2 期 dispatch-equivalent bridge,**NOT replay-equivalent**(r2 HIGH-2 closure 显式标记 + parity test set 不验证 replay for adapted Behaviors)。子 PRs:#447(EventLog Phase 1B)、#448(SnapshotStore)、#449(SagaRunner)、#450(Router + Behavior + Kind + LegacyAdapter integration)。`Behavior.Echo` 是 Phase 1 唯一 new-contract reference plugin。**Drift defense**:SPEC §11 grep gate 守 plugin code 不 import framework internals;`Behavior.apply_effects/2` 是 PURE function,可单测 without process/IO setup | impl |
| 149 | **Phase 1.5 / 1.5b ship — Kind.Runtime new-contract dispatch + effect executor wiring**(PR #453 + PR #454,2026-05-28)— Phase 1 让 `Ezagent.ActionSet.apply_effects/2` 跑通 pure bucketiser,但 buckets 的 side effects(SnapshotStore write / EventLog append / Router dispatch / Phoenix.PubSub broadcast / SagaRunner / `Kind.terminate`)需要 caller 执行。Phase 1.5 把 `Kind.Runtime.apply_new_contract_effects/4` 接 PURE bucketiser 跟实际 framework 操作:固定顺序 **State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations**(Runtime moduledoc 是 normative source)。Phase 1.5b 完成 effect executor:`:set` 早在 `apply_effects/2` 内 applied(让 downstream `{:ref, ...}` substitution 看见 new values),`:effect_returning` execute 后 bind 到 `returning` map,`:ref` substitution walks 任何 nested term(maps / lists / tuples / 非-URI 非-MapSet structs)。`{:halt, reason}` short-circuits → 映射到 `{:error, {:halt, reason}}`,SnapshotStore 永远不见 would-be new slice。**Drift defense**:`apply_effects/2` 单测 + `Kind.Runtime` integration 测覆盖 bucket order + halt 行为 + `:ref` substitution shape | impl |
| 150 | **Phase 2 / 2.5 ship — 28+ domain + 6 core Behaviors 全部 migrate 到 new contract**(PR #462 + PR #463,2026-05-28)— Phase 2 整合 7 个子 PR(p2a chat / p2b identity / p2c workspace / p2d external-mirror / p2e cc plugin verify-only / p2f feishu / p2g small plugins echo+np+curl_agent)。每个 Behavior 从 `@behaviour Ezagent.ActionSet` + `invoke/4` 切到 `use Ezagent.ActionSet` + `action/3` + `handle_<action>/2` + effects 返回。Slice 突变全走 `{:set, key, value}` effect;PubSub 广播全走 `{:notify, topic, payload}` effect;cross-Kind dispatch 全走 `{:dispatch, %Cmd{}}` effect;result-dependent in-handler dispatch(e.g. ReadMarker.mark after successful chat.receive cast)仍直接调 `Router.dispatch/1`(effect 词汇丢 dispatch 返回值)。Phase 2.5 PR #463 收尾 core 6 个 Behavior:Lifecycle / Routing / Presence / Sandbox / Notifications + 一些 cap-only(`dispatchable?/0 == false`)。**Migration parity policy**(r2 MED-3 closure):"dispatch parity"(legacy adapter mode — same reply, same PubSub)vs "replay parity"(new-design only — events fold to same state);新 EventLog rows 是 **intentional incompatibility** 不是 equivalence。**Drift defense**:per-Behavior 集成测 覆盖 same-as-legacy semantics;`Behavior.@interface` 仍由 `action/3` 宏自动派生,所有 adapter(CLI / LV / Channel)无感知 | impl |
| 151 | **Phase 3 ship — LegacyBehaviorAdapter DELETED + `invoke/4` retired to `@optional_callbacks`**(PR #464,2026-05-28)— Phase 2 完成 28+6 Behaviors 全数 migrate 后,无 production 路径再用 `Behavior.invoke/4`。Phase 3 物理删除 `Ezagent.LegacyBehaviorAdapter` 模块 + 所有引用;`@callback invoke/4` declaration 在 `Ezagent.ActionSet` 标记 `@optional_callbacks`(grep-able + 让 stale Behavior 见 precise CompileError 而非 silent dispatch failure)。`Kind.Runtime.handle_dispatch/4` 旧 step 7 `behavior.invoke(action, slice, args, ctx)` 路径被 new-contract `behavior.handle_<action>(args, ctx)` 完全取代。**Phase 1 + 2 grace window 关闭**:任何遗漏的 legacy Behavior 会在 compile time 撞 missing-handler CompileError(SPEC §4.3 `@before_compile` invariant — 每个 declared action MUST have matching `def handle_<action>/2`)。**Drift defense**:codex r2 HIGH-2 closure(adapter NOT replay-equivalent)被 Phase 3 deletion 物理保证 ——adapter 不在了,replay parity 仅适用 new-contract Behaviors。`docs/scenarios/README.md` Category 18 同步更新,反映"LegacyAdapter Phase 1 引入 / Phase 3 删除"git archaeology trail | impl |
| 152 | **Phase 4 ship — Kind.Server attach metadata + `read_graph` cleanup + audit fix**(PR #469,2026-05-28)— Phase 4 polish:`Kind.behaviors_of/1` + `persistence_of/1` 新 helpers 优先于 `__attached_behaviors__/0`(plugin authors 用 这些)。`Audit.uri_to_str(:system)` 修复返回 `"system://anonymous"`(原来某些 boot path 传 `:system` atom 直接给 audit 写入,SQL 接受不了非 string)。`read_graph` 函数清理 stale code paths。**E2E test suite (#465-#468) ship**:Category 5 + 10(CapBAC + routing)/ scenarios #24 + #25(destroy cascade + state rebuild)/ Categories 4 + 7 + 17(Feishu + PTY + admin LV)/ scenarios #30 + #5-7(plugin DX + cross-flavor agent roundtrip)— 共 165 个 passing E2E tests 覆盖 SPEC §7 全部 acceptance criteria。**E2E scenarios catalog (#452)** 同期 ship,30 个 scenarios 文档化在 `docs/scenarios/`,bilingual lockstep,作为 Phase 1-4 migration 的 acceptance gate。**Drift defense**:165 个 E2E tests 是 Phase 1-4 完成的 actual gate(per `feedback_completion_requires_invariant_test` —— invariant test 失败 = 架构目标未达,**这是** completion claim 的 gate,不是 PR-merge 或 unit-tests-pass);`docs/scenarios/README.md` §5 "Phase 1-4 migration shipped" 是 dev team 接手时的 single-source-of-truth | impl |
| 153 | **Lifecycle API = SOLE developer surface;R/B/K = internal engine**(SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`,Phase A/B/C,2026-05-29)— Allen 的 core 决策:把 §6.0 的 CQRS 机制(slice / invocation / snapshot / persistence-strategy / 四个 boot hooks)全部藏在 `use Ezagent.Lifecycle` 后面。**两容器状态模型**:`state`(PERSISTENT — framework auto-snapshot)+ `transients`(NEVER persisted — 没有序列化路径;PIDs / refs / ETS / ports / subprocess / monitor refs)。一个 transient **结构上不可能**被意外持久化(无序列化路径),也**不可能**在重启时被遗忘(只能在 `activate/2` 里建,而 `activate` 每次 start 都跑 —— fresh + cold-load 同路径)。这就**by construction** 杀掉了 cold-restart bug class(#110 orchestrator MCP ETS / #113 codex bridge subprocess / #114 AgentLineage ETS — 全是"fresh works, restart doesn't")。**五个 coarse hooks**:`create/1`(首次存在,gated by `ever_created` 列 OQ-1)/ `activate/2`(每次 start,pre-`:ready`,重建所有 transients + reconcile DB-projection state)/ `handle_<action>/2`(不变的 effect 语法 + 新增 `{:set_transient, k, v}` OQ-2)/ `deactivate/2`(优雅停,`:ok`-only F5)/ `destroy/2`(永久删除)。**两个 fine hooks**:`pre_handle/3` + `post_handle/4`(横切关注:authz / audit / effect 注入)。**两个补充 hooks**:`handle_signal/2`(非-action 消息 `:DOWN` / PubSub / 自延迟 mailbox — `handle_kind_message/3` 后继,OQ-3)/ `activated/2`(post-`:ready` reachability broadcast,`on_ready/2` 改名,OQ-5)。**§10 codex binding rules**:R10-1 自延迟(`send(self(), …)`)boot work 进 `activated`/`handle_signal` **不进** `activate`(pre-`:ready`)。R10-2 `{:set}` + `{:set_transient}` 是纯 pre-commit map reductions,只 `state` snapshot,transient 变更永不触发 snapshot write。R10-3 **engine `Ezagent.ActionSet` 契约保留**(macro 的 compile target;Phase C 只删 developer-tier 旧表面 + provably-dead carve-outs,**不删** engine 契约 / callback 定义 / `Kind.Runtime` 对它的使用)。R10-4 snapshot WIPE cutover 是 verified ordered sequence(停所有 node → deploy → 删 `kind_snapshots` → 重启)。**§11 三条命名原则**(NP-1 按职责命名最窄准确范围 / NP-2 用本层词汇,`ezagent_core` 模块名不得含上层概念 `Agent`/`Session`/`Orchestrator`/`Workspace`/`Worker`/`Feishu`/`Cc`/`Codex`/`Np`/`Curl`/ NP-3 名字语义宽度 = action 集合宽度)—— 由 `Behavior.Lifecycle → Behavior.Terminable` 的命名旅程提炼(OQ-6;`Terminable` 是 Kind-generic 能力名,`Enumerable`/`Collectable` 风格)。**Phase C HARD gates**:新 task `mix ezagent.check_invariants.lifecycle`(8 个 grep gate + NP-2/NP-3 lint),developer-tier 文件再现旧表面(`use Ezagent.ActionSet` / `def init_slice` / `def state_slice` / `def post_init`/`handle_continue`/`on_ready`/`reconcile_after_load` / `invoke/4` callback / Lifecycle handler 里直调 `Invocation.dispatch`/`SnapshotStore`/`EventLog.append`)即 CI 红。engine allowlist:`behavior.ex` / `kind/runtime.ex` / `lifecycle.ex` / `mix/tasks/compile/ezagent_plugin_check.ex`。**Drift defense**:gate 本身**就是** invariant test(`feedback_completion_requires_invariant_test`);clean 时绿、故意违规时红(已验证)。docs:ARCHITECTURE §6.0.7 + GLOSSARY Behavior/Lifecycle 条目 + `ezagent-developer` skill `references/lifecycle.md` | impl |
| 154 | **Architecture fitness functions = Phase-2 debt counters,Phase-3+ ratchet source of truth**(#25 architecture deepening Phase 2,2026-06-07)— Phase 2 不是重构,而是 executable architecture gate:`mix ezagent.arch.scan` + `apps/ezagent_core/test/architecture/` + `arch_baseline_manifest.exs`。每个 fitness function 量化一个 debt/invariant surface(oversized modules,def-counts,SpawnRegistry writers,create_session callers,duplicated `resolve_template_class`,cc/codex Template Class LOC,raw `Home.path`,`Path.expand("~")`,`spawn_fresh`,`:all_slices`,`{:set}` effects,cap-check presence,Kind.Runtime ordering/reentry,cold-restart respawn round-trip)。Tests assert **count <= cap**,so Phase 2 lands green-at-baseline and freezes current debt;Phase 3+ PRs lower a count and lower the cap to match. Any cap raise is review-blocking unless the manifest line includes `# arch-cap-bump: <reason>`. Human-readable baseline lives at `docs/notes/2026-06-07-arch-fitness-baseline.md`. **Drift defense**:new architecture debt fails CI instead of silently growing;objective refactor acceptance is "count and cap moved",not subjective cleanup prose | impl |
| 165 | **World UI refresh is declaration-driven and SliceChange-backed**(PR #1497,2026-07-23)— UI component layering and runtime refresh are separate concerns. Plugins declare a renderer surface plus caller-scoped `refresh_state/2`; `RefreshSurfaceRegistry` validates/combines declarations; `WorldLive` alone consumes `Ezagent.SliceChange`, coalesces active-surface refreshes, and emits `world:surface_state`; React merges only that JSON-safe partial state. **No plugin name in World refresh logic, no bespoke browser refresh event, no direct PubSub-to-browser shortcut.** Invalid declaration/provider output fails closed. **Drift defense**:World-side contract tests + `PluginWorkspaceLocalityContractTest` exact dynamic-receiver baseline + the UI contract in both Codex and Claude skills. | impl |

---

## Appendix C: 设计哲学

整个 grill 过程在反复做同一件事——**把抽象边界划清楚**。每一层(URI / Invocation / Behavior / Capability / Adapter)各管各事,层间通信只通过狭窄接口(Registry lookup、`ctx` struct、`@interface` schema)。

具体到方法上,反复用的判断标准是:**这条决策让新人加入项目时多懂几个东西,还是少懂几个东西?**

- 凡是让新人多记的 → **拒绝**(mixin 字段冲突、URI 里塞 verb、Command/Interface 三选一、DSL 宏、5 种 socket、Process trait/impl 三选一)
- 凡是让新人少记的 → **接受**(dispatch 一条路、Behavior 一种入口、Capability 一份契约、Plugin 就是 OTP app、`@interface` 一份 schema、URI 是 operationId)

**最终的简化路径**:

```
v0.1: 自创"Kind/Process/Behavior/Plugin/Capability"五件套
v0.2: Phoenix-first,大量复用生态
v0.3: 发现这本质是 OpenAPI-on-Phoenix-transport
        URI = operationId
        @interface = schema
        Adapter = code generator + protocol translator
        Behavior = pure invokable
        Kind = GenServer
        Plugin = OTP app
```

少发明,多装配,Phoenix-as-transport,@interface 是契约。把判断力花在边界上。
## Appendix D: Reference Views — LiveView IM + CLI

两个 reference 实现,展示 Ezagent 怎么用。**v0 阶段用作内部 dogfood**(在接外部 IM 前先验证 spec);**未来产品也会用到** LiveView IM(它是 Ezagent 自带的 web 入口,Feishu/Slack 接入后仍然存在,作为浏览器端的统一界面)。

### D.1 LiveView IM

Plugin: **`ezagent_web_liveview`**(独立 OTP app)
Target LOC: **~300**
依赖: `:phoenix_live_view`、`ezagent_core`

#### D.1.1 URL 结构

```
/sessions                       → 列出所有 session
/sessions/:id                   → 进入某 session(IM 主界面)
/sessions/:id/rules             → routing rules 编辑器(同页 side panel)
/agents                         → 列出所有 agent
/agents/:id                     → agent 详情 + 它持有的 caps
```

#### D.1.2 Session view 布局

```
┌─────────────────────────────────────────────────────────────┐
│ session://feishu-cc/cc-7f3a   [4 members]  [9 rules]   [⚙]  │  ← top bar
├──────────────────────────────────────────────┬──────────────┤
│                                              │  Members     │
│  09:23  @allen  hello @arch-a                │   • pty      │
│  09:23  @arch-a  let me see...               │   • allen    │
│         [thinking 1.2s ▼]                    │   • arch-a   │
│  09:24  @arch-a  pong                        │   • arch-b   │
│                                              │              │
│  ─── allen set default to @arch-a ───        │  Rules       │
│                                              │   • always→A │
│  09:25  @allen  @arch-b 你也看看              │   • @A → A   │
│  09:25  @arch-b  collab idea: ...            │   • @B → B,A │
│  09:25  @arch-a  +1, 我补充一点              │   • pty out  │
│                                              │              │
│                                              │  [+ add rule]│
├──────────────────────────────────────────────┴──────────────┤
│ > _                                              [Send]      │
└─────────────────────────────────────────────────────────────┘
```

#### D.1.3 关键交互

| 用户动作 | LiveView event | 内部 dispatch |
|---|---|---|
| 输入 `hello @arch-a` + Send | `send_message` | `dispatch(%Invocation{target: chat/receive, args: %Message{sender: allen, mentions: [arch-a], body: "hello @arch-a"}})` |
| 输入 `/set-default A` | `slash_command` | `dispatch(%Invocation{target: session_routing/set_default, args: %{agent: "A"}})` |
| 点击 "+ add rule" | `open_rule_editor` | LiveView 内部状态;提交时 dispatch `session_routing/add_rule` |
| 点击 mention `@arch-a` | (nothing,纯渲染) | — |
| 加载历史 (mount) | (mount hook) | 查 messages 表 last 100 条 |
| 实时新消息 | PubSub `<session_uri>:events` | LiveView assign update |

#### D.1.4 Render dispatch — View 抽象的具体落地

LiveView module 实现 `Ezagent.View` behaviour:

```elixir
defmodule EzagentWebLiveview.MessageView do
  @behaviour Ezagent.View

  def render(%Invocation{args: %Ezagent.Message{} = m}, _ctx) do
    %{type: :bubble, sender: m.sender, body: m.body, mentions: m.mentions, ts: m.inserted_at}
  end

  def render(%Invocation{
    target: %URI{path: "/behavior/session_routing/set_default"},
    args: args,
    ctx: ctx
  }, _) do
    %{type: :system, text: "#{short(ctx.caller)} set default to @#{args.agent}"}
  end

  def render(%Invocation{} = inv, _) do
    %{type: :system, text: "(#{inv.target |> short})"}
  end
end
```

LiveView template 根据 `%{type: ...}` 不同分支渲染气泡 vs 系统消息。

#### D.1.5 Routing rules 可视化(side panel)

每条 rule 显示为:`<matcher pretty-print> → [<receivers>]`。点击可编辑或删除(走 SessionRouting Behavior)。matcher pretty-print:

```
always()                                    →  always
mention("A")                                →  @A
mention("B") and from_member(:user)         →  @B + from user
from_external(:inbound)                     →  external inbound
```

DSL 反向渲染由 `Ezagent.Routing.Matcher.to_string/1` 提供(~10 LOC,递归 walk AST)。

### D.2 CLI

Plugin: **`esr_adapter_cli`**(独立 OTP app)
Target LOC: **~200**
依赖: `:optimus`、`:owl`(Elixir rich CLI rendering)、`:phoenix_gen_socket_client` or 类似

#### D.2.1 调用形态

```bash
# Inspect
$ esr-cli inspect session://feishu-cc/cc-7f3a
session://feishu-cc/cc-7f3a (Ezagent.Session.Feishu2CC)
  members: [pty, user://allen, agent://arch-a, agent://arch-b]
  rules: 9 active
  last_activity: 32s ago

# Attach (interactive)
$ esr-cli attach session://feishu-cc/cc-7f3a
[connected as user://allen]
[09:23] @allen: hello @arch-a
[09:23] @arch-a: let me see...
[09:24] @arch-a: pong
─── allen set default to @arch-a ───
> _

# One-shot invocation(脚本用)
$ esr-cli call agent://arch-a/behavior/chat/inbox_append \
  --args '{"body": "drive-by ping"}'
{:ok, "msg://..."}
```

#### D.2.2 Render 形态

CLI 实现 `Ezagent.View` behaviour,渲染到 ANSI:

```elixir
defmodule EsrAdapterCli.MessageView do
  @behaviour Ezagent.View

  def render(%Invocation{args: %Ezagent.Message{} = m}, _) do
    IO.ANSI.format([
      :light_black, fmt_time(m.inserted_at), " ",
      sender_color(m.sender), "@", short(m.sender), ": ",
      :reset, highlight_mentions(m.body, m.mentions), "\n"
    ])
  end

  def render(%Invocation{target: target, ctx: ctx} = inv, _) do
    IO.ANSI.format([:light_black, "─── ",
      describe_invocation(target, inv.args, ctx), " ───\n"])
  end
end
```

#### D.2.3 跟 LiveView 同构

注意 `EzagentWebLiveview.MessageView` 跟 `EsrAdapterCli.MessageView` 是**同构 View module**——两者都 dispatch 同样的 `%Invocation{}`,只是渲染输出类型不同(HTML assigns vs ANSI iodata)。这正是 §12.7 描述的 View pattern——adapter 的对称面,通用 Invocation 渲染器。

未来加 Feishu/Slack adapter 时,各自实现一个 `MessageView`,渲染成 Feishu card / Slack block。**Behavior 代码完全不变**。

### D.3 LiveView 与 CLI 的同构映射

LiveView 跟 CLI 是同一个系统的两个 View;**用户输入和命令在两侧自动等价**。这不是凑巧——它是 §6.2 `@interface` 强制 schema 的直接副产品。

#### D.3.1 等价的例子

| LiveView 输入 | CLI 输入 | 内部 Invocation |
|---|---|---|
| `/agent:set-default A`(slash command) | `esr agent set-default A` | `dispatch(target=session_routing/set_default, args={agent: "A"})` |
| 点击 "+ rule" 按钮填表单 | `esr rule add --matcher 'mention("B")' --to agent_b` | `dispatch(target=session_routing/add_rule, args={matcher, receivers})` |
| 输入框 `@arch-a hi`(自然 message) | `esr send @arch-a hi`(或 attach 模式直接输入) | `dispatch(target=chat/receive, args=%Message{...})` |
| 点击 "Invite Agent" | `esr session invite --template ...` | `dispatch(target=session_routing/invite, args=...)` |
| 点击某 agent 查 caps | `esr agent caps agent://...` | `dispatch(target=identity/list_caps, args={})` |

任何 LiveView 上的用户操作,都有对应 CLI 命令;任何 CLI 命令,都能在 LiveView 上找到 UI 对应。

#### D.3.2 为什么可以这样映射

每个 Behavior 声明 `@interface`——它就是该 Behavior 所有 action 的 schema(args / returns / errors / modes)。这一份声明,两侧 View **从同一个 source 自动派生 UI**:

```
@interface
   │
   ├── EzagentWebLiveview.SlashParser.compile/1   →  "/agent:set-default A" parser
   ├── EzagentWebLiveview.FormBuilder.compile/1   →  inline form / button
   ├── EsrAdapterCli.OptimusBuilder.compile/1 →  "esr agent set-default A" parser
   └── (未来) HTTP, MCP, ... 各自从同一份 @interface 派生
```

LiveView 没有"手写命令解析",CLI 没有"手写参数列表"——**两侧都是 `interface/0`(post-2026-05-28 由 `action/3` 宏自动派生)的渲染**。新增一个 Behavior 时,只需要写 `action :foo, args: ..., returns: ...` + `def handle_foo(args, ctx)`,LiveView 和 CLI **自动获得**该 Behavior 的所有 action,作为新的 slash command / CLI subcommand。

#### D.3.3 命名映射规则

LiveView slash 命令格式:`/<behavior-short-name>:<action>`,如:
- `/agent:set-default` → `Ezagent.ActionSet.SessionRouting.set_default`
- `/chat:send` → `Ezagent.ActionSet.Chat.send`

CLI 命令格式:`esr <behavior-short-name> <action>`(下划线/连字符互转):
- `esr agent set-default` ↔ `set_default` action
- `esr chat send` ↔ `send` action

`<behavior-short-name>` 由 Behavior 模块声明的 `@cli_name`(默认是模块名 snake_case 末段)决定,**两侧用同一份命名**。

#### D.3.4 自动挂载

CLI 命令**自动挂载**——无需 ops 手写命令清单。CLI plugin 启动时:

1. 通过 `BehaviorRegistry` 拿到当前 BEAM 内**所有已注册**的 Behavior
2. 读取每个 Behavior 的 `@interface` + `@cli_name`
3. 用 Optimus DSL 在内存里编译出一棵 subcommand tree
4. `esr --help` 显示所有可用命令

新装一个 plugin → 重启 CLI → 新命令自动可见。**没有需要 ops 维护的命令清单**。LiveView 同理——slash parser 编译时扫描注册表,新 Behavior 的 action 自动出现在 slash 自动补全里。

#### D.3.5 这一映射的隐含价值

| 价值 | 具体表现 |
|---|---|
| **可写脚本** | 任何 LiveView 操作都能用 CLI 一行复现,写 shell 自动化无障碍 |
| **可远程演示** | 直播写一遍 CLI 命令,观众在 LiveView 上看到等价效果,文档同步性强 |
| **可教学** | "试一下点这个按钮" 和 "试一下跑这条命令" 是同一件事,两种学习路径并存 |
| **可调试** | LiveView 不工作时,CLI 直接复现路径,排除前端问题 |
| **可压测** | CLI 写循环刷 1000 个 message,LiveView 实时看效果 |

这种"多 View 同源"是 OpenAPI 类比的直接收益——`@interface` 是 operationId schema,每个 View 都是它的一种渲染。新增 View(未来:HTTP REST / MCP tool / 自定义 TUI)都遵循同一个模式。

### D.4 用 LiveView 验证 spec 的几个关键点

v0 期 LiveView IM 起来后,以下 spec 决策都能在浏览器里立即看到效果——这正是为什么 v0 优先做 LiveView 而不是先接 Feishu。

| 验证项 | LiveView IM 能看到什么 |
|---|---|
| `@interface` 自动生成 form 跟 slash parser 是否好用 | 输入 `/set-default<TAB>` 是否能补全;form 表单字段是否准 |
| Message identity invariant | 同一条 message 转发多次,渲染应该一致;ref 指向旧消息能跳转 |
| Routing rules additive 语义 | side panel 显示所有 rule,新加一条不影响已有 |
| n×n routing | @B 时确认 A 也收到 |
| CapBAC | 没 cap 的 action 在 UI 上灰显;点击给 "forbidden" toast |
| Cross-cutting Behavior attach | attach `AuditLog` plugin 后,UI 立即出现 audit timeline |
| Snapshot persistence | 重启 BEAM,session 状态恢复;message 历史从 messages 表读出 |

LiveView 起来后,**第一个 sprint 应该跑通 §3-§7 全部决策**,任何不对劲都会立刻 surface 出来。LiveView IM 作为产品也会延续到 v0 之后,跟 Feishu/Slack/CC channel 并列。

---
