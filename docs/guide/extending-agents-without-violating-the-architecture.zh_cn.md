# 扩展 agent 时不违反架构

> 一份简短、可随时翻阅的清单，用于新增 agent 类型或新增渲染/feed 能力——避免两类
> 容易忽略的架构违反再次发生。本文是 `docs/together/contributing/README.md`
> 台账红线（P0–P3）与 `.claude/skills/ezagent-developer/references/design-principles.md`
> 原则的"如何对齐"配套说明。英文版：
> [`extending-agents-without-violating-the-architecture.md`](extending-agents-without-violating-the-architecture.md)。

最近两个 PR **功能完整、可用、测试充分**——但仍需返工重塑，因为它们越过了两条架构
红线。两者都是诚实的失误，且对"测试通过"完全不可见（设计原则 **P6**：测试套件通过
并不证明不变式被守住）。本文的目的，是让这两类问题在**动手写代码之前**就能被发现。

---

## 动手前必读清单（写代码 BEFORE）

对任何 agent/feed/render 任务跑这四项检查。"STOP 列"出现任何一个"是"，都意味着：
先暂停、与 lead 重新对齐设计（台账 **P0**），再实现。

| 检查 | 若"是"→ |
| --- | --- |
| **1. 我是否在为某个 agent 类型新增 `Ezagent.Entity.*` Kind**（如 `Entity.Salesperson`、`Entity.Advisor`）？ | **STOP。** 新 agent 类型几乎一定是统一 `Entity.Agent` 上的 **role × flavor**，*不是*新 Kind。见 §1 + 实例 A。 |
| **2. 我是否把业务逻辑塞进了平台路径**——一个通用机制（render/feed/transport/dispatch）被某个具体业务人设/生产者/cap（`:salesperson`、"看板卡片由 salesperson 渲染"）所网关或路由？ | **STOP。** 把**机制**（通用、与生产者无关）和**生产者**（你的业务 agent，只是*消费*机制）分开。见 §2 + 实例 B。 |
| **3. 该能力是否已有通用机制？** 建造前先 grep transport/registry：`git grep -n "render\|json-render\|feed_encoding\|RoleRegistry\|agent_flavors" -- apps/`。 | 若有 → **复用它**，不要另起一套平行实现（台账 **P2**：地基先行）。 |
| **4. 我这个东西让 plugin 作者多学*一个*概念，还是少学*一个*？**（设计原则 **P8**） | 多一个 → 否决该设计；少一个 → 好。新 Kind = 多一个；role-on-flavor = 少一个。 |

若检查 1–2 干净，你就是在顺着架构纹理扩展。

---

## 两条原则（大白话）

### 原则 1 —— 新 agent 类型是 **role × flavor**，绝不是自己的 Kind

**规则（ezagent 专属）：** `agent = role（做什么）× flavor（怎么执行）`。flavor 是
已有宿主——`cc` / `codex` / `py` / `curl` / `native`——其 Kind 是统一的
`Ezagent.Entity.Agent`。role 是一个 *recipe*（behaviors + caps + skills + prompt），
在 create 时经 role-foundation（#54）**按实例**加载。新增 agent 类型 = 经
`roles/0` plugin 回调注册一个 recipe；**不要**写 `Entity.<Type>` 模块。

**为什么 own-Kind-per-type 被废弃：** 代码库曾经这么干过（`Entity.PyAgent` 等），
并在 P4b 统一收编为单一 `Entity.Agent`。每类一个 Kind 违反**插件隔离北极星**（P1）
和 **P24**（插件扩展已有 scheme，不新造 core 原语）：每个新 Kind 都拖着 create 分支、
独立的 snapshot/cap 接线、以及一个路由身份（`entity://agent/*` "免费"获得 chat
principal 语义——可被 @、可 join——而被动数据 agent 恰恰*不能*有）。它也违反 **P9**
（"读什么数据决定层级"）——salesperson 和别的 agent 一样读 chat，并非新的 core 概念。
正解已经落地：**kanban-as-role** 废弃了独立 Kanban Kind，把它 24 个 behavior 收编进
`native` flavor 上的 `kanban-manager` role。

> 台账 **P3** 直接写了这条红线：`agent = 角色×风味`。

### 原则 2 —— 平台**机制**必须与**业务**逻辑可分离

**规则：** 通用平台能力（render transport、feed 编码器、dispatch 路径）是**与生产者
无关**的。任何 agent 都能向其生产；它既不命名也不依赖某个具体业务人设，更**不**被某个
业务专属 cap 网关。业务 agent 是一个**消费**该通用能力的 *fixture/role*——它不把能力
焊死进自己。

**为什么机制 ≠ 业务：** 若 render 路径只有"经 salesperson"（且在 `:salesperson` cap
之后）才能用，那下一个生产者（advisor、客服 bot、dashboard）要么重写 transport、要么
冒充 salesperson——两者都违反 P1/P3（平行 SoT、插件作者私建小世界）。耦合还让通用能力
无法独立测试（P12："不带这个人设、能用 `dispatch/1` 复现吗？"）。render catalog 已经
证明了应有形态——其注释明确保留某些节点类型 *"so existing producers, **e.g. advisor**,
render"*（`apps/ezagent_domain_socialware/assets/js/catalog.mjs:52`）：render 路径
服务于任何产出合规树的生产者。

> 这是目前唯一还没单独成为台账条目的教训，请内化：**先把机制做成独立的（transport-only），
> 让业务 agent 去消费它。**

---

## 两个案例（逐一走通）

### A. `Entity.Salesperson` → role × flavor（或：只要机制）

- **发生了什么：** 为一个 chat agent 新增 own-Kind `Ezagent.Entity.Salesperson`。
- **为何是反模式：** 与 P4b 收编掉的 `Entity.PyAgent` Kind 一模一样；salesperson 和
  别的 agent 一样是 chat 参与者——并非新 core 概念（P9），新 Kind 破坏 P1/P24，且白送
  不想要的 principal 语义。
- **对齐形态：** 定义一个 **`salesperson` role recipe**，经 `roles/0` 注册；挂在已有
  flavor（`cc`/`codex`/`native`）上。照抄先例：
  - `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` ——
    `roles/0` 返回 `[kanban_manager_recipe()]`；`kanban_manager_recipe/0` 是
    `%{name:, behaviors:, requested_caps:, passive:}`。该 plugin **不声明 `kinds/0`**。
  - `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex` ——
    `native` flavor：`agent_flavors/0` 把 `"native"` 映射到
    `{Ezagent.Entity.Agent, …}`（**统一**宿主 Kind，**不声明**任何 role 专属内容）
    + 一个 `:cap_policy`，按 recipe 铸 cap、fail-closed。
- **如果这个 agent 只是 render 卡片的载体**（没有真实人设），更诚实的答案更小：**你根本
  不需要新 agent 类型**——直接交付 render 机制（案例 B），让任何已有 agent 向其生产。
  （P8：少一个概念。）

### B. "在 session 里渲染 json-render 卡片" → 机制 vs 生产者拆分

- **发生了什么：** json-render 卡片功能被建在 salesperson 业务人设 + `:salesperson`
  cap *之上*——把通用 transport 和单一生产者焊在一起。
- **对齐形态（正是 #1035 以 transport-only 合入的样子）：** render 路径是一个**与生产者
  无关的 transport**。消息在 **body** 里携带可选 json-render 树（`body["render"]` /
  `body["render_css"]`）；feed 编码器把它提升到 SPA，**无生产者耦合、无业务 cap**：
  - `apps/ezagent_web/lib/ezagent_web/socialware/feed_encoding.ex` ——
    `encode_messages/1` 对*每条*消息读 `body["render"]` / `body["render_css"]`。
    moduledoc：*"和 Surface page 同一套 spec 格式，为页面生成的片段可在消息里原样复用。"*
  - `apps/ezagent_plugin_world/assets/src/components/JsonRenderBubble.tsx` +
    `apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs` —— 单一
    renderer，和预览页同一套 `@json-render` catalog。
  - 生产者（salesperson、advisor、任何人）只需发一条 body 带 `render` 树的消息。无
    `:salesperson` cap；若确需一个 render *能力* cap，那也是**通用的**"可发 render 片段"
    cap，而非以人设命名。
- **下次可用的判别法：** 问"*advisor*（或任何别的 agent）不改动这条路径，能不能渲染卡片？"
  若不能，说明机制和生产者耦合了——拆开。

---

## 具体的 ezagent 抓手

**需加载的 skill**（任何 `apps/**.ex` 工作必带——不带则 subagent 写过时 Elixir 并无视
不变式，台账/feedback）：
- `ezagent-developer` —— 读 `references/design-principles.md`（这两个案例触及的是
  **P1、P8、P9、P11、P24**）、`references/anti-patterns.md`、
  `references/how-to-recipes.md`（§"add a new plugin"、§"add a Kind"）。
- `ezagent-socialware` —— 任何触及 customer/render/feed 表面的工作（`public_view`
  模板、ChatFeed/CustomerFeed、json-render SPA）。
- `elixir-phoenix-helper` —— 始终与 `ezagent-developer` 配对。

**起草前需读的架构文档**（台账 P0 设计对齐）：
- `docs/together/contributing/README.md` —— 台账红线（**P0–P3** 正是本文展开的同一次
  kanban 事件）。每次 handoff 前重读。
- role-foundation spec/plan：`docs/together/2026-06-25/specs/role-foundation-design.md`、
  `…/role-foundation-plan.md` —— "agent = role × flavor"在代码里的含义（#54）。
- 先例 spec：`docs/together/2026-06-25/specs/kanban-as-role-spec.md`（own-Kind →
  role × `native`，salesperson 本该做的同一动作）与 `…/py-agent-flavor-plan.md`
  （P4b own-Kind agent 类型统一）。
- `ARCHITECTURE.md` Decision Log + `GLOSSARY.md` 看原语（Kind / Behavior / Role /
  flavor / URI）。

**能提早拦住两者的评审闸——请使用它：** dev-together 流程是
**SPEC → codex 对抗评审 → plan → 实现**，*不是*先实现再开 PR。这两处违反都是设计层面的：
一段写着"我要加 `Entity.Salesperson` 并经它渲染卡片"的一段式 SPEC，会在*写任何代码之前*
就因 P1/P3/P9 被对抗评审打回（成本：几分钟 vs 一个需重构的可用 PR）。具体而言，任何
**触及 core** 的任务（新 Kind / Behavior / agent 类型 / render-或-feed 机制 / 路由 /
lifecycle）：

1. 写一段简短 SPEC（*为什么* + 你要碰的原语 + 一个 `/goal`）。
2. 对 SPEC 跑 codex 对抗评审，加载 `ezagent-developer`（涉 UI/render 再加
   `ezagent-socialware`）——静态评审，不跑 `mix`。
3. 与 lead 确认设计（台账 P0），再 plan，再实现。
4. 完成以不变式测试（P6）为闸，而非功能清单。

role-foundation 工作（RF-1..9）是该流程的正例——spec → 2 轮评审 → plan → 实现，
近乎零返工（台账 P2）。
