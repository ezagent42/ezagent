# Handoff 4/4: 实现路径（建基座 · 分步 + 分类 + 基座缺口收口）

> **Date:** 2026-07-01 · **From:** jjkysy (FP5) · **To:** Allen (lead) + gaga T7
> **Base:** 干净 `upstream/main` @ `62820c38`（A #1117 已 merge 进 main；本篇所有 file:line 均对 `62820c38` 核实）
> **系列：** app / socialware 收口 4 文档之四（收官）。1=用法全流程 · 2=现有概念代码实情 · 3=应有概念关系 · **4=实现路径（本篇）**
> **Status:** research/design handoff（clarify-first）——本篇只产 **实现路径 + build slices + 基座缺口清单**，**不改代码**，供 Allen 拍板方向。

**一句话**：承接文档 3（应有概念地图 + 差距 + 三根因），本篇是收官——讲**怎么建**，即**建基座（substrate）**、不是改哪个 app。把"从现状建到一个统一 **app package 基座**"讲成 **分步路径**，每步标清**碰哪些文件**和**性质分类**（core / 基础设施 / 都不属于 / 下游），再把**干净 main 上真实存在的 5 处基座缺口**逐条带 file:line 列出来该怎么补。基座建好后，**具体 app（kanban/hello/autoservice/官网）按 gate 和规范自行 conform，本篇不逐个点名它们怎么改**。

---

## 0. 术语先对齐（首现解释）

- **app package**（拟新建的上位概念）：一个"可安装的产品单元"。声明它**用哪些能力**（`uses`）、**带哪些专职 agent 配方**（`agents`）、**拥有哪些运行时数据**（`data`）、**长什么视图**（`views`）、**匿名能做哪些动作**（`public_face`）。当前代码里**没有这个统一名**（`git grep AppPackage upstream/main apps/` = 空，已核实 `62820c38`）。
- **substrate（基座）**：让"一个 app"成立的底层机制 —— ①统一的"声明"抽象 ②装配契约 ③app package manifest ④conformance gate。基座住 core / domain / 基础设施层，被所有具体 app 复用。**A #1117 的 PR 标题自己就叫 "plugin UI-surface substrate"、B #1116/C #1115 同样是 substrate 拆分 —— 它们就是这批基座建设的第一批。**
- **socialware（公开交付面 / delivery facet）**：一个 app 对外匿名开放的那一面（只读投影 + gated 动作）。不是上位单元，是 app package 的**一个 facet**（Locked decision #1）。
- **plugin**：一个 OTP 代码包 / 提供方，声明 `kinds / behaviors / agent_flavors / roles / config_surface`（`apps/ezagent_core/lib/ezagent/plugin.ex:194-243`）。是**机制层**，被 app package 的 `uses` 引用。
- **recipe（配方）**：agent 的配置数据（`roles/0` 返回的 map）。**recipe ≠ agent ≠ plugin**（Locked decision #5）。
- **SessionTemplate**：会话层模板，最接近"app 定义"的现存物（`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`），但只声明"装哪些 socialware definition"，不含 recipe / 数据 / 视图 / 公开面（见 §2 缺口 3）。
- **routing（会话层接力）**：agent 之间的接力/转交规则，realized 在 session 层（**不是 agent 自己的属性**），运行时住 `Ezagent.RoutingRegistry` + `Routing.Resolver`（`apps/ezagent_core/lib/ezagent/routing/resolver.ex`）。
- **agent contract / AgentManifest**：一个 agent 的工具清单/工具契约（它能调哪些工具），`apps/ezagent_core/lib/ezagent/agent_manifest.ex:1`。与 recipe（agent 的配置数据）互补：recipe 配 agent，AgentManifest 声明它的工具面。
- **umbrella boot**：umbrella 起来时 core 逐个 boot plugin（`apps/ezagent_core/lib/ezagent/plugin.ex:417` boot / `:293` after_boot），期间把 routing 规则 hydrate 进 `RoutingRegistry`。
- **性质分类**（本篇给每步打的标签）：
  - **core** = 改 ezagent core 契约 / dispatch / URI 寻址（`apps/ezagent_core/*`），最重、必须 Allen 先拍。
  - **基础设施** = 跨 domain 共享层 / CI gate，不属单一产品。
  - **都不属于** = 前端 / 产品交互，既非 core 也非通用基础设施。
  - **下游** = 基座 + gate 建好后，各 app 团队按规范自行 conform，**本 spec 不逐个点名**。

---

## 0.3 核心论点：本篇讲**建基座**，不讲改 app

要解决的是**基座问题**，不是某个具体 app（kanban/autoservice）的问题。基座 = 四件东西：

1. **统一的"声明"抽象** —— 一份声明 = 一个 typed ConfigObject at `config://<ws>/<kind>/<名>` + 一套参数化 registry，收敛现在各自为政的 registry（见 §2 缺口 2）。
2. **装配契约** —— 泛化的 installer：从"只装 socialware definition"泛化到"装全部声明（recipe / definition / data / views / routing）"（见 §2 缺口 3）。
3. **app package manifest** —— 一个产品单元的统一声明形态（见 §2 缺口 1）。
4. **conformance gate** —— CI 强制校验"一个 app 声明合规 / 能装能跑能发布"（见 §2 缺口 5）。

**基座建好 → 具体 app 按 CI gate 和规范自行 conform / 拆分，不需要本 spec 逐个点名 kanban/hello/autoservice/官网怎么改。** 具体 app 现在的不规范（某 plugin 混了工具 + 配方、某 app 是 seed 脚本）是**症状**，不是基座缺口 —— 基座 + gate 上线后它们自行收敛，本篇不列这些。

**基座建设第一批（拆分后方案，非 #1110）**：

| 方案 | 是什么 | 状态 |
|---|---|---|
| **A #1117** | World UI-surface **substrate**（nav/session-tab 归 World，core Plugin 契约保持干净） | **✅ 已 merge 进 main `62820c38`** |
| **B #1116** | generic per-session role-agent materialization **substrate** | 在途 |
| **C #1115** | recipe ownership decision（产品配方归产品 plugin，不进平台层） | 在途 |

> **不引用 #1110**：#1110 是拆分**前**的总线，它引入的 `DefaultRecipes` 把产品配方放进平台层 `domain_agent`（分层错），**干净 main 上没有**（`git grep DefaultRecipes upstream/main` = 空，只命中一份分析文档）。A/B/C 是拆分**后**取代它的方案，本篇一律参考 A/B/C，不参考 #1110。

---

## 0.5 时间线分层：本周官网上线（两天内）vs 基座收口（两天后）

⚠️ **本周硬目标 = 官网必须上线**。基座（app package 抽象）是多周工程，**不能阻塞官网上线**。路径分两段：

**两天内 · 官网上线（用现状拼，不动基座）** —— 官网上线**不需要**碰基座，现有机制已够：hello 生成站点页（`Behavior.Surface.put_version`）+ public_view 开公开面（`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:3`，`/socialware/chat`）+ 内嵌 kanban/github 进度（world.cup 真数据，PR #1118 §5.2）+ 部署绑 `app.ezagent.chat`（PR #1118 §1①，须与 Allen/T6 协调）。→ 走 **PR #1118 §5.2 的 zhaomato/zyli handoff + T6 部署**，用"扁平拼"（SessionTemplate 装多个 definition + 脚本），**不等基座**。这是本周交付。

**两天后 · 基座收口（把官网 + kanban 当 conformance example 验证基座）** —— 官网上线后，基座建设启动：**建基座**（步 1-5：manifest spec / 泛化 installs / 发布接口 / view 统一 / conformance gate）+ 治文档 3 §5.3 三根因 → 拿官网 + kanban 当两个 **conformance example** 验证基座是否成立 → 官网从"脚本拼的"重表达成"app package 声明的"（下游 conform，非本 spec 逐个点名）。

**一句话**：两天内官网用现状上线（不动基座），两天后**建基座**、拿上线的官网 + kanban 当验证 —— **上线不等基座，基座拿上线当 conformance example**。

---

## 1. 分步实现路径（基座建设 + 下游）

> 每步给：**目的 / 具体做法 / 碰哪些文件(file:line) / 性质分类**。对应 gaga T7A-E，加产品侧输入。
> **步 1-5 = 基座**（core + 基础设施，本 spec 重点）；**步 6 = 下游**（各 app 按 gate 自行 conform，本 spec 不逐个点名）；**步 7 = 都不属于**（前端）。
> 依赖链：**步 1（spec）→ 步 2-4（建基座）→ 步 5（gate）→ 步 6（下游 conform，需 gate 就位）→ 步 7（前端，需 2-3 落地）**。

### 步 1 —— app package manifest schema spec 〔基座〕

| 项 | 内容 |
|---|---|
| **目的** | 先定"一个 app package 长什么样"——字段集 + 可寻址性 + 生命周期，形成一页 spec 给 Allen + jjkysy grill。**先定形态再动代码**，避免从下往上返工。 |
| **具体做法** | ① 定义 manifest **7 字段**：`uses:[plugin]` / `agents:[recipe]`（**每个 agent = recipe（配置）+ 可选 AgentManifest（工具契约，`apps/ezagent_core/lib/ezagent/agent_manifest.ex:1`）**）/ `data:[slice+schema]` / `views:{embedded, public}` / `public_face:CapBAC policy` / `lifecycle:{install/publish/compose}` / **`routing:`（agent 接力规则 —— realized 在 session 层，落 `Ezagent.RoutingRegistry` + `Routing.Resolver`，umbrella boot 时 hydrate，见 `apps/ezagent_core/lib/ezagent/plugin.ex:417` boot / `:293` after_boot）**。② 决定可寻址方案（open question 1：新开 `config://<ws>/app/<名>` vs 复用 `socialware/<名>` 泛化）。③ 术语进 `GLOSSARY.md` Decision Log（Allen 落笔，不是我们改）。**◆ 这一步是治文档 3 §5.3 三根因的治本手段之一 —— 统一"声明"概念：一份声明 = 一个 typed ConfigObject at `config://<ws>/<kind>/<名>`，收敛 §2 缺口 2 列的那 6 个各自为政的 registry。** |
| **碰哪些文件** | 产出物 = 1 份新 md spec（`docs/` 下）；参考但**不改** `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:53`（现有 `installs` 字段定义）、`GLOSSARY.md`（Allen 加 Decision）。 |
| **性质分类** | **core 契约扩展（core-adjacent）** —— 它要泛化 `SessionTemplate.installs` 并定义新的可寻址性，落地即碰 core 契约。spec 阶段不改代码，方向属 core。B #1116 的 materialization substrate 落在这条链的下游。 |

### 步 2 —— 安装接口：泛化 `installation.ex` 的 installs（装配契约）〔基座〕

| 项 | 内容 |
|---|---|
| **目的** | 让 `SessionTemplate.installs` 从"只能装 socialware definition"泛化到"能装 app package（装全部声明）"，并给 app package 一个可寻址 URI —— 这就是**装配契约**。 |
| **具体做法** | ① 把 `installs` 的语义从"ConfigStore-backed socialware refs"（`installation.ex:5-7` moduledoc）扩到"app package refs"，保留旧 socialware ref 向后兼容（`@default_installs ["chat"]`，`installation.ex:12` / `def default_installs` `:20` 不破坏）。② 让 `config://<ws>/socialware/<名>`（definition 可寻址，`definition_registry.ex:29`）**并列**一个 `config://<ws>/app/<名>`（或复用泛化——看步 1 的可寻址决策）。③ 安装动作走 dispatch + CapBAC（P14/P22 在 core，安装是 substrate）。**④ 这一步是治文档 3 §5.3 三根因的治本手段之二 —— 泛化 `installs` 从"只装 socialware definition"到"装全部声明（recipe / definition / data / views / routing）"= 定义"装配契约"。** |
| **碰哪些文件** | `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:5-7,12,20`（泛化 installs 语义 + 默认）、`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:29`（并列 app registry / 泛化）、`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:53,761`（`installs` 字段 + line 761 "P3/P4 socialware composition field" 注释更新）、`apps/ezagent_core/lib/ezagent/uri.ex` 附近（新 scheme/泛化，若选新开 `app` scheme）。 |
| **性质分类** | **core** —— 安装是 substrate，可靠性（P22）+ dispatch-only（P14）都在 core；碰 URI 寻址（`uri.ex`）就是 core 契约。 |

### 步 3 —— 发布接口：统一 public_view + ExternalFeed 出「公开地址 + 身份寻址」〔基座〕

| 项 | 内容 |
|---|---|
| **目的** | 造一个统一的"发布"动作，一次产出两样东西：(a) **公开地址**（外部匿名打开就能用）；(b) **身份寻址**（ezagent 内经 URI 找到这个 app）。现在这两样是散的、没有一个"发布"动作把它们一起产出。 |
| **具体做法** | ① 复用现有 `public_view` 匿名门（`public_view.ex:3` "Anonymous web-access gate for installed socialwares" + `web_anon_access?/1`）作为公开地址的门控。② 复用 `ExternalFeed`（只读投影 / feed）作为公开面交付（`external_feed.ex` + `external_feed_adapter.ex` 的 `:pull` adapter）。③ 把"发布"做成一个 action：写公开门控策略 + 登记身份寻址 URI（步 2 的 `config://.../app/<名>`）。 |
| **碰哪些文件** | `apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:3`（匿名门 facade）、`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex` + `external_feed_adapter.ex`（feed 交付）、`apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:20-27`（P5 substrate collapse 注释区，发布动作挂到统一 Session behavior 上）。 |
| **性质分类** | **domain_socialware（交付面）+ core（寻址）** —— 公开面交付逻辑属 `domain_socialware`；产出身份寻址 URI 的那一半属 core。 |

### 步 4 —— view 基座统一：收敛 Surface + @json-render + ExternalFeed 〔基座〕

| 项 | 内容 |
|---|---|
| **目的** | 现在一个 app 的"视图"横跨三处、无统一声明；收敛成 app package `views` 字段（`embedded` + `public` 两种）。 |
| **具体做法** | ① 把共享渲染原语 `Behavior.Surface`（住 `domain_session`）、`@json-render`（住 `domain_ui` + `world`）、公开交付 `ExternalFeed`（住 `domain_socialware`）三处的"渲染 + 交付"抽象出统一的 `views` 声明契约。② `views.embedded` = World slot 内嵌视图；`views.public` = Surface + feed 公开投影。③ 与 #1118 "dual-surface（json-render vs LiveView）"对齐（open question 4：`views` 是否就是 #1118 的落地口）。 |
| **碰哪些文件** | `apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex`（Surface 原语）、`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex` + `world`（`@json-render` 渲染层）、`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex`（公开投影）。碰 world 前必读 `docs/guide/world-coordination.md` + 登 in-flight registry。 |
| **性质分类** | **基础设施** —— 这是跨 domain（session / ui / socialware / world）的共享 view 层，不属单一产品。 |

### 步 5 —— conformance CI gate 〔基座〕

| 项 | 内容 |
|---|---|
| **目的** | 让"一个 app package 声明是否合规、能否经标准接口装/跑/发布"在提交时被强制检查（gaga T7C）——**这是让"下游 app 自行 conform"成立的前提**。 |
| **具体做法** | ① 写 `mix ezagent.*` conformance task：校验 manifest 字段齐全、`uses` 引用的 plugin 存在、`data` slice schema 合法、`public_face` CapBAC policy 可解析。② 挂进 CI，与现有 gate（arch.scan / doc.scan / uri_query.scan / check_invariants / format / test / `:ezagent_plugin_check`）并列。③ 提供"标准接口装/跑/发布"的 smoke：能 install → session load → publish 出地址。 |
| **碰哪些文件** | 新增 1 个 mix task（`apps/ezagent_*/lib/mix/tasks/` 下，或 core 的 tasks 目录）；CI 配置（`.github/` 或项目 CI 定义）；与现有 `:ezagent_plugin_check` gate 并列注册。 |
| **性质分类** | **基础设施（CI）** —— gate 是通用工程设施，不属单一产品。 |

### 步 6 —— 各 app 按 gate 自行 conform 〔下游 · 本 spec 不逐个点名〕

| 项 | 内容 |
|---|---|
| **目的** | 基座 + gate 建好后，现有那些"叫 app 但表达各异"的东西（kanban / hello / autoservice / 官网）按统一 app package 声明重表达，做成 conformance example，证明标准可用。 |
| **具体做法** | **各 app 按步 5 的 gate 和步 1 的 manifest 规范自行 conform / 拆分 —— 本 spec 不逐个点名 kanban/autoservice 怎么改。** 这是基座 + gate 建好后的下游收敛：gate 上线即给出"合规长什么样"，app 团队照做，绿则通过。哪个 app 混了工具 + 配方、哪个 app 是 seed 脚本，都由 gate 反馈驱动收口，不是本篇逐条设计的对象。 |
| **碰哪些文件** | 各 app 自身（`apps/ezagent_plugin_*`、`scripts/*_seed.exs`、官网建在 #1118 上）—— 具体文件由各 app conform 时定，不在本 spec 枚举。 |
| **性质分类** | **下游（gate 驱动 conform）** —— 不新增机制，由基座 + gate 反馈驱动，各 app 团队负责，本 spec 不逐个点名。 |

### 步 7 —— 前端 UI 暴露（World install / publish / compose）〔都不属于〕

| 项 | 内容 |
|---|---|
| **目的** | 在 World 前端把 install / publish / compose 做成用户可点的具体功能，让"当 app 平台用"这件事在 UI 上可见可操作。 |
| **具体做法** | ① World 里加 app package 列表 / 安装入口（调步 2 接口）。② 发布按钮（调步 3 接口）产出公开地址。③ compose：把一个 session 里多个 app 能力打包成新 app（步 4 的 composition，deferred，依赖步 1-3 落地）。④ 是 #1118 五面收敛的延伸。 |
| **碰哪些文件** | `world` 前端（碰前必读 `docs/guide/world-coordination.md` + 登 in-flight registry）；#1118 五面相关 LiveView。 |
| **性质分类** | **都不属于（前端 / 产品交互）** —— 既非 core 契约，也非通用基础设施，是 world 前端 + 产品交互。 |

---

## 2. 基座缺口表（干净 main `62820c38` 上真实存在的 core/domain 机制缺失）

> 这是收官重点：每条 = **缺口 / 依据(file:line) / 补什么**。**只列基座缺口，不点名 app**。全部依据已在 `upstream/main 62820c38` 核实。
> **一句话把 app 层排除在外**：具体 app 的不规范（如某 plugin 混了工具 + 配方、某 app 是 seed 脚本）是**症状**，基座建好 + gate 上线后 app 自行 conform，**不在本表** —— 本表只列**基座缺口**。

| # | 基座缺口 | 依据（file:line，对 `62820c38` 核实） | 补什么 |
|---|---|---|---|
| 1 | **无 app package 抽象** —— 没有上位"一个 app"的统一名 / 边界 | `git grep AppPackage upstream/main apps/` = **空**（已核实）；最接近的 `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:53`（`installs: [String.t()]`）只装 socialware definition，缺把 `recipe(agents) / slice+schema(data) / views / public_face` **统一声明**起来的东西 | 步 1 建 app package manifest |
| 2 | **声明 registry 增殖（基座碎片）** —— 同一个"声明 + 注册 + 物化"形状，干净 main 上各自为政造了 **6 遍**、没抽象出统一机制（呼应文档 3 §5.3 根因 1） | ①`apps/ezagent_core/lib/ezagent/routing_registry.ex:1`（`Ezagent.RoutingRegistry`）②`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex:1`（`Ezagent.Agent.RecipeRegistry`）③`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/adapter_registry.ex:1`（`Ezagent.AgentBridge.AdapterRegistry`）④`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex:1`（`Ezagent.ExternalMirror.AdapterRegistry`）⑤`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_registry.ex:1`（`Ezagent.ExternalMirror.BindingRegistry`）⑥`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:1`（`Ezagent.Socialware.DefinitionRegistry`；`:6` moduledoc 自认 "mirroring role-as-data's `config://.../recipe/...` pattern"，`:29` `config://<ws>/socialware/<名>`） | 步 1 统一"声明"概念（一份声明 = typed ConfigObject at `config://<ws>/<kind>/<名>` + 一套参数化 registry，收敛这 6 个） |
| 3 | **installs 只装 socialware definition，装配契约缺** —— 唯一像装配器的 `installs` 只装一种声明，没泛化到"装全部声明" | `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:5-7`（moduledoc："`installs` field names ConfigStore-backed socialware definitions"）+ `:12`（`@default_installs ["chat"]`）+ `:20`（`def default_installs`）——只覆盖 socialware definition（behaviors）那一条，recipe/data/views/routing 各走各的 | 步 2 泛化 installs 到"装全部声明（recipe/definition/data/views/routing）"= 定义装配契约 |
| 4 | **view 基座散** —— 一个 app 的"视图"横跨三处、无统一声明 | `apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex`（Surface 渲染原语）+ `@json-render`（`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex` + `world`）+ `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex`（公开投影） | 步 4 收敛成 app package `views` 声明（`embedded` + `public`） |
| 5 | **无 conformance gate** —— 没有一个 CI 校验"一个 app 声明合规 / 能装能跑能发布" | 现有 gate（arch.scan / doc.scan / uri_query.scan / check_invariants / `:ezagent_plugin_check`）都不校验 app package 合规性；`git grep AppPackage upstream/main apps/` = 空 → 无对象可校验 | 步 5 新增 `mix ezagent.*` conformance task，与现有 gate 并列 |

---

## 3. 实现分类小结（哪些步属哪类）

| 分类 | 是哪些步 | 为什么 |
|---|---|---|
| **core**（改 core 契约 / dispatch / URI）〔基座〕 | **步 2**（安装 substrate + URI 寻址）；**步 1** = core-adjacent（spec 阶段不改码，方向属 core，B #1116 落其下游）；**步 3 一半**（产身份寻址 URI） | 碰 `apps/ezagent_core/lib/ezagent/uri.ex`、`plugin.ex` 契约、install substrate（P14/P22 在 core），Allen 必须先拍 |
| **基础设施**（跨 domain 共享 / CI）〔基座〕 | **步 4**（跨 session/ui/socialware/world 的 view 层）；**步 5**（conformance CI gate） | 通用工程设施，不属单一产品 |
| **下游**（gate 驱动 conform）| **步 6**（各 app 按 gate 自行 conform，本 spec 不逐个点名）；**步 3 一半**（复用 public_view/ExternalFeed 属 domain_socialware 交付面） | 不新增机制，由基座 + gate 反馈驱动，app 团队负责 |
| **都不属于**（前端 / 产品交互） | **步 7**（World install/publish/compose UI） | world 前端 + 产品交互，非 core 非通用设施；deferred |

---

## 4. Definition of Done（给 Allen 的闭集）

本篇是 clarify-first 研究前置，DoD = 产出下游 build 需要的东西（**不建代码**），聚焦**基座 spec + gate**：

- [ ] **app package manifest spec 一页**（`uses/agents/data/views/public_face/lifecycle` 字段 + 可寻址性）—— 证明：Allen + jjkysy grill 过，进 `GLOSSARY.md` Decision Log（Allen 落）。
- [ ] **基座 build slices 拆分**（步 1-5 各拆成 PR-sized，标 core/基础设施）—— 证明：每 slice 有 owned surface + DoD 骨架（本篇 §1 表已给雏形）；对齐拆分后的 A #1117（已 merge）/ B #1116 / C #1115。
- [ ] **conformance gate spec**（步 5）—— 证明：校验项清单 + 与现有 gate 并列的注册点。
- [ ] **两个 conformance example 锁定**（用来**验证基座**，不是"要改的 app"）：**kanban（现有）** + **官网（嵌套，建在 #1118）** 必须过同一 app package gate —— 证明：两份 manifest 草稿。
- [ ] **术语对齐 #1120**：app package（上位）vs socialware facet（公开面），`Socialware.*` = legacy app-install substrate —— 证明：与 gaga T7A spec 一致。
- [ ] 本篇每条代码引用经核实（已完成：§1/§2 全部 file:line 读 `upstream/main 62820c38` 代码核过）。

---

## 5. Open questions（给 Allen 拍板，别先建）

1. **可寻址性** —— app package 新开 `config://<ws>/app/<名>` scheme，还是复用 `socialware/<名>` 泛化？（动 core 契约 + URI，`apps/ezagent_core/lib/ezagent/uri.ex`，必须 Allen 定；决定步 2 走法。）
2. **与 SessionTemplate 的关系** —— app package **是** SessionTemplate 的超集，还是**引用** SessionTemplate？（`session_template.ex:53` 现只装 definition；决定步 1 manifest 与现有模型的边界。）
3. **嵌套是真嵌套还是扁平** —— 官网含 hello+kanban+github，是 app package 的 `uses:[其它 app package]`（真嵌套），还是 install 多个 definition 到一个 session（扁平组合）？（决定 composition 模型 + 步 7 compose。）
4. **与 #1118 views 的关系** —— app package 的 `views` 声明是否就是 #1118 "dual-surface（json-render vs LiveView）"的落地口？（决定步 4 收敛终点。）
5. **与 gaga T7 的分工** —— gaga 出 T7A terminology/接口，本 handoff 出产品流程/形态，谁合并成最终 spec？（决定 spec 归口，避免两头各写。）

---

## 6. 关联 PR / 验证基准

| PR | 是什么 | 与本篇关系 |
|---|---|---|
| **A #1117** | World UI-surface **substrate**（拆分后） | **✅ 已 merge 进 main `62820c38`** —— 基座建设第一批之一 |
| **B #1116** | generic per-session role-agent materialization **substrate**（拆分后） | 在途；落步 1/步 2 材料化下游 |
| **C #1115** | recipe ownership decision（拆分后） | 在途；产品配方归产品 plugin，不进平台层 |
| **#1118** | Allen T1 五面收敛闸（Website / Hello / World UI / Agent Console / Socialware） | 官网 conformance example 建在其 §5.2；open question 4 与其 views 对齐 |
| **#1120** | gaga socialware/app 标准提案（T7A-E） | 本篇 = 它的产品侧输入 spec；术语对齐它 |
| ~~#1110~~ | ~~拆分前总线；引入 `DefaultRecipes`（分层错）~~ | **不引用** —— 拆分前的，`DefaultRecipes` 干净 main 无（`git grep DefaultRecipes upstream/main`=空），已被 A/B/C 取代 |

**验证基准**：本篇读**干净 `upstream/main 62820c38`**（A #1117 已 merge），§1/§2 全部 file:line 对该 commit 核实。不参考在途 wt，不引用 #1110。

---

> **给 Allen 的一句话**：本篇讲的是**建基座**不是改 app。基座 = ①统一声明抽象 ②装配契约 ③app package manifest ④conformance gate；**步 1-5 建基座（core + 基础设施），步 6 是下游（各 app 按 gate 自行 conform，本 spec 不逐个点名），步 7 前端**。同时补 5 处**基座缺口**（无 app package 抽象、声明 registry 增殖 6 遍、installs 只装 definition 缺装配契约、view 基座散三处、无 conformance gate），全部对干净 main `62820c38` 核实。基座建设第一批 = **A #1117（已 merge）+ B #1116 + C #1115**（拆分后方案，非 #1110）。建议：**先 grill 步 1 manifest（你拍字段 + 可寻址）→ gaga T7 接口 + 本产品流程合成最终 spec → 拿 kanban / 官网当两个 conformance example 验证基座。**
