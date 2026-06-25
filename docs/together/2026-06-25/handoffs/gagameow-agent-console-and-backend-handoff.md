# Handoff — 整个 agent console + 后端现状 handoff（gagameow / 黄佳佳）

> **任务**: ①给 `allenwoods` 的后端整合任务写一份现状分析 handoff（先做）②接管并做完整个 agent console（UI + config 面板 + 对接 domain.agent）。
> **分支**: `feat/agent-console`（off `main`，保持 rebase）+ handoff 文档
> **本周目标**: 团队日用（目标①）—— operator 能在 console 配置 agent。

## A. 后端现状分析 handoff（先做，解锁 `allenwoods`）
为 `allenwoods` 的"agent 运行时后端整合"写一份 `docs/together/2026-06-25/handoffs/agent-runtime-situation.md`，覆盖：
- **cc-headless sidecar**（#931，`apps/ezagent_plugin_cc`）：现在怎么起、怎么收发、生命周期。
- **protocol_api**（`apps/ezagent_plugin_protocol_api`）：conversation_registry / openai_chat_plug 现在怎么 spawn/lookup agent + session。
- **LocalRuntime**（`apps/ezagent_core/lib/ezagent/local_runtime.ex`，#95）：现有 facade（`kind_alive?`/`ensure_started`，URI-only，无 args/behaviors arity）。
- **接缝 + 未决问题**：三者怎么拼；echo→Entity.Agent（#918）需要 LocalRuntime 带 behaviors 的 spawn —— 现 facade 不支持，这是关键决策点。
- 你认为该怎么整合（建议），供 `allenwoods` 厘清后定方案。
> 这是 clarify-first 的前相产出 —— `allenwoods` 拿到它才动手。

## B. 整个 agent console（接管 `FatNine` 的 #958 之后）
console 现在在 `apps/ezagent_plugin_world/.../Identities.tsx`：`IdentitiesSurface` 外壳按 `state.component` 路由到 列表 / `agent_detail` / `agent_config`。**你接管全部**：
1. **UI 界面**：列表/详情/创建/删除 + config 面板，做完整、好用。
2. **config 面板**：从通用 kv 编辑器升级到**结构化每字段编辑**（"operator 能配每个字段"），走 `AgentConfig` facade（#938 + #966 加固）。
3. **对接 `domain.agent`**：把 console 接到 domain.agent 原语；**凡是当前下探/打通不了的，UI 上显式标注"还没接线"**（不留隐藏假象）。

## DoD（四性质）
- [ ] **A handoff 文档**落地，覆盖上面要点（`allenwoods` 能据此厘清方案）。
- [ ] **console 全功能可用**：create/查/改**每个配置字段**/删，且**对接 domain.agent**；未接线处显式标注。
- [ ] **在用户面验证**：每条 CRUD + 配置编辑有**挂路由的 LiveViewTest**（不是只在后端 dispatch seam）—— 这是 #958 欠的回归保护，本任务补上；+ agent-browser 截图。
- [ ] echo 配置依赖 echo 接入（#918），未就绪则标"待 echo 接入"（lead 裁定的延期，不算缺）。
- [ ] **CI 绿** + rebase 到当前 main。

## 关键文件
- console：`apps/ezagent_plugin_world/assets/src/components/Identities.tsx` + 相关 world_live/routes
- 后端 facade（只读对接）：`apps/ezagent_domain_identity/lib/ezagent/agent_config.ex`（+ `behavior/config_evolve.ex`）
- handoff 输出：`docs/together/2026-06-25/handoffs/agent-runtime-situation.md`

## 必读
- skill `ezagent-developer` + `ezagent-socialware`；`docs/guide/world-coordination.md`（world 区，与 `zhaomaota97`/`zyli-developer` 协调声明面）
- dev-together skill（DoD 四性质；UI 必须用户层测试；返还前 rebase+自测绿）

## 注意
- console 由你单一所有（避免之前 fatnine/gaga 分面板的接缝冲突）。
- 先出 A 的 handoff（`allenwoods` 在等），再做 B。
