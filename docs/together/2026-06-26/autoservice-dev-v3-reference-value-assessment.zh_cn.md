# autoservice-dev-v3 对后续实施的参照价值评估

日期：2026-06-26

当前分支：`feat/autoservice-verify-20260626`

参考分支：`autoservice-dev-v3` / `origin/autoservice-dev-v3`

参考提交：

- `0b6eeaec chore(autoservice): sync E2E screenshots, scripts, and minor tweaks`
- 关键前序提交包括：
  - `7e16eadc feat(autoservice): add AgentConfig module — registry + templates`
  - `b8c7407b feat(autoservice): add AgentConfig.create/3, delete/2, agent_to_map/1`
  - `a73775a4 feat(autoservice): add DebugSession — sandbox agent lifecycle`
  - `8892e175 fix(autoservice, session): chat flow — agent now responds to customer messages (4 bugs)`

## 1. 总体结论

`autoservice-dev-v3` 仍有 **中等偏高的设计参照价值**，但 **代码直接复用价值偏低**。

原因：

- 该分支的核心思想是正确的：把 AutoService 从 hardcoded fast/slow 页面，转成 `AgentConfig` 注册表、动态 admin UI、DebugSession、ContentAdmin 写入、customer/operator session flow。
- 但当前 `main` 的架构已经明显前进：
  - `ezagent_plugin_autoservice` 当前不存在。
  - `ezagent_plugin_liveview` 当前仍在仓库中，但已被 invariant 视作 retired。
  - 活跃管理台已经转向 `ezagent_plugin_world`：React/shadcn shell + typed-slot registry + `component_state` 数据构建 + `world:dispatch` mutation。
  - 当前 main 已有更通用的 `Ezagent.Agent.Config` facade，用 `read_cascade/apply_delta/delete_path/repoint` 管理 agent config，比 v3 的 `sandbox/config/agents.yaml` 更贴合现在的 config evolution 架构。

所以后续实施建议：

- **不要 rebase/merge autoservice-dev-v3。**
- **不要照搬 v3 的 LiveView 页面。**
- **可以吸收它的领域拆分、UX 流程和测试场景。**
- **实现时应落到当前 main 的 world typed-slot、domain_session、domain_agent、ConfigEvolve、public/socialware 这些现有结构上。**

## 2. v3 当初的设计思想

### 2.1 Agent 配置组件化

v3 的目标是替换硬编码的 `FastAgentLive` / `SlowAgentLive`：

- `AgentConfig` 管理 agent registry。
- 每个 agent 有 `sections`，例如 `:soul`、`:slots`、`:skills`、`:kb`。
- UI 根据 `sections` 动态渲染 tab。
- Sidebar、Debug Agent、Orchestrate、Overview 都从 `AgentConfig.list/1` 读取 agent 列表，而不是写死 fast/slow。
- 新 agent 通过 template 创建 skeleton。

这个方向仍然有价值：AutoService 真实线上不是一个固定 fast/slow demo，而是应该支持按租户、按 agent、按能力 section 组织配置。

### 2.2 ContentAdmin 作为写入边界

v3 计划所有 admin 写操作都走 ContentAdmin dispatch：

- `write_agents_yaml`
- `create_agent_skeleton`
- `delete_agent_skeleton`
- soul/slots/skills/kb 写入

这个思想仍然正确：Admin UI 不应直接写文件或数据库，必须通过 capability-gated 行为入口。

但当前 main 更成熟的表达方式应是：

- agent 通用配置走 `Ezagent.Agent.Config` facade。
- 业务内容写入可以新建 AutoService/KB/Content domain 或 plugin 行为。
- world UI 只做 `component_state` read + `world:dispatch` mutation，不直接写底层 store。

### 2.3 Admin Session 驱动

v3 有 `AdminSessionLive`，把 admin 操作做成聊天式界面：

- 管理员输入自然语言命令。
- `AdminAgent` parse intent。
- 生成 CR status / publish result card。

这个方向有产品参照价值，尤其适合后续做：

- Admin copilot。
- CR 审核助手。
- KB 变更解释。
- 发布前检查。
- “为什么这个 tenant 回复异常”的诊断。

但 v3 实现本身较弱：

- 消息只存在 LiveView assign，未持久化。
- intent parser 只是关键词匹配。
- `publish` 等操作有 stub / fallback。
- 没有接入当前 world 的 typed-slot 和 command/action 体系。

因此它应作为 UX 原型，不应作为代码基础。

### 2.4 DebugSession / sandbox vs release 对比

v3 设计了 `DebugSession`：

- sandbox agent URI 固定生成。
- release agent 走生产 agent。
- 尝试复制 API key。
- 对 sandbox/release 各发一条消息，对比响应。

这个思想对 AutoService 后续非常重要，因为真实线上 AutoService 有 sandbox preview / publish / release 概念。

但 v3 代码明显是半成品：

- `do_provision_sandbox/4` 最终只是 `{:ok, uri}`。
- `ensure_debug_session/2` 不真正创建 session。
- release URI 还写死为 `entity://<tid>/agent/cc_slow-<tid>`。
- key transfer 方案需要重新按当前 credential/cap model 审计。

保留设计，不保留实现。

### 2.5 Customer / Operator session 驱动

v3 的 `CustomerSession` 和 `CsOrchestrator` 试图把客服场景映射到 ezagent session：

- customer session 是普通 Session Kind。
- fixed fast/slow team，不使用通用 session orchestrator generator。
- customer message 触发 Turn.open。
- operator claim 时 cancel bot turn、open fresh turn、compose、claim。
- operator settle 后恢复 bot fan-out。

这个模型和本次真实 AutoService E2E 的核心场景高度相关：

- customer 发消息。
- agent 回复。
- operator 接管。
- operator release。
- session/message/history 持久化。

但当前 main 已有新的 session/orchestrator/member_template/read_marker/socialware 结构，v3 的实现依赖当时的 URI、routing、TurnDriver、LiveView 插件状态，不能直接复用。

应提取成后续 AutoService 复现的业务状态机需求，而不是照搬代码。

## 3. 当前仍有参照价值的部分

| v3 内容 | 参照价值 | 建议 |
| --- | --- | --- |
| `AgentConfig` 的 registry/sections/template 思路 | 高 | 作为 AutoService agent/domain 配置模型输入 |
| dynamic sidebar / dynamic agent tabs | 高 | 用 world typed-slot + React 组件重做 |
| ContentAdmin dispatch 作为写入边界 | 高 | 保留原则，换成当前 facade/domain |
| Admin Session 聊天式管理 | 中高 | 做成 world slot 或 session/coplanar admin copilot |
| DebugSession sandbox/release 对比 | 中高 | 重设实现，接 current session + agent config + credential |
| CustomerSession fixed team，不走 heavy orchestrator | 中 | 可作为客服场景性能假设 |
| CsOrchestrator operator claim/settle 状态机 | 中 | 抽成 AutoService takeover/release domain spec |
| ChatUI message/composer function components | 中低 | UI 细节可参考，但当前 world/React 已替代 |
| v3 E2E 脚本和截图 | 中 | 可用于理解当时目标流程，不作为通过证据 |

## 4. 不建议复用的部分

### 4.1 不建议复用 LiveView UI 文件

v3 的 UI 在：

- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/...`

当前 main 的方向是：

- `apps/ezagent_plugin_world/lib/ezagent/world/*`
- `apps/ezagent_plugin_world/assets/src/components/*`
- `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex`

`ezagent_plugin_liveview` 当前还触发 retired invariant；继续在里面开发 AutoService UI 会和主线方向冲突。

### 4.2 不建议复用 `sandbox/config/agents.yaml` 作为主配置 SoT

v3 用 `sandbox/config/agents.yaml` 管理 agent registry。

当前 main 已经有：

- `Ezagent.Agent.Config.read_cascade/4`
- `apply_delta/4`
- `delete_path/4`
- `repoint/4`
- `ConfigEvolve`
- immutable config object + pointer/repoint 机制

所以 AutoService 的 agent 配置应映射到当前 config cascade，而不是回退到单 YAML 文件。

### 4.3 不建议复用 `AdminAgent` 的关键词 parser

`AdminAgent` 当前只是：

- 包含“发布” -> publish CR
- 包含“检查” -> check status
- 否则 unknown

这不够支撑真实 admin copilot。后续如果做 Admin Session，应接入：

- 明确 action catalog。
- schema validated commands。
- dry-run / confirmation。
- audit log。
- capability check。
- 非修改性操作和修改性操作分离。

### 4.4 不建议复用 DebugSession 的 key transfer 实现

v3 的 `ensure_api_key/3` 尝试从生产 slow agent 取 plaintext key，再写入 sandbox agent。

这个方向安全风险较高，也不一定符合当前 credential 设计。后续应重新设计：

- sandbox agent 需要什么 provider key。
- 谁有权复制/引用。
- 是否使用 credential reference，而非 plaintext copy。
- 是否只允许本地/dev 模式。

## 5. 和当前 main 的对应落点

### 5.1 组件化 UI 的落点

v3 的 `AgentConfigLive` 应映射到当前：

- `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex`
- `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`

当前 main 已经有 `agent_config` slot：

- slot registry 注册 `"agent_config"`。
- route 能解析到 `component: "agent_config"`。
- `IdentityData.component_state/5` 调用 `Ezagent.Agent.Config.read_cascade/4`。
- `agent_actions.ex` 处理 `agents.config.update/delete_path/repoint`。
- React 侧已有 `AgentConfigEditor`。

结论：v3 的 `AgentConfigLive` 不需要迁移；应继续扩展 current world 的 `agent_config` slot。

### 5.2 Agent 配置模型的落点

v3 的 `AgentConfig.default_templates/sections/worker` 可转成当前 config key，例如：

- `autoservice.agent.registry`
- `autoservice.agent.sections`
- `autoservice.agent.worker`
- `autoservice.customer.routing`
- `autoservice.operator.takeover`

这些 key 通过 `Ezagent.Agent.Config` 管理，而不是放在 `agents.yaml`。

### 5.3 Admin Session 的落点

可选落点：

1. world 新增 slot：`autoservice_admin_session`
2. domain_session 新增一个 admin copilot session template
3. protocol API / command palette action 接入

建议优先做 world slot，而不是 LiveView：

- Elixir 侧提供 `component_state`。
- React 侧渲染聊天式 admin surface。
- 修改性 command 走 `world:dispatch`，并强制 confirm。

### 5.4 Operator takeover 的落点

v3 的 `CsOrchestrator.operator_claim/operator_settle` 应转成后续 AutoService domain spec：

- session state：`auto/copilot/takeover`
- customer-visible vs operator-only message visibility
- claim cancels/pauses bot turn
- release resumes routing
- idle release / timeout
- event log / audit

实现时应基于当前 `domain_session`、`Turn`、`Session.Membership`、`routing`，而不是旧 v3 的 direct file/LiveView coupling。

## 6. 参照价值评分

| 维度 | 评分 | 说明 |
| --- | --- | --- |
| 产品流程设计 | 75/100 | 覆盖 agent config、debug、admin session、operator flow，和真实 AutoService 场景相关 |
| 领域建模 | 65/100 | `AgentConfig`/`DebugSession`/`CsOrchestrator` 拆分方向正确，但边界较粗 |
| UI 组件化思想 | 70/100 | dynamic sections/tabs/sidebar 值得保留，但 LiveView 载体已过时 |
| 代码可直接复用 | 25/100 | 当前 main 架构变化太大，直接移植会制造冲突 |
| 测试/E2E 脚本价值 | 45/100 | 可参考流程，但不能作为当前通过证据 |
| 安全/权限设计 | 40/100 | ContentAdmin dispatch 思路好，但 key transfer、publish command、admin chat 都需重审 |
| 和当前 main 兼容度 | 30/100 | autoservice plugin 不在 main，liveview plugin retired，world 已替代 |

综合：**设计参照 65/100，代码复用 25/100。**

## 7. 后续实施建议

### 7.1 可以直接吸收为需求的内容

1. AutoService agent registry 不应 hardcode fast/slow。
2. Admin 应能按 agent 动态展示 sections。
3. Debug 应能比较 sandbox/release。
4. Operator takeover/release 应是显式状态机。
5. Admin copilot 可以作为聊天式入口，但修改性操作必须有 confirm/audit。

### 7.2 不应照搬的内容

1. 不要恢复 `ezagent_plugin_autoservice` 原样代码。
2. 不要继续在 `ezagent_plugin_liveview` 下扩展 AutoService UI。
3. 不要用 `sandbox/config/agents.yaml` 当主配置真源。
4. 不要复制 production key 到 sandbox agent，除非重新做安全设计。
5. 不要用关键词 parser 承担真实 admin publish。

### 7.3 推荐实施路径

第一阶段：AutoService 业务模型落到当前 ezagent

- 新建或恢复一个轻量 AutoService domain/plugin，但只放业务语义，不放旧 LiveView。
- 定义 `autoservice.agent.registry`、`sections`、`worker`、`routing` config schema。
- 用 `Ezagent.Agent.Config` 做配置读写。

第二阶段：world UI 扩展

- 新增 AutoService 相关 typed slots。
- React 组件按 v3 的 tab/section 体验重做。
- 所有 mutation 走 `world:dispatch`。

第三阶段：真实客服 session 状态机

- customer public/anonymous session。
- operator takeover/release。
- sandbox/release debug。
- General Bot/protocol API 映射。

第四阶段：高成本能力单独立项

- KB ingestion/vector search。
- Dream/CR/publish/release archive。
- Voice ASR/TTS。
- Attachments。
- SLA/CSAT/billing。

## 8. 最终判断

`autoservice-dev-v3` 最大价值不是代码，而是它记录了一个重要转向：**AutoService 不应是 fast/slow 两个页面，而应是 agent registry + section-driven admin + session-driven operations 的客服业务层。**

这个思想今天仍然成立。

但后续实施必须按当前 main 的架构重做：

- UI 用 `world` typed-slot。
- 配置用 `Ezagent.Agent.Config` / config cascade。
- session 用当前 `domain_session`。
- 权限和修改性操作走 current CapBAC/dispatch。

因此它适合作为“需求和设计参考”，不适合作为“代码移植来源”。
