# Socialware 完成度评估 + Autoservice/Loom 迁移分析

> 评估日期: 2026-06-08
> 基线: `github/main` @ `e6d372ec`
> 分析范围: socialware 当前完成面、autoservice(`autoservice`分支)迁移要做的事、loom(`feat/loom`分支)迁移要做的事、socialware对原autoservice customer/operator/admin的覆盖度

---

## 一、Socialware 当前完成度（逐个模块）

### 1.1 Behavior.Turn（499行，52个测试全部通过）

完成度: **90%** — 状态机核心逻辑完整，但缺少与真实 agent 的端到端集成验证。

| 功能 | 状态 | 备注 |
|---|---|---|
| `turn.open(trigger, opened_at)` | ✅ 完成 | 创建 turn，分配单调 turn_no |
| `turn.dispatch(turn_id, subtasks)` | ✅ 完成 | 记录 expected，对每个 subtask 发 `chat.send` dispatch（带 correlation） |
| `turn.deliver(turn_id, subtask_id, card_ref)` | ✅ 完成 | 收集 worker deliverable，并发安全（turn_id-keyed） |
| `turn.compose(turn_id, result_refs)` | ✅ 完成 | 写 chat 消息（带 `visibility`），dispatch `surface.put_version` |
| `turn.claim(turn_id, by: user_uri)` | ✅ 完成 | 切换 owner+mode→copilot，调 `hold_visibility` 翻转已有消息为 `:operator_only` |
| `turn.settle(turn_id)` | ✅ 完成 | 状态转换守卫 + `prepare_settlement` → `Settlement.begin` + `Settlement.flip_visibility` |
| `turn.cancel(turn_id)` | ✅ 完成 | 从任何非终端状态取消 |
| 状态机守卫 | ✅ 完成 | 终端状态拒绝所有操作；`open→compose` 仅当 zero-expected（degenerate single-bot turn） |
| 多 turn 并发 | ✅ 完成 | turn_id-keyed，两个同时打开的 turn 不会交叉 |
| 冷重启存活 | ✅ 完成 | snapshot 持久化 + LifecycleCase 测试 |
| `config_delta` 提取 + dispatch | ✅ 完成 | compose 结果中含 `config_delta` 时自动 dispatch `config_update.apply_delta` |
| `page_tree` 提取 | ✅ 完成 | 从 collected + result_refs 中提取 kind=page 的 tree |
| **与真实 agent 集成** | ❌ 未验证 | 从未有 cc/codex agent 通过 tool use 调用 `turn.open`/`turn.dispatch` |

### 1.2 Behavior.Surface（127行）

完成度: **85%** — 核心逻辑完整，但只有 operator HEEx 渲染，无 customer 前端。

| 功能 | 状态 | 备注 |
|---|---|---|
| `surface.put_version(turn_id, tree)` | ✅ 完成 | 追加不可变版本，version_seq 单调递增 |
| `surface.approve(version)` | ✅ 完成 | 设置 approved 指针，拒绝不存在的版本 |
| `surface.commit_settlement(turn_id)` | ✅ 完成 | 调 `Settlement.commit_after_pointer`，检测 CAS 冲突 |
| `operator_tree(surface)` | ✅ 完成 | 返回 latest 版本（操作员看草稿） |
| `customer_tree(surface)` | ✅ 完成 | 返回 `versions[approved]`（客户只看已批准） |
| `latest_version(surface)` | ✅ 完成 | 返回最大版本号 |
| 不可变性守护 | ✅ 完成 | `put_version` 拒绝已存在的版本号 |
| **跨 Behavior dispatch 接线** | ⚠️ 部分 | `turn.compose` 通过 `{:dispatch}` effect dispatch `surface.put_version`；`turn.settle` dispatch `surface.approve` — 这是正确路径。但需要真实 integration test 验证 |

### 1.3 Settlement（238行 + SettlementRecord + SettlementMessage）

完成度: **85%** — 持久化结算逻辑完整，崩溃重放就绪。

| 功能 | 状态 | 备注 |
|---|---|---|
| `begin(attrs)` | ✅ 完成 | 创建 pending settlement + 写入 SettlementMessage 关联 |
| `flip_visibility(turn_id)` | ✅ 完成 | 将关联消息的 visibility 设为 `:customer_visible` |
| `hold_visibility(turn_id)` | ✅ 完成 | 将关联消息的 visibility 设为 `:operator_only`（copilot 用） |
| `mark_pointer_advanced(turn_id, approved_version)` | ✅ 完成 | 含 CAS: `expected_prior_approved` 不匹配→`:approved_pointer_conflict` |
| `commit_after_pointer(turn_id, approved_version)` | ✅ 完成 | `:committed` 最后设置（after visibility flip + pointer advance + outbox emit） |
| 子写入追踪 | ✅ 完成 | `subwrites_done: [:visibility_flipped, :pointer_advanced, :outbox_emitted]` |
| 崩溃重放 | ✅ 完成 | replay 算法: 读 settlement → 补完缺失的 sub-write → 设 `:committed`（idempotent） |
| 事务 outbox | ✅ 完成 | `CustomerOutbox` 表 + `emit_outbox_once`（`on_conflict: :nothing` 防重复） |
| PubSub 客户投递信号 | ✅ 完成 | `:committed` 后 broadcast `{:customer_delivery, %{message_ids: ids}}` 到 CustomerFeed topic |
| **跨存储原子性** | ⚠️ 设计正确但待实战 | 消息（MessageStore）和页面（:surface snapshot）是分开存储的。Settlement 的 `:committed`-last 模型是正确的，但从未在真实 crash 场景验证过 |

### 1.4 Message.visibility + MessageStore API

完成度: **100%** — Schema 变更、迁移、API 全部就绪。

| 功能 | 状态 | 备注 |
|---|---|---|
| `Message.visibility` 字段 | ✅ 完成 | `:customer_visible \| :operator_only`, default `:customer_visible` |
| 迁移 | ✅ 完成 | `20260618000400_add_message_visibility_and_socialware_settlements.exs` |
| 向后兼容 | ✅ 完成 | legacy 消息默认 `:customer_visible` |
| `MessageStore.committed_customer_visible/2` | ✅ 完成 | 只返回 visibility=`:customer_visible` AND settlement=`:committed` 的消息 |
| `MessageStore.mark_visibility/2` | ✅ 完成 | 幂等设置一批消息的 visibility |

### 1.5 CustomerFeed + CustomerAuth（54+52行）

完成度: **60%** — 后端 API 就绪，但**没有任何前端或 streaming endpoint 消费它**。

| 功能 | 状态 | 备注 |
|---|---|---|
| `CustomerFeed.snapshot(session_uri, token)` | ✅ 完成 | gated query（committed + customer_visible）+ customer_tree |
| `CustomerFeed.history(session_uri, token)` | ✅ 完成 | 同上（不含 page） |
| `CustomerFeed.topic(session_uri)` | ✅ 完成 | PubSub topic for customer delivery signals |
| `CustomerAuth.authorize(token, session_uri, workspace_uri)` | ✅ 完成 | session-binding token → scope check |
| **P4 streaming endpoint** | ❌ 未实现 | spec §4.4 描述的 React/json-render streaming endpoint 完全不存在 |
| **session-binding token 签发** | ❌ 未实现 | CustomerAuth 验证 token，但没有 token 签发逻辑 |
| **ExternalMirror visibility filter** | ❌ 未实现 | spec §4.3 提到 ExternalMirror 应增加 optional visibility filter |

### 1.6 ConfigStore + ConfigUpdate（305+382行）

完成度: **写入侧 100%，消费侧在 `feat/socialware-config-consume` 未合并**。

| 功能 | 状态 | 备注 |
|---|---|---|
| `ConfigStore.write_config(attrs)` | ✅ 完成 | 写不可变 ConfigObject |
| `ConfigStore.write_and_point(attrs)` | ✅ 完成 | 原子写对象+指针（单个 DB transaction） |
| `ConfigStore.put_pointer(attrs)` | ✅ 完成 | upsert ConfigPointer（含 previous_config_id 用于 rollback） |
| `ConfigStore.resolve(layer, ws, subject, key)` | ✅ 完成 | 按指针解析到 ConfigObject |
| `Behavior.ConfigUpdate.handle_apply_delta(turn_id)` | ✅ 完成 | 从 settled turn 提取 config_delta → write_config → repoint → put_pointer |
| `Behavior.ConfigUpdate.handle_repoint(args)` | ✅ 完成 | rollback/前进到指定 config_id |
| **ConfigProjection（消费侧）** | ⚠️ 仅在 PR #607 | `resolve_config_dir` → `render_soul` → 写入 `CLAUDE.md` |
| **CascadeRepoint（消费侧）** | ⚠️ 仅在 PR #607 | `repoint_user_layer` → 读写 agent sandbox → 改 `user_layer_uri` |

### 1.7 SocialwareSession Kind + PageView

完成度: **Kind 定义 100%，operator UI 骨架完成**。

| 功能 | 状态 | 备注 |
|---|---|---|
| `SocialwareSession` Kind 定义 | ✅ 完成 | 组合 Chat+Turn+Surface+ConfigUpdate |
| `PageView` (operator SessionView) | ✅ 骨架 | 支持 text/container/table 三种节点，但不支持 `code` 节点（Sandpack） |
| **CapabilityRegistry 注册** | ✅ 完成 | application.ex 注册了所有 Turn/Surface/ConfigUpdate actions |

---

## 二、Socialware 对 Autoservice 的覆盖度

### 总体覆盖度: ~15%

Socialware 提供的是**基础设施层**（Turn状态机、Surface、Settlement、Visibility门控），autoservice 需要的是**完整的客服垂直应用**。两者在抽象层次上差了两级。

#### 2.1 Customer 面覆盖

| Autoservice 功能 | 文件 | Socialware 覆盖 | 迁移方式 |
|---|---|---|---|
| 客户 LiveView 聊天 UI | `customer_live.ex` (126行) | ❌ 无 | 需重写为 React SPA（P4）或保留 LiveView 但接入 CustomerFeed |
| 客户 session 供应 | `customer_session.ex` (386行) | ❌ 无直接等价 | 改为 socialware SessionTemplate 声明式创建 |
| 创建 fast agent (DeepSeek) | `provision/2` → `ensure_fast_agent` | ❌ 无 | socialware 用 AgentTemplate + #17 cascade 替代，不需要手写 provision 代码 |
| 创建 slow agent (cc) | `provision/2` → `maybe_slow_agent` | ❌ 无 | 同上，改为 AgentTemplate |
| 安装 routing rules | `install_routing` | ❌ 无 | socialware 的路由是 `{:from customer} → orchestrator`，由 SessionTemplate 声明 |
| 发送 greeting | `post_greeting` | ❌ 无 | 可建模为 turn.open → turn.compose → turn.settle（首个 auto turn） |
| 聊天消息收发 | `chat.send` / `chat.receive` | ✅ 完全覆盖 | 无需改动 — socialware 共享 Chat Behavior |
| 消息持久化 | `MessageStore` | ✅ 完全覆盖 | 无需改动 |
| **fast/cc 双相位** (P0) | `customer_session.ex` fast+slow agent | ❌ 无 | socialware 无 fast-ack 概念，需新增或在 orchestrator prompt 中实现 |
| **并发 ack** (P0) | — (autoservice 暂无) | ❌ 无 | socialware 无此概念 |

**Customer 面结论**: 除消息收发/持久化外，socialware 不覆盖 autoservice 的任何 customer 面。迁移需将 provision 逻辑改为声明式模板，将 LiveView UI 改为 React SPA（或保留 LiveView 挂到 CustomerFeed）。

#### 2.2 Operator 面覆盖

| Autoservice 功能 | 文件 | Socialware 覆盖 | 迁移方式 |
|---|---|---|---|
| 操作员控制台会话列表 | `operator_live.ex` (249行) | ❌ 无 | 需新建 operator LiveView |
| 操作员加入 session | `join_operator` | ❌ 无 | 可复用 `chat.join`（已存在） |
| 操作员发送消息 | `handle_event("send")` | ✅ 间接 | 操作员消息走 `chat.send` → 不匹配 `{:from customer}` routing → Turn 不触发 |
| **操作员接管** | — (autoservice 暂无真正的接管) | ✅ `turn.claim` + `:awaiting_human` + `:copilot` | 这是 socialware 的强项 — 接管建模为 `turn.claim(by: operator) → 翻转消息为 operator_only → 等待 settle` |
| 操作员审批/编辑 | — | ✅ `turn.settle` from `:awaiting_human` | 对接 operator_live 的审批按钮 |
| 操作员看草稿 | — | ✅ `Surface.operator_tree` 返回 latest（含未批准版本） | 挂到 `PageView` |

**Operator 面结论**: socialware 的 Turn.claim + Surface.operator_tree 对**接管流程**覆盖完善，但操作员控制台的会话列表/选择/聊天 UI 完全没有。autoservice 的 `operator_live.ex` 可以复用聊天 UI 部分，但需要增加"接管/审批/回滚"按钮并接线到 Turn actions。

#### 2.3 Admin 面覆盖

| Autoservice 功能 | 文件 | Socialware 覆盖 | 迁移方式 |
|---|---|---|---|
| 模板编辑器 | `template_editor_live.ex` | ❌ 无覆盖 | 独立于 socialware，可保留 |
| 模板 Diff 视图 | `template_diff_live.ex` | ❌ 无覆盖 | 独立于 socialware，可保留 |
| Bot 创建器 | `bot_creator_live.ex` | ❌ 无覆盖 | 独立于 socialware，可保留 |
| Soul Slot 编辑器 | `soul_slot_editor_live.ex` | ❌ 无覆盖 | 独立于 socialware，可保留 |
| KB Curator | `kb_curator_agent.ex` | ❌ 无覆盖 | 独立于 socialware，可保留 |
| 工作区/用户/路由/Cap 管理 | 多个 admin LiveView | ❌ 无覆盖 | 属于 ezagent core/admin 通用功能，与 socialware 无关 |
| **自进化配置** (SW-UPD) | — | ✅ `ConfigUpdate.apply_delta` + `ConfigStore` | 后端就绪，无 admin UI |
| **页面版本历史审计** | — | ✅ `Behavior.Surface.versions` 不可变+保留 | 后端就绪，无 admin UI |

**Admin 面结论**: socialware **不覆盖任何 admin UI**。Admin LiveView 是 ezagent 通用基础设施，socialware 不需要也不应该重新实现。socialware 的价值在 admin 面是**后端能力**：配置自进化（P6）、页面版本审计（Surface.versions）、结算记录追踪（Settlement）。

---

## 三、能否开始迁移？

### 结论: **可以开始基础设施侧的迁移，不能开始全量迁移。**

#### 3.1 现在就可以做的（零风险，不改 autoservice/loom 生产代码）

| # | 工作 | 说明 |
|---|---|---|
| 0 | **合并 PR #607** (`feat/socialware-config-consume`) | P6 消费侧就绪，打通自进化闭环。核心改动仅1行（`system_principal/catalog.ex` 加 `Sandbox:read`） |
| 1 | **创建 `SocialwareSession` 最小 E2E** | 在 test 环境下，用种子数据创建一个 SocialwareSession，通过 `Invocation.dispatch` 驱动完整的 turn.open→dispatch→deliver→compose→settle 流程，验证所有 Behavior 协作正确 |
| 2 | **编写 SessionTemplate 种子** | 创建 `session.socialware` 和 `session.autoservice` 两个 SessionTemplate，声明 Chat+Turn+Surface、roster、routing rules |
| 3 | **编写 AgentTemplate 种子** | 为 orchestrator/nl_worker/page_worker 创建 AgentTemplate，含 soul prompts 和 #17 cascade config |
| 4 | **验证 `Behavior.Turn` 与真实 cc agent 的 tool-use 交互** | 让一个 cc agent （通过 tool use）调用 `turn.open`/`turn.dispatch`，验证 turn_id 正确生成、correlation 正确传递 |

#### 3.2 需要 P4 完成后才能做的

| # | 工作 | 依赖 |
|---|---|---|
| 5 | 创建 customer streaming endpoint | 依赖 P4 的前端基础设施 |
| 6 | 移植 loom 前端到 CustomerFeed 传输 | 依赖 #5 |
| 7 | 构建第一个融合垂直应用 | 依赖 #5 + #6 |
| 8 | autoservice customer LiveView → React SPA | 依赖 #5 |

#### 3.3 迁移前置条件检查清单

```
[ ] PR #607 已合并（P6 消费侧）
[ ] SocialwareSession 端到端测试通过（Turn+Surface+Settlement 协作）
[ ] 至少一个 cc agent 成功通过 tool use 调用了 turn.open/dispatch
[ ] 至少一个 turn 完成了 open→dispatch→deliver→compose→settle（含真实 agent worker）
[ ] Settlement 的崩溃重放在测试中验证过（非仅单元测试）
[ ] CustomerFeed 的 streaming endpoint 已实现（哪怕是最简版本）
[ ] 前端能通过 CustomerFeed 拿到 committed+customer_visible 内容
```

---

## 四、Loom 端迁移具体事项

### 4.1 Loom 当前架构（715行 orchestrator）

```
用户消息 → chat.send → chat.receive → LoomOrchestrator.handle_receive
  ├── 分类: user_turn? / worker_deliverable? / page_update?
  ├── user turn → dispatch phase:
  │   └── LLM.chat(dispatch_messages) → parse_dispatch(raw) → fan_out(entries)
  │       └── 每个 worker 收到 @mention + 子任务文本
  ├── worker deliverable → collect:
  │   └── 通过 msg.ref_id (subtask_id) 匹配 turn
  │   └── all_collected? → compose_span → reply back to session
  └── page_update (v0 worker):
      └── 更新 loom_source 缓存 + 关闭 matching turn
```

### 4.2 迁移映射（loom → socialware）

| Loom 概念 | Socialware 等价 | 迁移动作 |
|---|---|---|
| `pending: %{turn_id => %{expected, collected, ...}}` | `Behavior.Turn` 的 `:turns` slice | **删除 `pending` 管理代码**，改用 `turn.open/dispatch/deliver/compose/settle` |
| `handle_user_turn` → `LLM.chat(dispatch_messages)` → `parse_dispatch` | orchestrator agent 的灵魂 prompt 指导它调用 `turn.dispatch` | **将 dispatch 逻辑从代码移到 prompt**。orchestrator 的系统提示词告诉它：收到用户消息后，调用 `turn.open` 然后 `turn.dispatch([{id: :nl, mention: <nl_worker>, prompt: ...}, {id: :page, mention: <v0_worker>, prompt: ...}])` |
| `fan_out` → `send_chat_cmd` @mention 各 worker | `turn.dispatch` 自动 fan-out（通过 `chat.send` dispatch effect） | **删除 `fan_out` 函数** |
| `handle_deliverable` → `all_collected?` → `compose_span` | worker 调 `turn.deliver(turn_id, subtask_id, card_ref)` → orchestrator 调 `turn.compose(turn_id, result_refs)` | **worker 的 soul 提示它回复后调 turn.deliver**；orchestrator 收集齐后调 turn.compose |
| `compose_span` → LLM 合成 scene card | `turn.compose` → `write_chat_messages`（带 visibility）+ `surface.put_version` | **保留 compose LLM 调用，结果通过 turn.compose 写入** |
| `handle_page_update` → 更新 `loom_source` | `Behavior.Surface.put_version` 追加不可变版本 → `Behavior.Surface.approve` 推进指针 | **v0 worker 的输出写为 surface 版本**，而非直接更新 orchestrator 的内存缓存 |
| `agg_timeout` | `turn.cancel` 处理超时 | **timer 改为调 turn.cancel** |
| `reply_cmd_effect` → `chat.send` 回 session | `turn.compose` → `turn.settle` → outbox → customer delivery | **reply 走 settlement 门控**，确保客户只看到 committed 内容 |
| Next.js SPA SSE 订阅 | CustomerFeed streaming endpoint（待建 P4） | **前端传输层替换**：从原始 Publisher SSE → CustomerFeed gated endpoint |
| `discover_workers` → 读 `:chat` slice members | 不变 | 可以保留，或在 SessionTemplate 中声明式指定 roster |

### 4.3 Loom 迁移文件级变更清单

```
删除/大幅简化:
  apps/ezagent_plugin_loom/lib/ezagent/behavior/loom_orchestrator.ex  (715行 → 可能完全删除)
    - pending 状态管理 → Behavior.Turn 替代
    - fan_out 逻辑 → Turn.dispatch 替代
    - 收集+合成逻辑 → Turn.deliver + Turn.compose 替代
    - agg_timeout → Turn.cancel 替代

修改:
  apps/ezagent_plugin_loom/lib/ezagent/behavior/loom_v0_worker.ex
    - 输出格式保持不变（<span type="page_update">）
    - 增加: 完成后调用 turn.deliver(turn_id, :page, card_ref)

  apps/ezagent_plugin_loom/lib/ezagent/behavior/loom_worker.ex
    - 输出格式保持不变
    - 增加: 完成后调用 turn.deliver(turn_id, subtask_id, card_ref)

  apps/ezagent_plugin_loom/lib/ezagent/prompts.ex
    - 编排器系统提示词: 增加 turn.open / turn.dispatch / turn.compose / turn.settle 工具说明
    - 移除: dispatch_messages prompt（不再需要 LLM 输出 dispatch JSON）

  apps/ezagent_plugin_loom/assets/ (Next.js SPA)
    - SSE 订阅 → CustomerFeed endpoint (P4 产物)
    - 增加: session-binding token 认证

新增:
  apps/ezagent_plugin_loom/priv/templates/session.loom.json  (SessionTemplate 种子)
  apps/ezagent_plugin_loom/priv/templates/agent.orchestrator.json  (AgentTemplate)
  apps/ezagent_plugin_loom/priv/templates/agent.v0_worker.json
  apps/ezagent_plugin_loom/priv/templates/agent.policy_worker.json
```

### 4.4 Loom 迁移风险点

| 风险 | 等级 | 缓解措施 |
|---|---|---|
| LLM 驱动的 turn.dispatch 不如硬编码 parse_dispatch 可靠 | 高 | 先用确定性解析（保留 parse_dispatch），逐步过渡到 tool-use |
| 前端 SSE→CustomerFeed 替换可能导致实时性下降 | 中 | CustomerFeed 的 outbox signal 模型延迟更低（ids only, refetch），但需要 endpoint 实现 |
| v0 worker 的 page_update 格式与 Surface 版本不兼容 | 低 | page_update span 可直接存为 Surface version 的 tree |
| 多 worker 并发 deliver 时 turn_id 传递链路断裂 | 中 | `turn.dispatch` 已在 chat.send 消息的 metadata.correlation 中传递 turn_id+subtask_id |

---

## 五、Autoservice 端迁移具体事项

### 5.1 Autoservice 当前架构

```
客户 LiveView → chat.send → routing {:from customer} → fast agent + slow agent
                                                          ├── fast: DeepSeek HTTP (立即ack)
                                                          └── slow: cc agent (详细回复)
操作员 LiveView → chat.send → routing 不匹配 {:from customer} → 操作员消息直接到session
```

### 5.2 迁移映射（autoservice → socialware）

| Autoservice 概念 | Socialware 等价 | 迁移动作 |
|---|---|---|
| `CustomerSession.provision/2` (386行) | SessionTemplate + AgentTemplate 声明式创建 | **用 `.json` 种子文件替代 provision 代码**。SessionTemplate 声明 Chat+Turn+Surface；AgentTemplate 声明 fast agent(DeepSeek curl) + slow agent(cc) |
| fast agent (DeepSeek, curl.agent template) | 保留 curl.agent，增加 Turn action 调用能力 | fast agent 的 prompt 增加：收到消息后调 `turn.deliver(turn_id, :fast_ack, reply_card)` |
| slow agent (cc agent) | 保留 cc agent，增加 Turn action 调用能力 | slow agent 的 prompt 增加：完成后调 `turn.deliver(turn_id, :slow_reply, reply_card)` |
| routing rule `{:from customer} → [fast, slow]` | routing rule `{:from customer} → orchestrator` | **增加 orchestrator agent**（即使是简单编排）或保留 routing 但 agent 自己调 Turn actions |
| `customer_live.ex` (126行) | React SPA (P4) 或保留 LiveView 挂 CustomerFeed | **保留 LiveView 作为过渡**，将消息源从 PubSub → CustomerFeed |
| `operator_live.ex` (249行) | 保留，增加接管按钮 | 增加"接管"按钮 → `turn.claim`；增加"批准"按钮 → `turn.settle` |
| 无 turn 概念 | `Behavior.Turn` 完整状态机 | **这是最大变更** — 引入 turn 概念到客服流程 |
| 无消息 visibility 区分 | `Message.visibility` | fast ack 在 turn settle 前设为 `:operator_only`（客户不可见直到慢速回复就绪） |

### 5.3 Autoservice 迁移文件级变更清单

```
简化/可能删除:
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_session.ex
    → SessionTemplate 种子替代 provision/2
    → 简化 ensure_joined/1（只需确保 session 存活）

修改:
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_live.ex
    → 消息源改为 CustomerFeed（而非直接 PubSub）
    → 增加 turn 状态显示（"正在输入..."/"已回复"）

  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/operator_live.ex
    → 增加接管/审批按钮
    → 接线到 turn.claim / turn.settle

  apps/ezagent_plugin_autoservice/priv/cinnox/souls/customer_soul.md
    → fast agent soul: 增加 turn.deliver 工具调用说明
    → slow agent soul: 增加 turn.deliver 工具调用说明

  apps/ezagent_plugin_autoservice/priv/cinnox/souls/operator_soul.md (新增或修改)
    → orchestrator soul: 增加 turn.open / turn.dispatch / turn.compose / turn.settle 说明

新增:
  apps/ezagent_plugin_autoservice/priv/templates/session.autoservice.json
    - 声明 Chat + Turn + Surface
    - roster: [orchestrator, fast_agent, slow_agent, operator]
    - routing: {:from customer} → orchestrator

  apps/ezagent_plugin_autoservice/priv/templates/agent.orchestrator.json
    - cc flavor, autoservice orchestrator soul

  apps/ezagent_plugin_autoservice/priv/templates/agent.fast_ack.json
    - curl.agent flavor (DeepSeek), fast ack soul

  apps/ezagent_plugin_autoservice/priv/templates/agent.slow_reply.json
    - cc flavor, slow reply soul + KB MCP config
```

### 5.4 Autoservice 迁移风险点

| 风险 | 等级 | 缓解措施 |
|---|---|---|
| fast+slow 双相位模型在 Turn 框架下语义退化 | 中 | fast agent 的 reply 作为第一个 deliverable，slow agent 的 reply 作为第二个；orchestrator compose 时合并 |
| provision 改声明式后幂等性语义丢失 | 中 | SessionTemplate.spawn_from_template 需要支持幂等（已存在则返回，不重复创建） |
| 客户 LiveView 改为 React SPA 的工作量 | 高 | **建议分两步**: 第一步保留 LiveView+CustomerFeed（最小改动），第二步再迁移到 React SPA |
| Turn 概念引入对客服人员的 UX 冲击 | 低 | turn 是后端概念，前端可以完全不暴露 — 客户看到的就是"发送消息→收到回复" |

---

## 六、建议的迁移顺序（含估时）

### Phase A: 基础设施完善（1-2周，零业务风险）

| 步骤 | 工作 | 估时 |
|---|---|---|
| A1 | 合并 PR #607 | 1-2天 |
| A2 | SocialwareSession E2E 测试（test only） | 2-3天 |
| A3 | SessionTemplate + AgentTemplate 种子格式定稿 | 1天 |
| A4 | 验证 cc agent tool-use 能调 Turn actions | 2-3天 |

### Phase B: Loom 后端迁移（2-3周，Loom 功能不退化）

| 步骤 | 工作 | 估时 |
|---|---|---|
| B1 | orchestrator soul 改 prompt（增加 Turn tool use） | 2-3天 |
| B2 | 删除 LoomOrchestrator 的 pending/fan_out/compose 代码 | 2-3天 |
| B3 | v0_worker/worker 增加 turn.deliver 调用 | 1-2天 |
| B4 | 验证: 一次 turn 完成 page 生成（含 Surface 版本） | 2-3天 |
| B5 | 对接 Settlement（customer only sees committed） | 1-2天 |

### Phase C: P4 客户前端（3-4周，关键路径）

| 步骤 | 工作 | 估时 |
|---|---|---|
| C1 | CustomerFeed streaming endpoint (Phoenix) | 3-5天 |
| C2 | Token 签发 + session-binding 认证 | 2-3天 |
| C3 | 移植 loom Next.js SPA 到 CustomerFeed 传输 | 5-7天 |
| C4 | 增加 Sandpack code 节点到 PageView | 2-3天 |

### Phase D: Autoservice 后端迁移（2-3周，autoservice 功能不退化）

| 步骤 | 工作 | 估时 |
|---|---|---|
| D1 | 创建 SessionTemplate + AgentTemplate 种子 | 2-3天 |
| D2 | fast/slow agent soul 增加 Turn action (turn.deliver) | 1-2天 |
| D3 | operator_live 增加接管/审批按钮 → turn.claim/settle | 2-3天 |
| D4 | 验证: copilot 模式下客户看不到草稿直到审批 | 2-3天 |

### Phase E: 融合 E2E（1-2周）

| 步骤 | 工作 | 估时 |
|---|---|---|
| E1 | SW-USE E2E (一次 turn → chat+page 双栏渲染) | 3-5天 |
| E2 | SW-UPD E2E (自进化配置 → 可观测 → rollback) | 3-5天 |

**总估时: 10-15 工程师周**（不含 React SPA 完整实现和人手并行加速）

---

## 七、当前最该做的事（优先级排序）

```
🔴 P0 — 合并 PR #607                           (解锁 P6 消费侧，打通闭环)
🔴 P0 — SocialwareSession 端到端 test            (验证基础设施真正可用)
🟡 P1 — SessionTemplate + AgentTemplate 种子格式  (定义迁移目标形态)
🟡 P1 — 验证 cc agent tool-use 调 Turn           (证明 prompt-driven 编排可行)
🟢 P2 — CustomerFeed streaming endpoint           (P4 的起点)
🟢 P2 — Loom orchestrator prompt 迁移             (开始 loom 实际迁移)
```

---

## 八、一句话总结

> **Socialware 基础设施完成度 ~85%（P1-P3+P6写），核心原语正确完整，52个测试全绿。但它仍处于"后端中间件"层面 — 没有任何前端、没有真实 agent 集成验证、没有端到端流程。Autoservice 和 Loom 都不能直接"切换"到 socialware，需要做合计 10-15 工程师周的实质性迁移工作。当前最优先的事不是迁移，而是(1)合并 PR #607，(2)用测试证明 Turn+Surface+Settlement 三者协作确实能跑通一个最小 E2E。**
