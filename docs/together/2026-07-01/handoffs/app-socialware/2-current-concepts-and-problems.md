# Handoff 2/4: 现有概念的代码实情 + 问题

> **Date:** 2026-07-01 · **From:** jjkysy (FP5) · **To:** Allen (lead) + 独立 dev（human + cc/codex）
> **Base:** 干净 upstream/main @ 62820c38（含 A#1117 World UI-surface substrate，已 merge）
> **系列:** app/socialware 收口 4 文档之二（1=平台全流程 · **2=本文：现有概念的代码实情** · 3=应有概念关系 · 4=实现路径）
> **一句话:** 承接文档 1（平台该怎么被用的 7 步流程），本篇落到"现在代码里到底有什么"——把 "plugin / socialware / app 在 ezagent 代码里到底是什么、边界在哪、乱在哪" 全部落到 file:line，作为定义 "app package" 的事实底稿。第 3 篇再画应有的概念地图 + 差距，本篇只讲现状。

---

## 0. 为什么先讲清 "现有概念是什么"

ezagent 口头上有一堆 "app"（kanban、hello、autoservice、官网、world…），但**代码里没有一个叫 "app" 的统一东西**。它们各自表达成三种完全不同的形态：有的是 plugin（OTP 代码包）、有的是 seed 脚本（一次性 `.exs`）、有的已退役。要定义 "app package"，得先承认现状：**当前只有三个真实存在的概念 —— plugin、socialware、SessionTemplate.installs —— 且这三个各有各的问题。** 本文逐个落到代码。

**术语先约定**（首现解释）：
- **plugin** = 一个 OTP application（`:ezagent_plugin_<name>`），`use Ezagent.Plugin` 声明它给平台提供什么。**不是** Mix 编译插件。
- **Kind** = 一个 URI ↔ 一个进程（GenServer）的运行时类型（如 `Entity.Agent`、`Entity.Session`）。
- **Behavior** = 动作处理器（一组 `action`），挂在某个 Kind 上，被 dispatch 调。**不是** Elixir 的 `@behaviour`。
- **flavor**（agent flavor）= agent 的"引擎宿主"（用哪个大脑跑：cc / codex / native / py / curl）。
- **recipe**（role）= 一份 agent 配方数据（装哪些 behaviors、要哪些 cap、system prompt 等），boot 时登进 RecipeRegistry。
- **socialware** = 一个会话的**公开对外交付面**（匿名只读投影）——本文 §2 会拆它的三义。

---

## ① plugin 到底是什么

### 1.1 契约：`Ezagent.Plugin` 的六个声明 callback

权威源 = `apps/ezagent_core/lib/ezagent/plugin.ex`。一个 plugin `use Ezagent.Plugin`，只**声明**它交付什么，**从不**自己调 `*Registry`——框架的 `Ezagent.Plugin.boot/1`（`plugin.ex:417`）负责把每条声明翻译成 registry 调用（`plugin.ex:7-16` 的 "declare, don't call" 哲学）。

只有 `plugin_info/0` 是必须的（`plugin.ex:195`）；其余全是 optional callback，`use Ezagent.Plugin` 给了 `defoverridable` 默认（`plugin.ex:281-305`，`kinds/0 → []`、`config_surface/0 → nil` 等）。

一个 plugin **可以提供什么**（决定它属于哪一类）：

| callback | 声明的 file:line | 提供什么 | 谁用它 |
|---|---|---|---|
| `kinds/0` | `plugin.ex:198` | 新的进程类型（Kind） | 少数 plugin（如 hello 的 `HelloBuilder`） |
| `behaviors/0` | `plugin.ex:199` | 动作处理器（工具） | 挂到某 Kind 上，dispatch 调 |
| `agent_flavors/0` | `plugin.ex:208` | **引擎宿主**（agent 用哪个大脑） | 引擎类 plugin |
| `roles/0` | `plugin.ex:212` | **recipe = agent 配方**（数据） | X-as-role 类 plugin |
| `adapters/0` | `plugin.ex:232` | ExternalMirror 出入站 adapter/binding | 渠道类 plugin |
| `config_surface/0` | `plugin.ex:242` | `/plugins` 配置图标开什么 | 有配置面的 plugin |
| `spawns/0` | `plugin.ex:206` | **RESERVED，必须 `[]`** | 无人——plugin 不许拥有 scheme 级 spawn（`plugin.ex:536` `reject_spawns!` 硬拒） |

> **关键**：`spawns/0` 被永久保留为 `[]`（`plugin.ex:38-51` moduledoc + `:206` + `:536`）。六个 core URI scheme（`entity/session/template/resource/workspace/system`，`plugin.ex:74`）全归 core/domain 拥有，plugin 一个都不能拥有。plugin 想加可 spawn 的 Kind，只能在**已有 scheme 里加 type/name 前缀**（如 `entity://<ws>/agent/<id>`），或在 core Kind 上挂 Behavior。这是理解 "plugin ≠ 独立系统" 的地基。

### 1.2 按"提供什么"分五类（每类带具体 plugin + file:line）

现有 13 个 `ezagent_plugin_*`（`apps/` 下：cc / codex / curl_agent / email / feishu / github / hello / kanban / kb / native / protocol_api / py / world）+ 2 个**非 plugin 的传输 umbrella app**（ezagent_web / ezagent_cli）。按它们**声明了哪个 callback** 归类：

#### 第 1 类 · 引擎 flavor 类（声明 `agent_flavors/0`，提供"大脑"）

给 agent 提供引擎宿主。一个 plugin 可声明**多个 flavor**。

| plugin | application.ex 路径 | `agent_flavors/0` | flavor 名 file:line |
|---|---|---|---|
| **cc** | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex` | `:100` | `"cc"` `:103` + `"cc-headless"` `:112`（`instance_behaviors: &…cc_headless_behaviors/0` `:116`） |
| **codex** | `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex` | `:35` | `"codex"` `:38` + `"codex-remote"` `:44` |
| **curl** | `apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/application.ex` | — | `"curl"` `:112` |
| **native** | `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex` | — | `"native"` `:90` |
| **py** | `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex` | — | `"py"` `:106` |

> **`cc-headless` 是 flavor，不是 plugin。** 它是 cc plugin 在同一个 `agent_flavors/0` 里声明的**第二个 flavor**（`application.ex:112`），和 `"cc"`（`:103`）共用一个 plugin。所以"真 Claude brain（headless）"不是独立可安装单元，是 cc plugin 的一个 flavor 变体。同理 `codex-remote`（`:44`）是 codex 的第二 flavor。**flavor 数 ≠ plugin 数**：5 个引擎 plugin 提供了 7 个 flavor。

#### 第 2 类 · X-as-role 类（声明 `roles/0`，提供"专职 agent 配方"，常拥有数据）

给平台加一个专职 agent（"员工"）+ 它的工具 Behavior。这类是"最像 app"的 plugin，也是最容易被误当 app 的（见 §④）。

| plugin | application.ex 路径 | `roles/0` file:line | recipe / behaviors / 数据 |
|---|---|---|---|
| **github** | `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex` | `:70` | `github_gateway_recipe`（`:78`），`behaviors: [Ezagent.Behavior.Github]`（`:83`），gh CLI 网关 |
| **kanban** | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` | `:71` | `kanban_manager_recipe`（`:95`），`behaviors: [Ezagent.Behavior.Kanban]`（`:99`，24 动作），**board 挂通用 `Entity.Agent` 的 `:tree` slice**（`shared.ex:142` `def tree` / `:149` `{:set, :tree}`） |
| **kb** | `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/application.ex` | `:80` | `kb_recipe`（`:67`），`behaviors: [Ezagent.Behavior.Kb]`（`:71`），**拥有 sqlite FTS5 corpus**（每 KB 一个独立 sqlite 文件，moduledoc `:8-9`） |

> **kanban 特殊在"拥有 board 数据"。** github 是无状态网关（薄包 gh CLI）；kanban 和 kb 则**拥有各自的运行时数据**——kanban board 挂在通用 `Entity.Agent` 的 `:tree` snapshot slice 上（`shared.ex:142`/`:149`），kb 是每 KB 一个独立 sqlite 文件（`application.ex:8-9`）。这个"拥有数据"正是"一个 app 该有 data 面"的现实雏形，但现在它被塞在 plugin 的 role recipe 里，没有独立的"app data 声明"。

#### 第 3 类 · 渠道类（声明 `adapters/0`，提供进出外部世界的传输）

ExternalMirror adapter/binding 对（出入站镜像）+ 一个 cap-only 的 marker Behavior（门控 per-adapter 权限）。

| plugin | application.ex 路径 | `adapters/0` file:line | adapter/binding 对 |
|---|---|---|---|
| **feishu** | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex` | moduledoc `:13-15`、`:42` | `{FeishuAdapter, FeishuChatBinding}` + cap marker Behavior（`:17-18`） |
| **email** | `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex` | `:12` | `{Ezagent.Email.Adapter, Ezagent.Email.Binding}` + `EmailAllow` marker（`:17-18`） |
| **protocol_api** | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex` | `:37` `def adapters, do: [{Adapter, Binding}]` | `{ProtocolApi.Adapter, Binding}` |

> 这类**不声明 flavor、不声明 role**——它们只是把消息桥到外部渠道（飞书/邮件/HTTP），属于"传输"，不是"能力提供方"也不是"专职 agent"。

#### 第 4 类 · 传输前端类（UI / 前端外壳）

| 名 | 路径 | 是 plugin 吗 | 提供什么 |
|---|---|---|---|
| **world** | `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex` | ✅ 是 plugin | `behaviors/0`（`:27`）+ `resource_types/0`（`:44`，UI layouts）+ UI 渲染外壳（React/json-render slot） |
| **web** | `apps/ezagent_web/` | ❌ **不是 plugin** | 纯 Phoenix umbrella app（HTTP transport）；托管 `/socialware/*` 路由（`ezagent_web/lib/ezagent_web/router.ex:153,160,167`） |
| **cli** | `apps/ezagent_cli/` | ❌ **不是 plugin** | 纯 umbrella app（终端 transport） |

> **注意与直觉的偏差：** world 虽是前端，但它**确实**声明了 `behaviors/0`（`:27`）和 `resource_types/0`（`:44`），不是"零 Kind/Behavior"。而 web/cli **根本不是 plugin**（`grep "use Ezagent.Plugin"` 在 `ezagent_web`/`ezagent_cli` 下无命中），是独立 umbrella app。所以"前端"这一类内部就已经形态不一：world=plugin、web/cli=umbrella app。

#### 第 5 类 · 自带 Kind 类（少数，声明 `kinds/0` + 专属 flavor）

**hello** 是特例——它既声明 `agent_flavors/0`（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:64`）**又**用一个**专属 Kind** `Ezagent.Entity.HelloBuilder`（`:68`）作为 flavor 的 `kind`，还声明 `behaviors/0`（`:89`，`{Entity.HelloBuilder, :receive, Behavior.HelloBuilder}` `:105`）。它不复用通用 `Entity.Agent`，而是自带 Kind + flavor + behavior 一整套。这让 hello 看起来"像个 app"，但它本质仍是一个 plugin（见 §④ 归类问题）。

### 1.3 三层区分：plugin ≠ agent ≠ 工具

这是最容易混的一层，落到定义：

| 层 | 是什么 | 载体 | 例子 |
|---|---|---|---|
| **plugin** | **代码包 / 提供方**（机制层） | OTP app `:ezagent_plugin_<name>`，`use Ezagent.Plugin` | kanban plugin、cc plugin |
| **recipe（role）** | **agent 的配方**（数据层） | `roles/0` 声明的 map，登进 RecipeRegistry | `kanban-manager`、`github-gateway`、`kb` |
| **agent** | **配方的运行实例**（运行时） | `entity://<ws>/agent/<id>` 进程 | 某会话里一个具体的 kanban-manager agent |
| **工具** | **Behavior**（动作处理器） | `behaviors/0` 声明，挂 Kind 上 | `Behavior.Kanban`（24 动作）、`Behavior.Github` |
| **flavor** | **引擎宿主**（agent 用哪个大脑） | `agent_flavors/0` 声明 | `cc` / `cc-headless` / `native` / `py` |

**读法**：一个 kanban plugin（代码包）**声明**了 `kanban-manager` recipe（配方数据）+ `Behavior.Kanban` 工具；用户 create 一个 agent 时选 flavor `native` × role `kanban-manager`，物化出一个 agent 实例（`entity://<ws>/agent/<id>`），这个实例在通用 `Entity.Agent` 宿主上 per-instance 加载 24 个 kanban behaviors。**plugin 是代码，recipe 是数据，agent 是运行实例，工具是挂在实例上的 Behavior——四个不同的东西，口头都可能被叫 "kanban"。**

---

## ② socialware 是什么（一名三义 = 乱源）

`socialware` 这个词在代码里跨**三个层**同名使用，这是术语漂移的最大来源。三义各带引用：

### 义 1 · 公开交付面（delivery facet）

一个已安装 socialware 的**匿名 web 访问闸 + 只读投影**。

- **入口闸**：`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:1-3` moduledoc "Anonymous web-access gate for installed socialwares"；`web_anon_access?/1`（`:17-19`）委托 `Installation.web_anon_access?`，靠 definition 的 `visibility_policy.web_anon_access` 字段。
- **投影 adapter**：`apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:16` 用 `ChatFeedAdapter` + `ExternalFeedAdapter` 两个 `:pull` adapter，boot 时注册（`:51-59`）。ExternalFeed 实现在 `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex`。
- **公开路由**：`apps/ezagent_web/lib/ezagent_web/router.ex:153`（`/socialware/external`）、`:160`（download）、`:167`（legacy `/socialware/customer` 301）。
- **匿名身份**：`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex`（mint 只读 anon-User）。
- **关键事实**：P5 substrate collapse 后，**本域不再拥有 session Kind**（`application.ex:6-7` "After the P5 substrate collapse it no longer owns a session Kind"）——socialware 会话是**统一 `Entity.Session`** 的实例，只是带 `Session.socialware_behaviors/0` 的 `:kind_base` 子集。**socialware 不是一个独立会话类型，只是统一会话开了公开面。**

### 义 2 · 一个可寻址的 definition

一份"装哪组 behaviors + 公开策略"的配置对象，有自己的 URI。

- **可寻址 URI**：`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:5-6` `config://<workspace>/socialware/<name>`（ConfigObject key `"socialware"`，镜像 role-as-data 的 `config://.../recipe/...` 模式）。
- **URI 构造**：`definition_subject_uri/2`（`:21-30`，`"config://#{workspace}/socialware/#{name}"`）。
- **内建两个 definition**：`builtin_definitions/0`（`:108-131`）—— `"chat"`（`bases: Session.chat_behaviors()`，`web_anon_access: false`）+ `"socialware"`（`bases: [Behavior.Session, Publisher.SessionImpl]`，`shape: [Turn, Surface, SupervisorApproval]`，`web_anon_access: true`）。
- **读法**：一个 definition = 一组 behaviors 的命名打包 + `visibility_policy`。它**可被 URI 寻址**，但**只打包 behaviors**，不含 recipe / 数据 / view。

### 义 3 · 安装机制（install substrate）

把 definition 装进一个会话的机制。

- **安装读取**：`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:5` moduledoc "A SessionTemplate's `installs` field names ConfigStore-backed socialware …"；`@default_installs ["chat"]`（`:12`）；`installs_from_template/1`（`:24`）；`behavior_set_for_template/2`（`:53`，把 installs 解析成实际 behavior set 织进会话）。
- **读法**：`Socialware.Installation` / `Socialware.DefinitionRegistry` / `Socialware.ConfigStore` 这些模块名里的 "Socialware" 其实是**历史命名的 app-install substrate**（装配机制），跟"公开面"没关系。同一个词，第三个意思。

### ⚠️ 上游 skill 的窄义

上游 `ezagent-socialware` skill 把 "socialware app = public_view SessionTemplate" 当权威——这是**窄义**，只覆盖了义 1（公开面）。它会误导读者以为 "socialware = 一个 app 单元"。**实际 socialware 是一个 app 的一个 facet（公开交付面），不是上位 app 单元**（本收口系列的 locked decision #1：`domain_socialware/application.ex:6-7` + `public_view.ex` 交叉验证）。

**三义汇总表**：

| 义 | 是什么 | 权威 file:line |
|---|---|---|
| 1 · 公开交付面 | 匿名 web 访问闸 + 只读 feed 投影 | `public_view.ex:1-3,17-19`；`domain_socialware/application.ex:16,51-59`；`external_feed.ex`；`router.ex:153,167` |
| 2 · 可寻址 definition | `config://<ws>/socialware/<名>`，一组 behaviors + 公开策略 | `definition_registry.ex:5-6,21-30,108-131` |
| 3 · 安装机制 | `SessionTemplate.installs` → 装 definition 的 substrate | `installation.ex:5,12,24,53` |

---

## ③ "类似 app 定义"在代码里是什么

**代码里最接近"一个 app"的东西 = `Ezagent.Entity.SessionTemplate`**，具体在它的 `installs` 字段。

- **文件**：`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`。
- **自我定位**：moduledoc `:5-6` 自称 "the **production unit of multi-agent orchestration** — a named, versioned, forkable configuration"。它定义：团队由哪些 agent 组成、路由规则、绑哪个 orchestrator、落哪个 workspace。
- **installs 字段**：`:50-53`
  ```
  # `installs` — product/runtime install refs consumed by
  # `Ezagent.Session.InstallCatalog` during materialization.
  # P3 built-ins: "chat" and "socialware"; absent preserves "chat".
  installs:                   [String.t()],
  ```
  另一处注释 `:761` 明说它是 "the P3/P4 **socialware composition field**"；`:767` 把 `installs` 列进 slice_keys（持久化字段）。

**为什么它不是完整 app**（关键差距）：`installs` 是一个 `[String.t()]` 列表，materialization 时经 `Ezagent.Session.InstallCatalog` 装**socialware definition**（义 2，一组 behaviors）。也就是说：

| app 该有的 | SessionTemplate 有吗 | 依据 |
|---|---|---|
| 会话形态 / 成员 / 路由 | ✅ 有 | `session_template.ex:36-76` slice schema |
| 装哪些 socialware definition（behaviors） | ✅ 有（但只这个） | `installs:` `:53` + `installation.ex:53` |
| recipe（专职 agent 配方） | ❌ 无统一声明 | recipe 归各 plugin `roles/0`，不在 template 里 |
| 拥有的运行时数据（slice + schema） | ❌ 无统一声明 | 数据散在各 plugin（kanban `:tree` slice / kb sqlite） |
| view（嵌入 + 公开面） | ❌ 无统一声明 | 散四处（见 §④） |
| 公开面 CapBAC policy | ⚠️ 间接（靠 definition `visibility_policy`） | `definition_registry.ex:114-129` |

**结论**：`SessionTemplate.installs` 是"最接近 app 的组合层"，但它**只声明了装哪些 socialware definition（一组 behaviors）**，缺 recipe / 数据 / view / 公开面的**统一声明**，也没有 install/publish/compose 的生命周期接口。它是 app 的**一个切面**，不是完整 app。

---

## ④ 现在的问题（每条带依据）

### 问题 1 · 没有统一的 "app" 边界（grep 空）

```
$ git grep -l AppPackage apps/
（无输出，exit 1）
```
**已核实**：`apps/` 下 `AppPackage` 零命中。代码里根本不存在一个叫 "app" / "AppPackage" 的类型或模块。所有"app"都是别的东西冒充的（plugin / seed / template.installs）。

### 问题 2 · "app" 归类不统一（同名三种形态）

同样口头叫 "app" 的东西，代码里是三种完全不同的形态：

| "app" | 代码形态 | 依据（已核实） |
|---|---|---|
| **hello** | plugin（自带 Kind + flavor + behavior） | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:64,68,89` |
| **kanban** | plugin（role + behavior + 数据 slice） | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:71,99` |
| **autoservice** | **seed 脚本，不是 plugin** | `scripts/autoservice_tier1_seed.exs`（**644 行**，KB 语料 + persona）；`apps/` 下 `ls | grep autoservice` 无命中 |
| **advisor** | **退役 plugin** | `apps/` 下 `ls | grep advisor` 无命中；`domain_socialware/application.ex:30` 注释 "The advisor demo vertical … was retired in `chore/retire-session-advisor`" |

> **autoservice 是 seed 脚本，不是 plugin。** 它是一个 644 行的一次性 `.exs`（`scripts/autoservice_tier1_seed.exs`），往 ConfigStore 灌 KB 语料 + persona，**根本没有 OTP app**（`apps/` 下无 `ezagent_plugin_autoservice`）。这是"app 形态最混乱"的铁证：一个被当作产品/app 的东西，实现是一段跑一次的种子脚本。advisor 则更进一步——退役了，`apps/` 下已无。**三个 "app"：一个是自带 Kind 的 plugin、一个是 role plugin、一个是 seed 脚本、一个已退役——没有共同边界。**

### 问题 3 · view 基座散在四处（无统一声明）

一个 app 的"视图 / 渲染 / 交付"横跨四个不同的 domain/plugin，没有任何统一的 `views` 声明：

| view 关注点 | 住在哪 | file:line（已核实） |
|---|---|---|
| 共享渲染原语 `Behavior.Surface` | `domain_session` | `apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex` |
| `@json-render`（会话内富渲染） | `domain_ui` + `world` | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`；`apps/ezagent_plugin_world/lib/ezagent/world/{conversation_data.ex,slot_registry.ex}` + `assets/src/components/JsonRenderBubble.tsx` |
| 公开交付投影 `ExternalFeed` | `domain_socialware` | `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex` |

> 一个 app 想声明"我长什么样、内嵌哪个 slot、公开面渲染成什么"，现在要**同时碰 `domain_session` + `domain_ui` + `world` + `domain_socialware` 四处**，没有一个地方能一次声明清楚。这是"app package 缺 views 声明"的直接后果。

### 问题 4 · 中间层"声明"概念被复制了 5 次（增殖 → 看起来都像）

"声明一份配置数据→物化成运行时"这一个模式，在代码里被独立实现了至少 5 次，各为一个目标——这是"plugin/socialware/SessionTemplate/recipe/manifest 看起来都像"的代码级根因。

| 声明概念 | 声明什么 | 物化成 | file:line |
|---|---|---|---|
| recipe | agent 配置 | 一个 agent | `apps/ezagent_core/lib/ezagent/agent/recipe.ex:1` + RecipeRegistry `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex:3` |
| socialware definition | 一组 behaviors | 装进 session | `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:29` + DefinitionRegistry |
| SessionTemplate | 会话形态 | 一个 session | `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex` |
| AgentTemplate | agent fork（凭证/config_dir） | 一个 agent fork | `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`、`apps/ezagent_plugin_py/lib/ezagent/template/py_agent.ex` |
| agent manifest（agent contract） | agent 工具清单 | spawn 一个 agent | `apps/ezagent_core/lib/ezagent/agent_manifest.ex:1` + `agent_manifest/tools.ex:1` |

**代码自己承认是复制**：`definition_registry.ex:6` 明写 socialware definition "mirroring role-as-data's `config://.../recipe/...` pattern"——definition 是照 recipe 抄的同一套；recipe 有 RecipeRegistry、definition 有 DefinitionRegistry，两个几乎一样的 read-through resolver。**"看起来都像"不是错觉——它们本来就是同一个模式被抄了 5 遍、且没收敛。** 至于这套复制为何会滚成"缺 app package"（声明增殖 → 映射不一致 → 装配无契约三个结构性根因），是文档 3 §5.3 的权威分析，本篇只给复制 5 次这个事实、不展开根因。

---

## ⑤ 一页速查（给 Allen）

| 概念 | 代码里到底是什么 | 权威 file:line | 问题 |
|---|---|---|---|
| **plugin** | OTP 代码包，`use Ezagent.Plugin` 声明六样（kinds/behaviors/agent_flavors/roles/adapters/config_surface） | `apps/ezagent_core/lib/ezagent/plugin.ex:194-243` | 五类混杂；被误当 app |
| **flavor** | agent 引擎宿主，`agent_flavors/0` 声明 | cc `application.ex:100`（含 cc-headless `:112`） | flavor ≠ plugin，易混 |
| **recipe/role** | agent 配方数据，`roles/0` 声明 | kanban `:71`、github `:70`、kb `:80` | 归各 plugin，无统一 app data 声明 |
| **socialware（义1）** | 公开交付面（匿名闸 + feed 投影） | `public_view.ex:1-3`、`domain_socialware/application.ex:6-7` | 一名三义之一 |
| **socialware（义2）** | 可寻址 definition `config://<ws>/socialware/<名>` | `definition_registry.ex:5-6` | 只打包 behaviors |
| **socialware（义3）** | 安装机制（installs → 装 definition） | `installation.ex:5,12` | "Socialware.*" = 历史命名的 install substrate |
| **SessionTemplate.installs** | 最接近 app 的组合层 | `session_template.ex:50-53,761` | 只装 definition，缺 recipe/数据/view/公开面 |
| **agent contract（AgentManifest）** | agent 工具清单契约 | `agent_manifest.ex:1` | 与 recipe 同为"声明"概念、未收敛 |
| **routing** | 会话层接力规则（挂 session 非 agent） | `routing_registry.ex`+`resolver.ex:68` | app 层缺 routing 声明字段 |
| **app（package）** | **代码里不存在** | `git grep AppPackage` = 空 | 最大缺口 |

---

> **给 Allen 的一句话**：代码里没有 "app" 这个概念——只有 plugin（五类混杂：引擎 flavor / X-as-role / 渠道 / 传输前端 / 自带 Kind）、socialware（一名三义：公开面 / 可寻址 definition / 安装机制）、和 `SessionTemplate.installs`（最接近 app 但只装 definition）。三个 "app"（hello=plugin、autoservice=seed 脚本、advisor=退役）连共同形态都没有。更深一层，中间层还有"声明概念增殖"问题（recipe/definition/template/manifest 同模式复制 5 次），见文档 3 §5.3。要定义 "app package"，得先在这三个真实概念之上补一层统一声明 + 生命周期接口——这是文档 3（应有关系）和文档 4（实现路径）的任务。
