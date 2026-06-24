# 配置一个 agent 自动编辑 mindmap：配置机制、顺序、界面盘点

> 基线 worktree `df-tech`（`feat/df-tech`）。路径已定 = **路 A（agent claim 节点后 dispatch `mindmap.*`，@agent 触发）**，
> 出自 `docs/superpowers/specs/2026-06-23-agent-automation-and-outbound.md` §6。
> 本文只摸清"配置这套东西"的机制 + 顺序 + 界面现状，不实现。

---

## 0. 全局结论（先看这）

- **mindmap 是一个独立的「数据资源 Kind」**，URI 形如 `resource://<ws>/mindmap/<name>`，节点树住在它的 state（真相源）。
  它的动作处理者是 `Ezagent.Behavior.Mindmap`（`apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex`），
  14 个动作：`add_node` / `claim_node` / `set_status` / `attach_artifact` / `set_metric` / … 全是 `:call` 模式。
- **「让 agent 编辑 mindmap」≠ 在 agent 上挂 mindmap behavior**。mindmap 的 behavior 挂在 **mindmap Kind** 上，
  不是挂在 agent 上。agent 是经 `Invocation.dispatch` **打** `mindmap.*` 动作（agent 是 caller，mindmap Kind 是 target）。
- **路 A 要新建一个 agent 侧 Behavior `Ezagent.Behavior.Agent.MindmapWorker`**——**目前不存在**，
  只在 spec `2026-06-23-agent-automation-and-outbound.md:168` 被规划。这是路 A 唯一要写的代码。
  它 `use Ezagent.Lifecycle` + `action(:work_mindmap, ...)`，handler 收到任务消息后规则化地一串 dispatch `mindmap.claim_node`/`set_status`/`attach_artifact`，caller=agent 自己。

---

## 1. 正确的配置顺序（从零到「agent 自动编辑 mindmap」跑起来）

| # | 步骤 | 在哪做 | 依赖前一步什么 | 界面现状 |
|---|---|---|---|---|
| ① | **写 `MindmapWorker` Behavior 模块** | 代码：在 mindmap 插件里新建 `Ezagent.Behavior.Agent.MindmapWorker`，并在 `application.ex` 的 `behaviors/0` 把它 `{Agent_Kind, :work_mindmap, MindmapWorker}` 注册 | 无（纯新代码） | **无界面，纯写码**（一次性） |
| ② | **建一个 mindmap 实例（target）** | 运行时：spawn `EzagentPluginMindmap.Mindmap` Kind 实例（`resource://<ws>/mindmap/<name>`），或经 world 的 `/plugins/mindmap` 操作面建树 | ① 无关；只要 mindmap 插件装了 | **有界面**：world `/plugins/mindmap`（`components/Mindmap.tsx`） |
| ③ | **spawn worker agent（持 MindmapWorker）** | `mix ezagent.agent.create entity://agent/<ws>/<name> --flavor <flavor> --cwd <dir>`（CLI），或 world 创建表单 `/identities/agents/new`。两者共用 `Ezagent.Workspace.create_agent/3` | 需要 ① 的 Behavior 已编译进，agent Kind 才在它的 behavior set 里有 `:work_mindmap` | **有界面**：world `Identities.tsx:294` `AgentNewForm`（flavor/name/cwd/caps/with_pty） |
| ④ | **grant mindmap cap 给该 agent** | 走统一 grant chokepoint `Ezagent.Identity.Grant`。CLI 顺手：`mix ezagent.agent.create … --caps 'mindmap.claim_node,…'`（内部调 `Workspace.grant_initial_caps/3`） | 需要 ③ 的 agent_uri 存在 | **半缺**：CLI 创建时带 `--caps` 可一次性给；world **无独立 grant 表单**（只展示 caps + 可 revoke） |
| ⑤ | **配 routing rule：把 mindmap 任务消息路由给该 agent** | 会话视图右侧 ROUTING 面板「Add」，或 dispatch `session.routing.add` / `routing.add_rule` 动作。matcher 选 `mention`（@agent）或 `text_contains`，receivers 填 agent_uri | 需要 ③ 的 agent_uri（当 receiver） | **有界面**：world `Conversation.tsx:715` ROUTING 面板 |
| ⑥ | **触发：在会话里 @该 agent 发任务消息** | 会话发消息 @agent；routing 命中 → dispatch 给 agent → `agent.receive` → `MindmapWorker` handler 规则化 claim+编辑 mindmap | 需 ①②③④⑤ 全到位 | **有界面**：world 会话发消息框 |

> **cap 最省做法（强烈推荐）= claim-then-edit**：agent 只需 `mindmap.claim_node` 一个 cap。
> claim 之后该节点 `owner = agent_uri`，后续 `set_status`/`attach_artifact` 等靠 mindmap behavior 里
> 的 **per-node owner 检查** `owner_or_admin?`（`mindmap.ex:470`）自然放行，不必给一堆编辑 cap。
> 这跟你「节点被 claim 后才配 agent 编辑」的诉求完全吻合，也是最小权能面。

---

## 2. 四样配置的界面现状盘点（world React 前端）

源码：`apps/ezagent_plugin_world/assets/src/`（Vite/TS，已复刻并退役 LiveView）。

| 配置项 | 现状 | 位置 / 实证 |
|---|---|---|
| **① 创建 agent** | ✅ **有完整界面** | `Identities.tsx:294` `AgentNewForm`，入口 `/identities/agents/new`；字段 flavor / name / cwd / caps / with_pty；提交 → `agents.create` → 后端 `Workspace.create_agent/3`（与 `mix ezagent.agent.create` 同一条路） |
| **② behavior 挂载** | ⚠️ **无界面（也基本不需要 UI）** | agent 的 behaviors 在 **agent Kind 的 `behaviors/0` 里声明**（`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:86`，base set 见 `:97`），是**编译期模块级声明**，不是运行时挂载。`MindmapWorker` 要加进 agent 的 behavior set 就是改这处代码（步骤①），没有也不该有「给某 agent 挂 behavior」的表单。前端 `Identities.tsx:247` 只有一列 `behavior` 是**展示** caps，不是配置 |
| **③ cap grant** | ⚠️ **半缺**：能展示+能撤销，**不能在前端新建 grant** | 展示：`Admin.tsx:328` CapsAdmin（grantable / default_grants 只读）、`WorkspacePlugin.tsx:329` AutoDerive（credential cascade）。撤销：`WorkspacePlugin.tsx:480` Revoke 按钮（`credential_grant.revoke`）。**新建 grant 当前只能走 CLI** `--caps`（→ `grant_initial_caps`）或后端 dispatch。唯一收口 = `Ezagent.Identity.Grant`（`apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`，`{:held_by}`/`{:admin}` 等四种 authorization tag 派生 granter） |
| **④ routing 配置** | ✅ **有完整界面** | `Conversation.tsx:715` 会话右侧 ROUTING 面板。表单字段：matcher type（**always / mention / from / text_contains**）+ matcher argument + receivers（逗号/空格分隔 URI）+ Add。已有规则列表带 enable/disable toggle。提交 → `session.routing.add`（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:81`）→ 后端 `Behavior.Routing.add_rule`（`apps/ezagent_core/lib/ezagent/behavior/routing.ex:91`） |

**routing 能不能配「@某 agent → dispatch 给它」？能，完全支持。** matcher 选 `mention`、argument 填 agent 的 entity URI、
receivers 填同一个 agent URI 即可。底层 `{:mention, uri}` matcher 比对 `message.mentions`（`matcher.ex:142`），
另有 `$mentions` magic token 做 mention-gated 路由（`resolver.ex:328`）。规则持久化在 SQLite `routing_rules` 表
（`rule_store.ex:36` 共 12 字段），boot 时 `DefaultRules.bootstrap/0` → `RuleStore.load_into_registry/1` hydrate 进 ETS
（`default_rules.ex:103`，对应最近 commit `be6c59f4`）。

---

## 3. 最关键的待补界面 / 待决策

1. **【代码，非界面，必做且唯一阻塞】写 `Ezagent.Behavior.Agent.MindmapWorker`**——路 A 的全部新代码就这一块。
   目前**不存在**（spec `2026-06-23-agent-automation-and-outbound.md:168` 仅规划）。它决定了步骤①③能不能跑。
   纯 plugin Behavior，**不碰 MCP 工具锁、不需要 Allen 改架构**。

2. **【界面缺口】world 没有「给已有 agent grant cap」的表单**。现状 grant 只能在「创建 agent 时」用 CLI `--caps` 一次性给，
   或后端 dispatch。同事做配置 UI 时，**这是最值得补的一块**：一个「选 agent → 选 cap（如 `mindmap.claim_node`）→ grant」
   的表单，后端接 `Ezagent.Identity.Grant`（chokepoint 已就绪）。否则 PoC 里给 worker agent 发 mindmap cap 只能命令行。

3. **【非路 A，留意别走偏】真要让 claude「智能想」= 路 B**，要加 `mindmap_edit` MCP 工具，**那条要暂停等 Allen**
   （扩 orchestrator 权能边界 = Decision，工具集 `tools.ex:81` 故意上锁）。**路 A 的规则化编辑不碰这块**——
   只适合「收到 PR webhook → set_status done」这类规则化自动编辑，不做 LLM 决策。配置 UI 范围内不涉及。
