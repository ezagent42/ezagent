# Handoff 3/4: 应有的概念关系 + 差距

> **Date:** 2026-07-01 · **From:** jjkysy (FP5) · **To:** Allen (lead) + 独立 dev（human + cc/codex）
> **Base:** 干净 upstream/main @ 62820c38（含 A#1117 World UI-surface substrate，已 merge）
> **系列:** app/socialware 收口 4 文档之三（1=使用流程 · 2=现有概念代码实情 · **3=本篇** · 4=实现路径）
> **一句话:** 承接文档 2（现有概念在代码里长什么样、乱在哪），本篇画出"该长什么样 + 差多少"——对照文档 1 的使用流程，接在原语层之上的**全部概念**（不止 plugin/agent/app/socialware/workspace/session 这六个顶层产品概念，中间还有一整层）该怎么分层、怎么组装，离**实现**还差什么、为什么会乱，每条断言带 `file:line`。怎么分步建留给文档 4。

---

## 0. 这篇解决什么

文档 1 讲了"平台该怎么被用"（建 agent → 打包成 app → 发布 → 别人用又是新沙盒）。文档 2 讲了"现在代码里这些概念长什么样、哪里乱"。本篇夹在中间，回答一个具体问题：

> **要支撑文档 1 那套流程，从原语到产品，一共有哪些概念、怎么分层、怎么向上组装？摆好之后，跟现在代码的距离有多大、缺口在哪？**

**重点提醒**：顶层的 plugin / agent / app / socialware / workspace / session 只是**最上层的产品概念**。它们不是直接搭在原语（Kind/Behavior/URI/dispatch/CapBAC）上的——**中间还有一整层概念**（flavor、recipe、behavior set、cap、template、socialware definition、installation、ConfigObject、channel/adapter、feed/Surface、anon user…）被跳过了。这一层才是"产品概念怎么用原语拼出来"的真正黏合剂。本篇把三层都画全。

结论先给（后面逐条证）：**原语层 + 中间概念层基本齐了，缺的是最顶上一层"app package"抽象**——一个能把中间概念（recipe / data / view / public_face）统一声明起来的产品单元。代码里根本没有它（`grep -rn AppPackage apps/` 返回空）。

---

## 1. 三层概念地图（总览）

自底向上三层。**下层是砖，中层是把砖砌成的构件，上层是用构件拼出来的产品。**

```
┌─ 第三层 · 产品 / 组合概念（面向"用平台的人"）────────────────────────┐
│  workspace   app package(待建❌)   session   socialware facet   agent   plugin  │
└───────────────────────────────▲──────────────────────────────────────┘
                                 │  中层概念向上组装成产品概念
┌─ 第二层 · 中间概念（原语之上、产品之下 —— 本篇重点补齐）─────────────┐
│  Kind 类型(Agent/Session/User/Workspace/Template/Resource)                    │
│  flavor    recipe/role    behavior set + mount/detach    capability/cap        │
│  template    socialware definition    installation/installs                    │
│  ConfigObject/ConfigStore    channel/adapter(push/pull)    feed/Surface/view    │
│  anon user / public_view    routing(会话层)    umbrella boot    agent-contract   │
└───────────────────────────────▲──────────────────────────────────────┘
                                 │  中层概念全部踩在原语上
┌─ 第一层 · 原语（最底，plugin 作者绕不过）──────────────────────────┐
│  Kind        Behavior        URI        dispatch        CapBAC                  │
└──────────────────────────────────────────────────────────────────────┘
```

下面三节逐层展开，每个概念**一句话定义 + `file:line`**。

---

## 2. 第一层 · 原语（primitives）

系统的最小构件，plugin 作者绕不过。产品概念全部最终踩在这五个上。

- **Kind** —— "一个 URI 对应一个进程"。每个可寻址实体背后是**唯一一个 GenServer**（`Ezagent.Kind.Server`），用 `use Ezagent.Kind, pattern: ...` 声明（`apps/ezagent_core/lib/ezagent/kind.ex:629`）。这是 ezagent 跟普通 Phoenix app 最大的区别：不是"请求来了起临时进程处理完就走"，而是"每个实体是常驻 actor"。（易混淆：这是 ezagent Kind，不是别的。）
- **Behavior** —— "动作处理器"。一个 Behavior 模块声明若干 `action`，每个 action 带 `required_caps`（要什么能力才能调）。plugin 作者写业务逻辑的地方。（易混淆：`Ezagent.Behavior`，不是 Elixir 的 behaviour callback 契约。）
- **URI** —— "寻址"。每租户 scheme（`entity`/`session`/`template`/`resource`）强制 `<workspace>/<type>/<name>` 三段权威，`apps/ezagent_core/lib/ezagent/uri.ex:515`（`@unified_per_tenant_schemes`）；缺 workspace host 直接 raise（uri.ex:522 附近，防跨租户越权）。
- **dispatch** —— "Kind 之间**唯一**的入站路径"，`Ezagent.Router.dispatch/1`（`router.ex`）→ `Ezagent.Invocation.dispatch/1`（`invocation.ex`）。设计原则 P14。**不许** `PubSub.broadcast` 抄近路到 inbound topic（事故 2.1 根因）。（易混淆：ezagent dispatch，不是 Phoenix.Router 的 HTTP dispatch。）
- **CapBAC**（Capability-Based Access Control，基于能力的访问控制）—— "能力门控"。每个 action 声明要什么 cap，调用方必须持有对应能力令牌才放行。核心模块 `apps/ezagent_core/lib/ezagent/capability.ex`、`capability_registry.ex`。

**为什么 dev 要先记这层**：文档 1 说"app 里一切操作是 chat + 权限门控"——落到代码就是"一切是一条 dispatch，每条 dispatch 过 CapBAC"。不是新造的机制，是原语层本来就有的。

---

## 3. 第二层 · 中间概念（原语之上、产品之下）

**这一层是本篇要补齐的重点**——顶层六个产品概念不是直接搭在原语上的，中间靠这一堆构件黏合。逐个来（定义 + `file:line`）：

**Kind 类型（具体 Kind 声明）** —— 原语 Kind 是"机制"，中层是它的**具体类型实例**：
- **Entity.Agent** —— agent 的 Kind（员工进程），`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex`。
- **Session** —— 会话/房间的 Kind，`apps/ezagent_domain_session/lib/ezagent/entity/session.ex`。
- **User** —— 人/匿名身份的 Kind，`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`。
- **Workspace** —— 租户边界的 Kind，`apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex`。
- **Template / Resource** —— 模板与资源，作为每租户 scheme 存在于 `uri.ex:515` 的 `@unified_per_tenant_schemes`（`template`/`resource`）。
> 一句话：`entity://<ws>/agent/<名>` 背后是 Entity.Agent Kind，`session://<ws>/<名>` 背后是 Session Kind——**URI scheme ↔ 具体 Kind 类型**的对应就在这层。

**flavor（引擎宿主 —— agent 怎么跑）** —— "同一个 agent 配方，用哪个引擎把它跑起来"。plugin 通过 `agent_flavors/0` 声明：`curl`（`apps/ezagent_plugin_curl_agent/lib/ezagent_plugin_curl_agent/application.ex:109`）、`py`（`apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:103`）、`native`、`cc`/`cc-headless`（cc plugin）、`codex`/`codex-remote`（codex plugin）、hello builder（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:64`）。Allen 原话："HOW the sandbox is loaded is the FLAVOR"（`apps/ezagent_core/lib/ezagent/agent/recipe.ex:6`）。

**recipe / role（agent 配方 = 数据）** —— "一个 agent 该装什么内容"（skills、plugins、system-prompt persona、可选 script）。flavor 无关，纯数据。`Ezagent.Agent.Recipe`（`apps/ezagent_core/lib/ezagent/agent/recipe.ex:1`，由 `Ezagent.Role` 改名而来，#127）。存成 ConfigObject，`config://<ws>/recipe/<名>` 可寻址，经 `Ezagent.Agent.RecipeRegistry` read-through 解析（`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex:3`）。Allen 原话："The CONTENTS of the sandbox are the RECIPE"（recipe.ex:6）。plugin 通过 `roles/0` 声明自带哪些 recipe。

**behavior set + mount/detach（行为组合）** —— "一个活着的 Kind 实例当前挂了哪些 Behavior、某个 action 由谁处理"。解析在 `Ezagent.Kind.BehaviorSet.resolve_action/3`（`apps/ezagent_core/lib/ezagent/kind/behavior_set.ex:262`）。**per-instance 运行时挂载/卸载**（RF-2/RF-3）在 `apps/ezagent_core/lib/ezagent/kind/mount_detach.ex:1`（moduledoc："runtime per-instance behavior MOUNT + DETACH on a LIVE Kind"），入口 `Ezagent.Kind.mount/3`（`kind.ex:535`）/ `detach/2`（`kind.ex:561`）；改动写进持久化的 `:kind_base`，冷重启由 `BehaviorSet.effective_set/2` 复原。**这是"往一个会话/agent 里装一组能力"的底层机制。**

**capability / cap（能力轴）** —— CapBAC 里被门控的"能力令牌"本身。`Ezagent.Capability`（`apps/ezagent_core/lib/ezagent/capability.ex`）+ `Ezagent.CapabilityRegistry`（`capability_registry.ex`）。materialize 一个 agent 时**授权 + 铸造**它的 caps：`Ezagent.Agent.Recipe.CapMint`（`apps/ezagent_core/lib/ezagent/agent/recipe/cap_mint.ex:1`，moduledoc："Fail-closed cap authorization + minting for role materialization"）。文档 1 里"invite 要注册权限""公开面只能看不能改"全靠这条轴。

**template（模板 —— 凭证 vs 非凭证）** —— "一个可 fork 的实例模板"。两类：
- **SessionTemplate**（`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`）—— 定义一个会话该长什么样（含 `installs` 字段，见下）。
- **AgentTemplate（引擎侧，常带凭证/config_dir）** —— cc（`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`）、codex（`apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex`）、py（`apps/ezagent_plugin_py/lib/ezagent/template/py_agent.ex`）。recipe 是"内容"，template 是"可 fork 的 `template://<ws>/role/<名>` 载体"（recipe.ex:9）。

**socialware definition（一个可寻址的公开面配置）** —— "一份 socialware 定义"，`config://<ws>/socialware/<名>` 存成 ConfigObject（key `"socialware"`），经 `Ezagent.Socialware.DefinitionRegistry` 解析（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:29`）。它打包一组 behaviors + `visibility_policy`（谁能匿名看）。跟 recipe 同套路（definition_registry.ex:6 明写 "mirroring role-as-data's `config://.../recipe/...` pattern"）。

**installation / installs（把 definition 装进 session）** —— "安装机制"。`SessionTemplate.installs: [String.t()]`（session_template.ex:53，注释叫它 "the P3/P4 socialware composition field" session_template.ex:761）列出要装哪些 socialware definition；物化时 `Ezagent.Socialware.Installation`（`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`）把每个 definition 的 behavior union **织进** session 的 `:kind_base`（installation.ex:6-7），并写 per-session ConfigObject。默认 `["chat"]`（installation.ex:12）。**是个 list——天生能装多个。**

**ConfigObject / ConfigStore（配置治理层）** —— "可寻址配置数据的统一存储 + 治理"。recipe / socialware definition / per-session install 记录全部落成 ConfigObject 存进 ConfigStore。`Ezagent.Socialware.ConfigObject`（`apps/ezagent_domain_identity/lib/ezagent/socialware/config_object.ex:1`）、`Ezagent.Socialware.ConfigStore`（`config_store.ex:1`）。RecipeRegistry / DefinitionRegistry 都是它的 read-through 解析器（recipe_registry.ex:3）。**这是 `config://` scheme 背后的持久层。**

**channel / adapter / external-mirror（跟外部世界通消息）** —— 这里要分清**三个不同层**（常被混成一个）：
- **external-mirror = 底层基础设施 domain（机制，不是 plugin）**：`apps/ezagent_domain_external_mirror`（`ezagent_domain_*`，**无 `use Ezagent.Plugin`**），moduledoc 自称 "facade for the ExternalMirror Domain"（`external_mirror.ex`）。它是**出站镜像的唯一 owner**——一套通用机制（`AdapterRegistry` + `BindingRegistry` + Publisher 契约 + bind 4-gate）管"会话内容怎么镜像到外部"。**它跟 dispatch / CapBAC / Surface 同层（底层原语/基础设施），不属于任何 plugin，是 plugin 复用的地基**（像"邮局系统"，不属于任何寄信的公司）。
- **channel = plugin（第 3 类·渠道，跟 kanban 平级只是不同类）**：feishu（`apps/ezagent_plugin_feishu/`，**有 `use Ezagent.Plugin`**）、email（同）——外部消息进来变成 dispatch。**channel 不是"external-mirror 的外化"，channel 就是 plugin；它跟 kanban 是同级不同类。**
- **adapter = channel plugin 经契约 `adapters/0` 插进 external-mirror 的"插头"（声明）**：plugin 声明一对 `{Adapter, Binding}`（`plugin.ex:232` `@callback adapters`；email `application.ex:65` `def adapters, do: [{Adapter, Binding}]`），boot 时注册进 external-mirror 的 `AdapterRegistry`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`）。push/pull 两轴（P12 adapter pattern：协议相关代码只在 adapter 里）。
> **注意**：socialware 的公开 feed **本身就是 external-mirror 的一个 `:pull` adapter**（`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed_adapter.ex:37` `@behaviour Ezagent.ExternalMirror.Adapter` / `:63` `adapter_kind, do: :pull`）——即 socialware 公开交付**复用**了 external-mirror 这套底层机制，不是自己造的。**这正是下面 §5.3 要点的"底层 registry + 上层声明"同构模式的又一实例。**

**feed / Surface / view（交付 + 渲染）** —— "把会话内容渲染出来、投给外部"：
- **Behavior.Surface** —— 共享的 page surface 渲染原语，拥有 `:surface` slice；内部读者看最新版，外部读者只看 `:approved` 指向的版本（`apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex:1`，moduledoc 说明内/外读者差异 surface.ex:5-6）。
- **ExternalFeed / ChatFeed** —— 只读投影交付（`external_feed_adapter.ex`、`apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed.ex`）。
- **@json-render** —— 前端渲染（`apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs` 等）。
> 一个 app 的"视图"现在横跨这三处，**无统一声明**（文档 2 已指出）。

**anon user / public_view（匿名身份 + 公开访问门）** —— "让匿名访客能看公开面"：
- **anon user** —— mint 一个只读匿名 `entity://<ws>/user/<名>` 加入公开会话（`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex`）。
- **public_view** —— 匿名 web 访问 gate，是否放行看 definition 的 `visibility_policy.web_anon_access`（`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:3`）。

**routing（路由/接力 —— 会话层，非 agent）** —— "一条消息该发给谁"。经 `Ezagent.Routing.Resolver`（`apps/ezagent_core/lib/ezagent/routing/resolver.ex:68`，纯函数 `(msg, session_uri, members)→recipients`）按 `Ezagent.RoutingRegistry`（`routing_registry.ex`）里的规则算出收件人；配 `Routing.Matcher` / `Routing.Legend`。**关键更正**：routing **挂在会话（session）上、不是 agent 上**——`Behavior.Routing` 的 instance 是 `<workspace>/<session>/<system>` 三级（`apps/ezagent_core/lib/ezagent/behavior/routing.ex:38/40/42`），由会话调 Resolver（`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:516`），Entity.Agent 的 behaviors 里**没有** Routing。agent 是路由的**对象**（规则里的 sender/recipient），不 own routing。改规则 = dispatch 一个 `Behavior.Routing` action 到拥有规则的 scope Kind（Workspace/Session/System）+ CapBAC（PR #146 / SPEC v2 §5.7 已 **dissolve** 旧的 `routing-admin://default` 合成单例 Kind + `Behavior.RoutingAdmin`，泛化成挂在三个 scope Kind 上的 `Behavior.Routing`，`apps/ezagent_core/lib/ezagent/behavior/routing.ex:5-12`）。app 层说的"agent 接力"= app package 的 `routing:` 字段，realized 在 session 层。

**umbrella boot（启动）** —— "app 声明的东西怎么变成 live"。OTP app start → `Ezagent.Plugin.boot(__MODULE__)`（`apps/ezagent_core/lib/ezagent/plugin.ex:417`）注册 plugin 的 kinds/behaviors/flavors/roles → `after_boot/0`（`plugin.ex:293`）种默认 agent + **把 durable 路由规则 hydrate 进 live RoutingRegistry**（G1-b `be6c59f4`）+ reap 孤儿 + load workspaces。boot **顺序**有讲究。**连接点**：路由规则在 boot 时 hydrate——boot 就是"app 声明的 routing 变成 live"的那个地方。

**agent contract / AgentManifest（agent 工具契约）** —— "这个 agent 有哪些工具"的清单，含 versioned artifact pin + ledger 跟踪 `migrate_session`。`Ezagent.AgentManifest`（`apps/ezagent_core/lib/ezagent/agent_manifest.ex:1`）+ `.Tools`（`apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex:1`）+ CLI facade `EzagentCli.AgentManifestFacade`（`apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex:1`），用于 `spawn_from_manifest`。**跟 recipe 区别**：recipe=角色配置 bundle；manifest=工具/artifact 声明。一个 agent = recipe（配置）+ 可选 AgentManifest（工具契约）。

---

## 4. 中间概念怎么向上组装成产品概念

产品概念不是凭空来的，是中层构件拼出来的。三条主装配线：

**装配线 1 —— flavor + recipe (+ 可选 manifest) → agent（员工）**
recipe（配方=数据，`recipe.ex:1`）说"装什么内容"，flavor（`agent_flavors/0`）说"用哪个引擎跑"，CapMint（`cap_mint.ex:1`）授权它的 caps，物化出一个活着的 **Entity.Agent** 实例（`entity/agent.ex`），JOIN 进某个 session。**一个 agent = recipe（配置）+ 可选 AgentManifest（工具契约，`agent_manifest.ex:1`）**——前者定角色，后者定工具/artifact。→ 这就是文档 1 Step 1 的"建 agent 加入 session"。
> 注意 **routing 不在这条线上**：agent 只是路由的对象，routing 规则在 **session 层**组装（`resolver.ex:68` 被 `session.ex:516` 调，`Behavior.Routing` 挂 `<workspace>/<session>/<system>` 而非 agent）；app 层的"agent 接力"= app package 的 `routing:` 字段，realized 在 session。

**装配线 2 —— behaviors + socialware definition + installation → 装进 session（沙盒）**
socialware definition（`config://<ws>/socialware/<名>`，definition_registry.ex:29）打包一组 behaviors；SessionTemplate 的 `installs`（session_template.ex:53）列出装哪些；Installation 把 behavior union **mount 进** session 的 `:kind_base`（installation.ex:6-7 + mount_detach.ex:1 的 per-instance 机制）。`installs` 是 list，能装多个。→ 这就是文档 1 Step 2/4 的"打包安装成 app、一个会话装多个能力"的**现有底座**。

**装配线 3 —— Surface + feed + public_view + anon user → socialware facet（公开交付面）**
Behavior.Surface（surface.ex:1）渲染 + 版本门（内部看最新 / 外部看 approved），ExternalFeed（`:pull` adapter，external_feed_adapter.ex:63）只读投影交付，public_view（public_view.ex:3）当匿名访问 gate，anon_user（anon_user.ex）mint 匿名只读身份。四样合起来 = 一个 session 的**对外那一面**。→ 这就是文档 1 Step 3/7 的"发布公开面、公开 vs 非公开面区别"。

**顶层产品概念的最终形态**（这些是"用平台的人"直接打交道的）：
- **workspace** = 隔离边界/租户（≈公司），装多个下层单位（`workspace.ex`；URI 强制它当第一段 uri.ex:515）。
- **app package** = 产品单元（**待建 ❌**）：把上面三条装配线的"配方"统一声明起来——`uses:[能力 plugin]` / `agents:[recipe]` / `data:[slice+schema]` / `views:embedded+public` / `public_face:CapBAC policy`。
- **session** = app package 的运行实例 = 沙盒（Session Kind + dispatch + CapBAC + installs 织入）。
- **socialware facet** = session 开 public_view 后长出的公开交付面（装配线 3 的产物）。
- **agent** = recipe 的运行实例 = 员工（装配线 1 的产物），session 成员。
- **plugin** = 代码包/提供方（机制层），声明 `kinds/behaviors/agent_flavors/roles/config_surface`（`apps/ezagent_core/lib/ezagent/plugin.ex:198/199/208/212/242`），被 app package 的 `uses:` **引用**。

**顶层拥有/引用关系图**：
```
workspace  装多个 →
  ├─ app package(待建❌)  ── uses: → plugin(机制层，横在旁边被引用)
  │     实例化成 ↓
  ├─ session(沙盒)
  │     └─ socialware facet(公开交付面，可选)
  └─ agent(员工，session 成员)
```

---

## 5. 差距表（逐概念：现状 / 差距 / 依据）

对照 §3/§4 逐个核。**依据全部读干净 main `62820c38` 当前代码。**

### 5.1 原语层 + 中间概念层（大多 ✅）

| 概念（层） | 现状 | 依据（file:line） |
|---|---|---|
| Kind / Behavior / URI / dispatch / CapBAC（原语） | ✅ 全在 | `kind.ex:629`、`uri.ex:515`、`router.ex`→`invocation.ex`、`capability.ex` |
| Kind 类型（Agent/Session/User/Workspace） | ✅ 各 domain 有具体 Kind | `entity/agent.ex`、`entity/session.ex`、`entity/user.ex`、`entity/workspace.ex` |
| flavor | ✅ `agent_flavors/0` 多引擎 | `curl_agent/.../application.ex:109`、`py/.../application.ex:103`、`hello/.../application.ex:64` |
| recipe / role | ✅ role-as-data，可寻址 | `recipe.ex:1`、`recipe_registry.ex:3` |
| behavior set + mount/detach | ✅ per-instance 挂载完整 | `behavior_set.ex:262`、`mount_detach.ex:1`、`kind.ex:535` |
| capability / cap | ✅ mint/authorize 完整 | `capability.ex`、`cap_mint.ex:1` |
| template（凭证/非凭证） | ✅ SessionTemplate + cc/codex/py AgentTemplate | `session_template.ex`、`cc_agent.ex`、`codex_agent.ex`、`py_agent.ex` |
| socialware definition | ✅ 可寻址 ConfigObject | `definition_registry.ex:29` |
| installation / installs | ✅ 装 definition 进 session（list） | `installation.ex:6-7`、`:12`、`session_template.ex:53` |
| ConfigObject / ConfigStore | ✅ 配置治理层完整 | `config_object.ex:1`、`config_store.ex:1` |
| channel（plugin，第3类）/ adapter（声明）/ external-mirror（基础设施 domain） | ✅ 三层各就位：channel=plugin、adapter=经 `adapters/0` 声明的插头、external-mirror=底层 registry domain | channel `feishu/`、`email/adapter.ex`；adapter `plugin.ex:232`；external-mirror `adapter_registry.ex`（domain，非 plugin）；socialware feed=其 `:pull` adapter `external_feed_adapter.ex:37` |
| feed / Surface / view | ⚠️ 功能在，但**散三处无统一声明** | `surface.ex:1`、`chat_feed.ex`、`catalog_jsonrender.mjs` |
| anon user / public_view | ✅ 匿名身份 + 公开门完整 | `anon_user.ex`、`public_view.ex:3` |
| routing（路由/接力，**会话层非 agent**） | ✅ 纯函数 Resolver + 规则表 + admin 改规则 | `resolver.ex:68`、`routing_registry.ex`、`behavior/routing.ex:38/40/42`、`session.ex:516` |
| umbrella boot | ✅ boot 注册 + after_boot 种 agent + hydrate 路由规则 | `plugin.ex:417`、`plugin.ex:293`、G1-b `be6c59f4` |
| agent contract / AgentManifest | ✅ 工具/artifact 声明 + CLI facade | `agent_manifest.ex:1`、`agent_manifest/tools.ex:1`、`agent_manifest_facade.ex:1` |

**小结**：原语层全 ✅；中间概念层**几乎全 ✅**，唯一不齐的是 **view 基座散三处（Surface / feed / @json-render）无统一声明**——这不是缺功能，是缺"统一声明它们的口子"，正好由缺失的 app package 承接。

### 5.2 产品概念层

| 概念 | 现状 | 差距 | 依据（file:line） |
|---|---|---|---|
| **plugin** | ✅ 契约完整（六类声明） | 无功能差距；认知上要区分"能力 plugin（纯机制）"vs"被误当 app 的 plugin（hello/kanban 混了配方+工具）" | `plugin.ex:195/198/199/208/212/242`；默认实现 `:281-293` |
| **agent** | ✅ 完整（装配线 1 产物） | 无 | `entity/agent.ex`；create 入口 `workspace.ex:768` |
| **workspace** | ✅ 完整（隔离+成员+create） | 无 | `workspace.ex`；URI 强制 host `uri.ex:515-524` |
| **session** | ✅ 完整（Session Kind + dispatch + CapBAC + installs 织入），沙盒语义已在 | 无核心差距；"每次使用=新沙盒"的确切语义待 Allen 拍板（现匿名是 mint anon 进公开会话） | Session Kind `ezagent_domain_session`；织入 `installation.ex:6-7`；匿名 `anon_user.ex` |
| **socialware facet** | ✅ 公开交付面完整（装配线 3） | 命名混三义（见文档 2 §②），应降级为 app package 的一个 facet；P5 后本域已不拥有 session Kind（standalone socialware-session Kind 已删），佐证它只是切面 | 公开门 `public_view.ex:3`；Kind 已删 `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:20-22` |
| **app（package）** | ❌ **无统一概念** | **最大差距**：`grep -rn AppPackage apps/` 返回**空**；最接近的 `SessionTemplate.installs` **只能装 socialware definition（=一组 behaviors）**，缺把中间概念 `recipe(agents) / slice+schema(data) / Surface+feed(views) / cap policy(public_face)` **统一声明**起来的东西；也没有 install/publish/compose 生命周期接口 | `grep AppPackage`=空（已核 `62820c38`）；`installs` 只装 definition `session_template.ex:50-53`、`:761`；织入只 behavior union `installation.ex:6-7` |

**差距浓缩成一句**：原语 5 个 ✅，中间概念 12 个里 11 个 ✅（view 基座待统一）；顶层产品概念里 plugin/agent/workspace/session 四个 ✅，socialware ✅ 但命名降级；**只有 app package 是 ❌ 从零——它是唯一真正的建设缺口。**

---

## 5.3 为什么现在会"看起来都像"——三个结构性根因

顶层缺 app package 只是**表面**。往下挖，"plugin / socialware / SessionTemplate / recipe / manifest 看起来都像同一种东西"，是三个结构性问题叠出来的：

**根因 1 · 中间层"声明"概念被点状复制了 5 次（增殖）**——"声明一份配置数据→物化成运行时"这一个模式，被独立实现了至少 5 次（recipe / socialware definition / SessionTemplate / AgentTemplate / agent manifest），各为一个目标却各造一套。**逐个 file:line 的事实表见文档 2 §④问题4，本篇不重列**；这里只用它当根因：代码自己都承认是复制（`definition_registry.ex:6` 明写 definition "mirroring role-as-data's `config://.../recipe/...` pattern"），recipe 有 RecipeRegistry、definition 有 DefinitionRegistry 两个几乎一样的 read-through resolver。**它们"看起来都像"，是因为本来就是同一个模式被抄了 5 遍。**

**根因 2 · 底层→中间的映射不一致**——同样一份"声明"，落地各不相同、无统一规则：recipe/socialware definition→ConfigObject（`config://<ws>/<type>/<名>`）；SessionTemplate/AgentTemplate→template Kind+struct（`template://`）；agent manifest→自成一个模块。三种声明三种落地，没有"一份声明 = 一个 `config://<ws>/<kind>/<名>` 的 typed ConfigObject"这样的统一规则。**后果**：没法统一寻址/版本化/存储"一份声明"，自然没法统一声明"一个 app 由哪些声明组成"。

**根因 3 · 中间→产品的装配没有统一契约**——§4 三条装配线是三条独立临时的路。唯一像装配器的 `installs`/`Installation` 只装 socialware definition（behaviors）那一条（`installation.ex:6-7`）；recipe→agent 是另一条 materialize 路、view 散四处、public_face 靠 definition 的 visibility_policy。**没有一个地方能说"一个产品 = 这些声明按这套规则装起来"**，所以 app package 无处安放。

**旁证 · "底层 registry + 上层声明"是全系统反复出现的同构模式**——不只前面 5 个"声明→物化"概念，连基础设施层也是同一形状：**routing** = `RoutingRegistry` ← routing rule；**external-mirror** = `AdapterRegistry` / `BindingRegistry` ← adapter decl（channel plugin 经 `adapters/0` 声明）；**installs** = InstallCatalog ← socialware definition；连 socialware 公开 feed 都是 external-mirror 的一个 `:pull` adapter 声明。干净 main 上这类各自为政的 registry 一共有 6 个（**逐个 file:line 详见文档 4 §2 基座缺口表**，本篇不重列）。三处都是"一个底层 registry + 一堆各自为政的上层声明"，**同一个形状被实现了这么多遍却没抽象出来**——这更坐实了根因 1/2：系统缺一个统一的"声明 + 注册 + 物化"抽象，于是每个子系统各造一套 registry + 各定一种声明格式。app package 要做的，正是在这团同构碎片之上盖一层统一声明。

**三根因串起来**：声明增殖（根因1）+ 落地不一致（根因2）→ 没法统一寻址声明 → 没法统一装配（根因3）→ app package 无处安放 → 想指"一个 app"只能抓 5 个替身之一 → "看起来都像"。**所以"补一个 app package 容器"只治标；治本三步**：① 统一"声明"概念（一份声明=一个 typed ConfigObject at `config://<ws>/<kind>/<名>` + 一套参数化 registry，收敛 RecipeRegistry/DefinitionRegistry）；② 定义装配契约（manifest 引用一组声明 + 泛化的 installer 把它们一起装进 session，把 `installs` 从"只装 definition"泛化到"装全部声明"）；③ app package 就是"manifest+installer"自然落出来的，不是硬造容器。

---

## 6. 结论

**缺 app package 是表面，根子是 §5.3 的三个结构性问题（声明增殖 / 映射不一致 / 装配缺契约）。** 把三层叠起来看，结论很清爽：

**原语层 + 中间概念层已经支持文档 1 流程的大部分。** 具体地——

- "一切操作是 chat + 权限门控" → **dispatch（P14）+ CapBAC/cap（cap_mint.ex）** 已在。
- "建 agent" → **flavor + recipe + CapMint → Entity.Agent**（装配线 1）已在。
- "打包安装、一会话装多个能力" → **socialware definition + installs(list) + mount/detach**（装配线 2）已在。
- "开公开面给匿名看" → **Surface + feed + public_view + anon user**（装配线 3）已在。
- "配方/definition 可寻址" → **`config://` + ConfigObject/ConfigStore** 已在。

**缺的只有最顶上一层：app package 抽象。** 现在没有一个产品单元，能把中间概念里的 `recipe(agents) / data(slice+schema) / views(Surface+feed+@json-render) / public_face(cap policy)` **统一声明**在一处——`SessionTemplate.installs` 只覆盖了 behaviors 那一条，其余散着；也没有 install/publish/compose 三个动作的标准接口。顺带，view 基座（Surface/feed/@json-render）散三处，正好由 app package 的 `views` 声明来收口。

**给 Allen 的一句话**：不是要重造轮子——原语五块砖 + 中间概念一整层构件都齐了（flavor/recipe/behavior-set/cap/template/definition/installs/ConfigStore/adapter/Surface/public_view），缺的是**给它们盖一个统一的 app package 声明 + 一套生命周期接口**，把散落的中间概念统一表达起来，顺带把 socialware 的"一名三义"降级成一个 facet。**下一篇（文档 4）讲怎么分步把这层砌上去。**
