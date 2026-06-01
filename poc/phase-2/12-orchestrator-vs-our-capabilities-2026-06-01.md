# 任务 4 —— (rebase 后的) orchestrator 能否替代我们的能力?(soul 编辑 / 接管)

> 2026-06-01。针对合并后的 `poc/phase-2-customer-service`(HEAD b3c95bf0,已合入
> ezagent main)调研。来自 PR #446 规划的问题:最新的 orchestrator 代码是否已经提供了
> 我们已建 / 在建的东西,以至于 **admin-edit-soul 的 scope #1 应该重构到 orchestrator
> 原语上**,而不是用我们基于文件的 `SoulStore`?
>
> **结论:不能。** 保持 scope #1 的 `SoulStore` 设计不变。orchestrator 既不编辑 soul
> 文本,也不处理接管;它是另一种(LLM 驱动的、做 session 组合的)抽象,而且根本不在我们的
> soul / 消息路径上。细节 + 唯一一个真正的收敛点(已推迟)见下。

## 被质疑的两个能力
1. **可编辑 soul**(scope #1,`11-admin-edit-soul-design.md`):人类管理员在 UI 里编辑某租户
   的客户 soul markdown → 保存 → 新会话使用它。实现为:`SoulStore`(文件
   `edited→fixture→nil`,write/revert/reset)+ `ConfigLive` + `ConfigAuth`(workspace-admin
   cap)。生效方式:cc 在 spawn 时读 `soul_path` → `--append-system-prompt-file`。
2. **接管**(`Ezagent.Behavior.Mode`,本 session 已迁移到 Lifecycle):operator 替代 AI;
   对 session `:mode` slice 做 `:set`/`:get`;`Chat` 在 `:takeover` 时抑制 agent-sender 的
   fan-out。

## orchestrator 究竟是什么
一个**子系统**(`apps/ezagent_domain_chat/lib/ezagent/orchestrator/*`),不是单个 behavior。
它是一个 **LLM 驱动**的引擎:每个 session 一个 cc-orchestrator claude 实例,调用 **7 个 MCP
工具**来组合 + 路由 *worker* agent:

| 工具 | 作用 |
|---|---|
| `add_agent_slot(slot, template_uri, prompt_override?)` | 从 AgentTemplate 在某 slot 上 spawn 一个 worker(reconciler,幂等) |
| `remove_agent_slot(slot)` | 终止 worker + 清理路由 |
| `update_agent_template(slot, new_template_uri)` | 把一个 slot **换**到*另一个已存在*的模板 |
| `write_matcher(ast, receivers)` | 加一条 session 路由规则 |
| `update_template()` / `save_template_as(name)` | 把**当前 session 组合**快照为新的 / fork 的 SessionTemplate 版本 |
| `list_templates(filter?)` | 发现模板(经 CapBAC 过滤) |

外加 `Behavior.OrchestratorAdmin` = 一个**仅 cap** 的门禁(`:restart`),基于 session-owner
权限。orchestrator 工具是 **仅 MCP / 对人类 operator 不可见**的
(见 `docs/notes/agent-orchestrator-ui-audit-2026-05-23.md`)。

## soul 编辑 —— orchestrator 做不到(证据)
- `add_agent_slot` 的 `prompt_override` 是一个**显式 no-op**:*"为与 SPEC 的 API 对齐而接受,
  但并不被消费 —— worker 的 prompt 来自它 AgentTemplate 的 `claude_config_dir/settings.json`
  (Decision #136)"*(`orchestrator/tools.ex:155-163`)。
- **没有任何 orchestrator 工具编辑 prompt 文本。** `update_agent_template` 只是*把一个 slot
  指向另一个已存在的模板 URI*;`update_template`/`save_template_as` 快照的是 **session 组合**
  (有哪些 slot + 路由),不是某个 agent 的 system-prompt 内容。
- 唯一能改动 agent 行为文本的是 **AgentTemplate 内容**(`Behavior.Template :write`,整模板
  替换)—— 这是一个*独立的*、粗粒度的 behavior,完全没有 scope #1 的
  per-`(tenant,role)` `edited/fixture/prev/reset` 语义,也没有 workspace-admin cap 门禁。
- 我们的 soul 模型在*类型*上根本不同:soul = 一个 per-`(tenant,role)` 的 **markdown 文件**,
  在 spawn 时按 `edited→fixture` 解析并经 `--append-system-prompt-file` 注入
  (`cc_agent.ex:1146`);管理员在 textarea 里编辑 markdown。orchestrator 没有对应物,也没有
  人类编辑界面。

**⇒ orchestrator 做不了 scope #1。要重构到它上面,首先还得先把缺失的"编辑 prompt 文本"
原语建出来。**

## 接管 —— orchestrator 不做这个(正交)
Mode 是一个**session 级** behavior(`:mode` slice);orchestrator 对它无感知,也不是一个
"被接管"的参与者。它们本就正确地共存。无需改动;**不要**把接管走 orchestrator。

## 决定性的架构事实:orchestrator 根本不在我们的路径上
`bootstrap.ex:74-86`:我们的客户会话调用 `EzagentDomainChat.create_session/3`,它
**无条件为每个 session spawn 一个 cc-orchestrator**(Phase-7
"session-create-orchestrator-unified")—— **但我们的代码从不驱动它;orchestrator 闲置在那
(每个 session 多一个 claude PTY)。** 真正的客户 cc agent 是由**我们的**
`ensure_cc_for_conv → Workspace.create_agent(..., soul_path)`(`bootstrap.ex:114-167`)
spawn 的,*不是* `add_agent_slot`。所以 orchestrator 既不在我们的 soul 路径上,也不在我们的
消息路径上 —— 今天它就是闲置的死重(已追踪:REVISIT,向 Allen 申请一个
`create_session(orchestrator: false)` 的 opt-out)。

## 结论与对 PR #446 / scope #1 的影响
1. **scope #1 保持 `SoulStore`(基于文件)。** orchestrator 不提供 soul 文本编辑,是
   LLM-/MCP-驱动的(不是人类管理界面),采用它会把整个 AgentTemplate/SessionTemplate 的
   **版本化**界面拖进来,而那正是 scope #1 §11 *明确推迟*的 —— 也就是设计的"渐进式红线"
   所禁止的 cargo-culting。轴也不对(session 组合 vs 租户级配置)。
2. **接管保持 `Mode`。** 已迁移 + 正确;与 orchestrator 正交。
3. **唯一真正的收敛点 —— 推迟,不是现在。** *如果 / 当* scope #2+ 想要**版本化 soul +
   A/B 变体 + 原地切换**时,ezagent 原生的"通过版本化改变 agent 行为"原语是
   **AgentTemplate + `update_agent_template`** —— 到那时收敛到这里,而不是另建一套平行的
   版本存储。scope #1 的 `.prev` 单步撤销刻意保持基于文件;模板路径是完整版本历史的未来归宿。
4. **值得单独立项的清理(与 soul 无关):** 每个客服 session 闲置的 orchestrator PTY 浪费 ——
   向 Allen 申请 `orchestrator: false` opt-out。考虑到 boot 风暴 / 绑定压力,这点格外重要。

## 这对任务 3(PR 拆分)的启示
soul 编辑切片(`SoulStore`/`ConfigLive`/`ConfigAuth`)立足于它**自己的** ezagent 原语
(cc `soul_path`、能力模型),对 orchestrator **零依赖**。它可以拆成自己独立的可 review PR,
没有任何 orchestrator 耦合的附带说明。接管切片(`Mode` + `Chat` 门控 + operator dashboard)
同样独立于 orchestrator,也能干净地单独拆出。
