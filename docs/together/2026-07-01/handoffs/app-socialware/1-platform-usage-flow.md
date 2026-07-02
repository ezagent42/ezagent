# Handoff 1/4: ezagent 平台怎么用

> **Date:** 2026-07-01 · **From:** jjkysy · **To:** Allen (lead) + 独立 dev（human + cc/codex）
> **Base:** 干净 upstream/main @ 62820c38（含 A#1117 World UI-surface substrate，已 merge）
> **系列定位:** 这是「app / socialware 收口」4 文档系列的**第 1 篇**（起点）。主题 = **一个用户怎么用 ezagent 这个平台去开发 / 安装 / 发布 / 使用一个 app**（下称"平台使用全流程"）。第 2-4 篇顺序推进：2=现有概念的代码实情、3=应有的概念关系 + 差距、4=实现路径。本篇只讲**流程本身**（要什么），把每一步"谁参与、想干嘛、期望拿到什么、代码里现在有没有、举例长什么样"讲透，作为下游 spec/build 的产品输入；概念代码实情、概念地图、实现分步分别留给 2/3/4，本篇不展开。

---

## 0. 先说清楚三个基础词（后面反复用，第一次在这里解释）

ezagent 是一个**消息路由运行时**（把多个渠道的消息路由给多个 agent 编排），不是普通的"请求-响应"网站。它有几个自造词，用错了整篇会读歪：

> （下表只给朴素定义；"公司 / 部门 / 员工"这套帮助分层的比喻集中在 README §0.5，本篇不重复。）

| 词 | 在 ezagent 里指什么 | 朴素说明 |
|---|---|---|
| **workspace（工作区）** | 租户 / 隔离边界，`workspace://<名>` | 一个隔离边界，里面装 agent、session、app |
| **agent** | 一个会干活的实例，`entity://<ws>/agent/<名>` | 可寻址的干活实例 |
| **session（会话）** | 一个 routing room（路由房间），`session://<ws>/<名>` | 一个路由房间 + 运行沙盒，成员（人 / agent）在里面收发消息 |
| **dispatch（分发）** | Kind 之间**唯一**的入站路径，`Ezagent.Router.dispatch/1` → `Ezagent.Invocation.dispatch/1` | 平台里"所有操作"都是一条被投递的消息，不是直接函数调用（设计原则 P14） |
| **CapBAC** | 能力门控（capability-based access control） | 每个动作声明它需要哪张能力令牌才放行 |
| **plugin（插件）** | OTP 代码包 / 能力提供方，声明 kinds/behaviors/flavors/roles/config_surface | 机制层的能力提供方，不是 app 本身 |
| **socialware** | 一个 app 的**公开对外交付面**（public delivery facet） | 把一个会话开放给匿名网友看的那一面，**不是**一个上位 app 单元 |
| **recipe（配方，旧称 role）** | agent 的配方数据 | 一份 agent 配置数据，物化后变成一个 agent |
| **flavor（风味）** | agent 的引擎宿主（cc / codex / native / py / curl…） | agent 背后用哪个引擎跑 |

> ⚠️ 一个贯穿全篇的重点：**代码里目前没有一个统一叫 "app / app package" 的东西**（grep 实锤见文档 2 §④问题1）。现在被叫作 "app" 的（kanban、官网、hello…）分别是 plugin、seed 脚本、或者 `SessionTemplate` + socialware 定义拼出来的。所以下面每一步的"现状"里，凡是 ⚠️ 半 / ❌ 缺，几乎都指向同一个缺口：**缺一个统一的 app 抽象 + 生命周期接口**。这正是本系列要收口的东西。

**本篇两个例子贯穿全 7 步**（不是提一句，是走完整链路）：
- **例 A = kanban（现有 app）** —— 一个"团队看板"app：一个 pm-coordinator（协调员）+ 一个 kanban-manager（看板管理员），看板数据挂在 agent 上，24 个动作各带能力券。**它是"扁平"的：一个 session 里几个 agent 协作。**
- **例 B = 官网（嵌套 app，建在 PR #1118 §5.2 上）** —— 一个"含 hello 的 app"：hello 是"用一句话生成一个页面"的生成器；官网 = 让 hello 生成站点页面 → **开放成 socialware（公开匿名访问）** → 页面里**内嵌 kanban / github 能力**来实时反映开发进度。**它是"嵌套"的：一个 app 里嵌了别的 app 的能力 + 公开面。** 官网正是"嵌套 app"这个概念的活例子。

---

## 1. 平台全流程 7 步（每步：① 参与用户 ② 目的 ③ 期望得到 ④ 现状 ⑤ 举例）

### Step 1 — 建 agent，加入 session 聊天

- **① 参与用户：** 开发者（workspace 成员）。
- **② 目的：** 搭一个能干活的 agent，把它拉进一个会话里，开始聊天 / 干活。
- **③ 期望得到：** 一个 `entity://<ws>/agent/<名>`（可寻址的 agent），并且它已经 JOIN 了某个 `session://<ws>/<名>`。
- **④ 现状：✅ 有。** 入口是 Workspace Kind 上的 `:create_agent` 动作 —— `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:768` `create_agent(%URI{scheme: "workspace"}=workspace_uri, args, ctx)`。它不是直接建对象，而是走 `Router.dispatch(%Cmd{target: ..., action: :create_agent, ...})`（同文件 :776，符合 P14"一切经 dispatch"）。`args` 里带 recipe（岗位）+ flavor（引擎），dispatch 里做 CapBAC 校验（`ctx` 带 `:caller` + `:caps`，:773-774），然后按 flavor 物化出 agent。
  - **补充（recipe ≠ manifest，别混）：** 一个 agent 除了 recipe（配方 / 岗位）之外，还可以带一份 **agent contract / AgentManifest**（`apps/ezagent_core/lib/ezagent/agent_manifest.ex:1`，声明式的"工具清单契约"：`tools`（action / participant refs）+ `caps` + `soul` + `executor`（选一个或多个 flavor），CLI facade 在 `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex:1`，经 `Ezagent.Entity.Agent.spawn_from_manifest/6` 物化）。**两者不是一回事**：recipe 回答"这是什么角色 / 怎么配置"，manifest 回答"装了哪些工具、绑哪个引擎、要哪些券"（含把 tool ref pin 成 spawn-time 派生 artifact，见 `agent_manifest.ex:79-80`）。
- **⑤ 举例：**
  - **例 A（kanban）：** 建两个 agent —— 一个 `kanban-manager`（recipe = `kanban-manager` × flavor `native`），一个 `pm-coordinator`（recipe = `pm-coordinator`）。都 create_agent + join 到同一个团队 session。
  - **例 B（官网）：** 建一个 **hello builder**。⚠️ **注意与直觉不同**：hello builder **不是** "role × native flavor" 的普通 recipe agent，而是 hello 插件自带的一个**专用 Kind** `Ezagent.Entity.HelloBuilder`（type_name `:hello_builder`，`apps/ezagent_plugin_hello/lib/ezagent/entity/hello_builder.ex`），通过插件契约注册成一个 flavor `"hello_builder"`（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:64-72`）。它被直接 spawn 成一个 socialware session 的成员（见该文件 :84-88 注释）。

### Step 2 — agent 产出 → 符合条件安装成 app → 被 session load → 变成沙盒

- **① 参与用户：** 开发者。
- **② 目的：** 把"agent + 工具 + 数据 + 视图"打包成一个**可复用、可安装**的东西（一个 app），让任意 session 装上它就"变成正在用这个 app 的沙盒"。
- **③ 期望得到：** 一个 app，能被任意 session `load`；load 之后那个 session 就是"实际使用这个 app 的隔离运行环境"。
- **④ 现状：⚠️ 一半。** "装东西进 session"的机制**有**，但"agent 产出 → 打包成 app"这条流水**没有**，而且现在能装的只是 socialware **definition（一组 behaviors）**，不是完整 app（还应含 recipe / 数据 / 视图 / 公开面）。
  - 安装机制：`SessionTemplate`（会话模板，`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`）的 `installs` 字段声明"装哪些东西"。该字段类型 `installs: [String.t()]`（:53），注释 :50-52 写明"product/runtime install refs，P3 内置 `"chat"` 和 `"socialware"`，缺省保留 `"chat"`"。SessionTemplate 自我定义是"**production unit of multi-agent orchestration**"（多 agent 编排的生产单元，moduledoc :6）—— 它是目前"最接近 app 定义"的东西。
  - 物化（materialize）：`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex` —— moduledoc :5 "A SessionTemplate's `installs` field names ConfigStore-backed socialware definitions. Materialization writes a per-session ConfigObject record and threads the definitions' behavior union into the Session's `:kind_base`."（把 definition 里的 behaviors 联合织进这个 session 的 `:kind_base`，并写一条 per-session ConfigObject 记录）。默认装 `@default_installs ["chat"]`（:12）。
  - **缺口：** "agent 产出 → install 成 app"这条**没有**；`installs` 装的是 definition，不是"app package"。
- **⑤ 举例：**
  - **例 A（kanban）：** kanban app 理想上 = pm-coordinator 配方 + kanban-manager 配方 + board 数据 + 会话形态。**现状是散的**：kanban-manager 配方在 kanban 插件（见 Step 6），board 数据靠运行时挂在 agent 上，没有一个"kanban app"清单把它们绑一起。（pm/dev recipe 的归属见 C#1115 决策，属 app 配方治理、非本系列基座主题。）
  - **例 B（官网）：** hello app 理想上 = HelloBuilder 生成能力 + Surface 视图 + AI 生成。现状：hello 插件把 `Behavior.HelloBuilder` 的 `:receive` 钩子绑在 `Entity.HelloBuilder` Kind 上（`application.ex:105`），页面"只经 `Behavior.Surface.put_version/2` 诞生"（moduledoc :7-8），但**没有一个"官网 app"清单**统一声明"用 hello + 开公开面 + 嵌 kanban/github"。

### Step 3 — 发布 app → 生成地址 + 身份寻址

- **① 参与用户：** 开发者（发布者）。
- **② 目的：** 让这个 app 对外可用、可被寻址。
- **③ 期望得到：** 两样东西一次产出 —— (a) 一个**公开地址**（别人打开就能用）；(b) 一个**身份寻址**（在 ezagent 内部用 URI 找到这个 app）。
- **④ 现状：⚠️ 一半。** 两样都能拼出来，但**没有一个统一的"发布"动作**把它们一次产出。
  - 公开地址：`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex` —— moduledoc :3 "Anonymous web-access gate for installed socialwares"（已安装 socialware 的匿名网页访问闸）。判定入口 `web_anon_access?(%URI{scheme: "session"}=session_uri)`（:18），转发给 `Installation.web_anon_access?/1`，靠 socialware definition 的 `visibility_policy.web_anon_access` 字段决定这个 session 允不允许匿名看（moduledoc :5-8）。这就是"公开地址"落地面。
  - 身份寻址：socialware definition 住在 `config://<workspace>/socialware/<name>`（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:5`，`@definition_key "socialware"` :12，URI 构造 :29 `"config://#{workspace}/socialware/#{name}"`）。运行实例则是 `session://<ws>/<名>`。注意 `config` 是"跨切面 scheme"，不在每租户统一 scheme 白名单里（`@unified_per_tenant_schemes ~w(entity session template resource)`，`apps/ezagent_core/lib/ezagent/uri.ex:515`）—— 这条对 Step 3 的"app 该用哪个 scheme 寻址"是个悬而未决的设计点（本系列第 4 篇会提）。
  - **缺口：** 没有一个"publish app"动作把 (公开地址 + 身份寻址) 一次产出。
- **⑤ 举例：**
  - **例 A（kanban）：** kanban 通常给内部团队用，未必开公开面；但如果开，走的也是同一套 public_view。
  - **例 B（官网）：** 官网发布后，匿名网友打开公开地址就是它 —— 计划绑到 `app.ezagent.chat`（PR #1118 §1① 记："官网尚无独立域名，计划绑到 `app.ezagent.chat`，上生产前须与 Allen/T6 协调"）。当前真实渲染路径是 `/socialware/chat?session_uri=session://system/hello/site`（PR #1118 §1①）。hello 插件甚至有个 `HELLO_DEMO_SEED=1` 的启动种子，boot 时物化一个 `public_view` hello app，让匿名访客立刻在 `/socialware/chat` 看到渲染页（`application.ex:115-118`）。

### Step 4 — 一个 session 装多个 app，同时用多个 app 能力，再打包成新 app

- **① 参与用户：** 开发者。
- **② 目的：** 组合能力（app + app、或 app + agent → 新 app）。
- **③ 期望得到：** 一个会话里同时具备多个 app 的能力；并且能把这个组合**打包成一个新 app**。
- **④ 现状：⚠️ 一半（能多装，不能打包）。**
  - 能多装：`installs` 是一个 **list**（`installation.ex:12` `@default_installs`，`installs_from_template/1` :24 读出的是列表），所以一个 session 装多个 definition 是**有基础的**。
  - 不能打包："把这个组合 compose 成一个新 app"（composition）**没有** —— 因为压根没有"app"这个统一单元可打包。
- **⑤ 举例（这是"嵌套 app"的核心，重点看例 B）：**
  - **例 A（kanban）：** kanban session 里已经同时有 kanban-manager（看板机制）+ pm-coordinator（协调）+（可选）github 网关能力，算一种"多能力并存"，但它们没被打包成"一个 kanban app 单元"。
  - **例 B（官网 = 嵌套 app 的活例子）：** 官网 app = **含 hello（生成站点）+ 开放为 socialware（公开匿名）+ 内嵌 kanban / github 能力（反映开发进度）**。也就是"一个 app 里嵌了多个 app 的能力 + 一个公开面"。PR #1118 §5.2 的"门户助手·导航式副驾"就指向这个：官网对话框能把访客切到 world.cup 版块看真实 GitHub 进度数据（§5.2 grounding 锚三源之一 = "world.cup 真 GitHub 数据"）。**但"官网 app = hello + kanban + github + 公开面"这个组合现在没有清单能声明、更不能一键打包**，只能靠 SessionTemplate 装多个 definition + 脚本拼。这是本系列要收口的最大缺口。

### Step 5 — 别人用这个 app，使用过程自动又是一个新 session

- **① 参与用户：** 终端用户（可能是匿名网友）。
- **② 目的：** 每个使用者有自己隔离的运行上下文。
- **③ 期望得到：** 每次"打开用" = 一个新的 session 沙盒（数据隔离）。
- **④ 现状：⚠️ 部分（语义待 Allen 敲定）。**
  - 匿名访问会 mint（铸造）一个**只读匿名 User**：`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex` —— 它是 `Ezagent.Entity.User` Kind 的一个"匿名 flavor"，`entity://<viewed-workspace>/user/anon-<random>`，**构造即只读**（moduledoc :6-9）。`mint/1`（:65）经 `Ezagent.Users.create_read_only/1` 建 users 行，**不**给广义 session 基线 cap（moduledoc :25-29），所以它能靠 session 成员身份**读**，但一个 `chat.send` 会在 CapBAC 卡点（dispatch step 5.5）被拒（缺 session 写 cap）。它在"首次匿名打开一个 public_view 页"时铸造、join 进那个 session、48 小时后按 `last_seen_at` 被 GC（moduledoc :40-41）。workspace 段取"被看的那个 session 的 workspace"，所以匿名 User 永远跨不了 workspace（moduledoc :33-36）。
  - **待定点：** 现在的语义是"铸一个匿名 User 进那个**公开会话**"，不完全等于"**每个使用者一个全新沙盒 session**"。"每次使用 = 一个新沙盒 session"要 Allen 确认（这影响匿名生命周期 + composition 模型）。
- **⑤ 举例：**
  - **例 A（kanban）：** 团队成员是认证 User，进的是同一个团队 session（不是每人一个新沙盒），符合"团队共享一块板"的语义。
  - **例 B（官网）：** 匿名访客打开官网 → mint 一个只读 anon-User → join 进 `session://system/hello/site` 那一类公开会话 → 只能看 + 受限交互（投票之类），不能改站点内容。是否给每个访客开独立沙盒，取决于上面那个待定点。

### Step 6 — app 里一切操作 = chat；invite 等特定操作要注册（关 CapBAC）；运行时数据同理

- **① 参与用户：** app 内的 agent / 用户。
- **② 目的：** 统一交互模型（**一切皆消息**），特定操作受权限门控，运行时数据隔离存储。
- **③ 期望得到：** invite / 特定动作 = 一个"需要能力券"的 action；运行时数据有隔离存储。
- **④ 现状：✅ 完全对上架构。**
  - 一切皆消息：所有 inbound 都是 dispatch（P14），`workspace.ex:776` 的 create_agent、下面 kanban 的每个动作，都是一条被投递的 `%Cmd{}`。
  - 每个 action 声明它要哪张券：kanban 的每个动作在 recipe 里带一个 **cap-template map** `%{behavior:, action:}`（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:100-103`，`for action <- Ezagent.Behavior.Kanban.actions()` 逐个生成 requested_caps）。invite（邀请成员）就是这样"一个要 cap 的 action"。
  - 运行时数据隔离：kanban 的看板数据挂在 **per-session、per-agent** 的 slice 上，key = `:tree`（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/shared.ex:144` `tree(ctx), do: ctx[:read].(:tree, empty_tree())`，写回 :151 `commit(tree), do: {:set, :tree, ...}`）。插件作者只用 `ctx[:read]` 读、`{:set, key, value}` 写，看不到底层 slice/snapshot（符合 Behavior 契约）。
  - **agent 之间怎么接力（routing —— @某人到底谁转发）：** 一切既然都是消息，那"pm @dev 一句就把活派过去"这条也不是特例，靠的是**会话层的 routing**。一条 message 经 `Ezagent.Routing.Resolver`（`apps/ezagent_core/lib/ezagent/routing/resolver.ex:68`，纯函数 `(msg, session_uri, members) → recipients`）按 `Ezagent.RoutingRegistry`（`apps/ezagent_core/lib/ezagent/routing_registry.ex`，运行时规则表，`Resolver` 从这里取规则派收件人）里的规则算出收件人。**关键（一处常见误解的更正）：routing 挂在会话（session）上，不是挂在 agent 上** —— 是**会话**去调 Resolver（`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:516` `Ezagent.Routing.Resolver.resolve_with_ctx(...)`），`Behavior.Routing` 的 instance 也只有 **workspace / session / system 三级**（`apps/ezagent_core/lib/ezagent/behavior/routing.ex:38`（workspace）、:40（session）、:42（system）），`Entity.Agent` 身上**没有** Routing behavior。agent 只是路由的**对象**（规则里的 sender / recipient），它不 own routing；所以**单个 agent 默认不会接力**（没有规则 = 消息进会话后没人被 route 到）。改路由规则不是改 agent，而是对 scope-owning Kind dispatch 一个 `Behavior.Routing` action + CapBAC 卡点（dispatch step 5.5）——注意 PR #146 已把旧 `Behavior.RoutingAdmin` + 合成单例 `routing-admin://default` **dissolve 掉**，泛化成挂在上面三个 scope Kind 上（`routing.ex:5-12`）。用大白话说：**"谁 @谁能接力到谁"这件事，在 app 层就是 app package 的 `routing:` 字段**（realize 之后落在 session 上，而不是长在某个 agent 身上）。
- **⑤ 举例：**
  - **例 A（kanban）：** pm @dev 派活、`set_status`、`claim_node` 都是经 dispatch + CapBAC 门控的 action。其中 **pm @dev 派活 = 一条 relay 规则**（`from(pm) + in_session → [dev]`）经 Resolver 转发给 dev；dev 回传 pm 同理（一条 sender-locked 规则）。这两条规则**挂在这个团队 session 上**，不是长在 pm 或 dev 身上——换个 session 就没有它们。`Ezagent.Behavior.Kanban` 里用 `action(:...)` 宏声明动作（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`，含连接器动作：`add_node / rename_node / move_node / remove_node / set_stage / claim_node / unclaim_node / set_status / attach_artifact / detach_artifact / set_metric / drop_subtree / get_tree / export_markmap / import_markmap / sync_github / push_pr / register_pr / attach_code_file / sync_prs / sync_miro / set_board_config / bind_session / save_github_creds / save_miro_creds …`）。
    > ⚠️ **证据说明：** 动作数 = **24**（干净 main `62820c38`）；另外"board = agent `:kanban` slice"的旧说法不准 —— 看板挂在**通用 `Entity.Agent`（kind `:agent`）宿主**的 `:tree` slice 上（shared.ex:142 `def tree`、:149 `{:set, :tree}`）。
  - **例 B（官网）：** 匿名访客的"投票 / 导航"是受限 action（缺写 cap 会被拒）；团队成员在同一 app 内驱动 hello 生成、跑 kanban，是全 action。官网对话框本身"只读"（PR #1118 §5.2："对话框不做生成/改/发布页面内容、任何后台变更、跨 session 读"）。

### Step 7 — 公开面 vs 非公开面的区别

- **① 参与用户：** 开发者（设计 app 时）。
- **② 目的：** 区分"给外部匿名看的"和"给内部成员操作的"。
- **③ 期望得到：** 明确两个面的差异规则。
- **④ 现状：✅ 有，三个维度：**

  | 维度 | 公开面（socialware facet） | 非公开面（内部成员） | 代码依据 |
  |---|---|---|---|
  | **身份** | 匿名只读 anon-User `entity://<ws>/user/anon-<random>`，构造即只读 | 认证成员（普通 User / Agent，带 session 写 cap） | `anon_user.ex` moduledoc :6-9、:25-29 |
  | **能力** | 受限（看 / 投票，靠 definition `visibility_policy.web_anon_access`）；写动作在 CapBAC 卡点被拒 | 全 action（每个 action 各自要对应 cap） | `public_view.ex:18` + `installation.ex` moduledoc :5 |
  | **交付** | feed / page 投影（`public_view` → `/socialware/*` 只读渲染） | 直接进会话收发（dispatch 双向） | `public_view.ex` moduledoc :3、PR #1118 §1① |

- **⑤ 举例：**
  - **例 A（kanban）：** 若 kanban 开公开面，匿名访客只读看板 + 投票；团队成员全 action（claim / set_status / 派活）。
  - **例 B（官网）：** 公开面 = 匿名访客看 kanban 进度 + 投票（受限，导航式副驾）；非公开面 = 团队成员在同一 app 内操作 hello 生成 / kanban / github（全 action）。这正是"同一个 app、两个面"的活例子。

---

## 2. 两个例子的完整链路速览（把 7 步串起来）

### 例 A · kanban（现有 app，扁平组合）

| 步 | kanban 走到哪 | 现状 |
|---|---|---|
| 1 建 agent 入 session | create kanban-manager（recipe×native）+ pm-coordinator，join 团队 session（`workspace.ex:768`） | ✅ |
| 2 装成 app | 缺 "kanban app" 清单；kanban-manager 配方在 kanban 插件，board 靠运行时挂 agent（pm/dev 归属见 C#1115） | ⚠️ |
| 3 发布 | 内部用为主；开公开面则走 public_view | ⚠️ |
| 4 多装 + 打包 | 一 session 里 kanban+pm+github 能力并存，但不能 compose 成"一个 kanban app" | ⚠️ |
| 5 别人用=新 session | 团队成员进同一团队 session（共享一块板） | ⚠️ 语义待定 |
| 6 一切=chat + CapBAC | 24 个 action 各带 cap-template（`application.ex:100-103`），board=`:tree` slice（`shared.ex:142/149`） | ✅ |
| 7 公开 vs 非公开 | 匿名只读看板 / 成员全 action | ✅ |

### 例 B · 官网（嵌套 app，建在 PR #1118 §5.2）

| 步 | 官网走到哪 | 现状 |
|---|---|---|
| 1 建 agent 入 session | spawn `Entity.HelloBuilder`（flavor `"hello_builder"`，`application.ex:64-72`）进 `session://system/hello/site` | ✅ |
| 2 装成 app | 缺 "官网 app" 清单；页面靠 `Behavior.Surface.put_version/2` 诞生（hello moduledoc :7-8） | ⚠️ |
| 3 发布 | public_view 给公开地址（`/socialware/chat`，计划 `app.ezagent.chat`）；`HELLO_DEMO_SEED=1` 可 boot 种子（`application.ex:115-118`） | ⚠️ |
| 4 多装 + 打包（**嵌套核心**） | 官网 = hello 生成 + 公开面 + 内嵌 kanban/github 进度；组合能拼但不能声明/一键打包 | ⚠️/❌ |
| 5 别人用=新 session | 匿名访客 mint 只读 anon-User（`anon_user.ex:65`）join 公开会话 | ⚠️ 语义待定 |
| 6 一切=chat + CapBAC | 对话框只读（导航 action + 短文字，PR #1118 §5.2）；生成/改属团队成员全 action | ✅ |
| 7 公开 vs 非公开 | 匿名看进度+投票（受限）/ 成员驱动 hello+kanban+github（全 action） | ✅ |

**两个例子都走完了 7 步。** 它们的差别正是本系列要澄清的："扁平组合"（例 A：几个 agent 在一个 session）vs "嵌套 app"（例 B：一个 app 嵌了别的 app 能力 + 公开面）。

---

## 3. 核实记录（本篇所有 file:line 已对干净 main `62820c38` 代码核过）

| 断言 | 文件:行 | 核实结果 |
|---|---|---|
| create_agent 走 dispatch | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:768`（def）、:776（Router.dispatch） | ✅ 与底稿一致 |
| installs 织进 kind_base + 默认 chat | `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:5`（moduledoc）、:12（`@default_installs ["chat"]`）、:24（installs_from_template） | ✅ 底稿 :5/:12 准 |
| 匿名网页访问闸 / web_anon_access? | `apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:18`（函数）、:3（moduledoc 引言） | ✅ 函数在 :18 准；⚠️ 底稿把 moduledoc 引言标 :6，实际在 :3 |
| anon-User 只读铸造 | `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex:65`（mint）、:6-9/:25-29/:40-41 | ✅ 存在且只读、48h GC |
| SessionTemplate = 生产单元 + installs 字段 | `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:6`（moduledoc）、:50-53（installs 字段） | ✅ 底稿 :52 落在字段注释区，字段字面在 :53 |
| socialware definition 寻址 | `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:5/12/29` `config://<ws>/socialware/<名>` | ✅ 准 |
| URI scheme 白名单（config 不在其中） | `apps/ezagent_core/lib/ezagent/uri.ex:515` `@unified_per_tenant_schemes ~w(entity session template resource)` | ✅ config 是跨切面 scheme |
| kanban roles = 仅 kanban-manager | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:71`（roles）、:95（kanban_manager_recipe）、:98-103（passive/behaviors/requested_caps） | ✅ kanban `roles/0` 只声明 kanban-manager |
| pm/dev recipe 归属 | — | 见 C#1115 决策（在途）：产品配方归产品 plugin、不进平台层——属 app 配方治理、**非本系列基座主题**，本篇不展开 |
| kanban 动作数 + board slice | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（`action(:` 宏）、`kanban/shared.ex:142/149`（slice key `:tree`） | ✅ 动作数 = **24**；slice key `:tree`（非 `:kanban`） |
| hello builder = 专用 Kind/flavor | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:64-72`（flavor `"hello_builder"`→`Entity.HelloBuilder`）、:105（`Behavior.HelloBuilder` :receive）、:79（plugin_info）、:115-118（HELLO_DEMO_SEED）；`.../entity/hello_builder.ex`（Kind） | ⚠️ **修正底稿**：底稿 §Step1 例 B 写"role HelloBuilder × native"，实际是专用 Kind + flavor `"hello_builder"`，直接 spawn 成 session 成员，非 role×native recipe |
| 官网 = hello 生成页，公开地址 | PR #1118 §1①（`/socialware/chat?session_uri=session://system/hello/site`，计划 `app.ezagent.chat`）、§5.2（门户助手·导航式副驾/只读/grounding 三源） | ✅ 已读 PR #1118 diff 核对 |
| routing = 会话调 Resolver（纯函数） | `apps/ezagent_core/lib/ezagent/routing/resolver.ex:68`（`(msg, session_uri, members) → recipients`）、`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:516`（session 调 `resolve_with_ctx`） | ✅ 准；routing 挂 session 非 agent |
| Routing behavior 仅 workspace/session/system 三级 | `apps/ezagent_core/lib/ezagent/behavior/routing.ex:38`（workspace）、:40（session）、:42（system）；:5-12（PR #146 dissolve `routing-admin://default` + `RoutingAdmin`） | ✅ `Entity.Agent` 无 Routing behavior |
| AgentManifest = 工具清单契约（≠ recipe） | `apps/ezagent_core/lib/ezagent/agent_manifest.ex:1`（struct: tools/caps/soul/executor）、:79-80（tool 派生 artifact）；CLI facade `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex:1` → `spawn_from_manifest/6` | ✅ 存在；facade 在 `ezagent_cli` 非 `ezagent_core` |

---

> **给 Allen 的一句话：** 平台底层原语（dispatch / CapBAC / session 沙盒 / public_view 公开面 / anon-User / installs-as-list）**已经支撑住这 7 步的大部分**；每一步的 ⚠️/❌ 都指向同一个缺口 —— **缺一个统一的 "app" 抽象 + install/publish/compose 生命周期接口**。例 A（kanban，扁平）和例 B（官网，嵌套）是两个天然的 conformance 目标：把它们都能用同一套 app 定义表达出来，这个抽象就成立了。下一篇（2/4）讲现有概念在代码里到底长什么样、乱在哪。
