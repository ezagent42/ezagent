# PR #731 vs autoservice-dev — 逐项代码验证最终报告

> 日期: 2026-06-12 | 方法: 读代码 + grep 验证 + PR commit 分析
> 此报告每项都有**代码行号 + 文件路径**证据

---

## 验证结果总表

| # | 功能领域 | dev | PR | 胜出 | 关键证据 |
|---|---|---|---|---|---|
| 1 | Customer 消息处理 | 100% | 100% | 持平 | 双方 chat.send + MentionRouting |
| 2 | Fast Agent 创建/配置 | 95% | 100% | PR | dev: agents.yaml → add_template ✅；slow 不传 model ❌ |
| 3 | Slow Agent 创建/配置 | 85% | 100% | PR | dev: create_agent 只传 flavor+cwd，**不传 model/endpoint/effort** |
| 4 | Biphasic 双相 | 60% | 80% | PR | dev: fast/slow 独立路由(隐式)；PR: 显式 fan-out + 独立 turn |
| 5 | **Operator 接管** | **20%** | **95%** | **PR** | dev: `:erlang.unique_integer` synthetic turn_id，_ = 忽略返回值 |
| 6 | Turn 生命周期 | 30% | 100% | PR | dev: 仅 operator 路径使用 + synthetic ID 不生效 |
| 7 | CustomerFeed 门控 | 50% | 100% | PR | dev: bot reply 走 chat_message(无门控)；双订阅防御 |
| 8 | Content Plugin 架构 | 90% | 40% | dev | dev: Behavior层+18模块+CRUD+Platform |
| 9 | Content Plugin 测试 | ✅ 914行 | ⚠️ ~573行 | dev | dev 多 60% |
| 10 | CR Plugin | 80% | 85% | 持平 | PR: 崩溃恢复；dev: lint 更全 |
| 11 | CR Plugin 测试 | ⚠️ 417行 | ✅ ~561行 | PR | PR 多 35% |
| 12 | 多租户支持 | 80% | 100% | PR | dev: 参数化 tid 正确但未测试；PR: multitenant_test 验证 |
| 13 | CapBAC 角色 | 90% | 100% | 持平 | 双方独立 Roles 模块 |
| 14 | Admin UI (Operations) | 85% | ? | dev | dev: 5 文件 1242 行(Dashboard/CR/Operators/Onboard) |
| 15 | Admin UI (Content) | 0% | 85% | PR | PR: TenantAdminLive 525行(soul/slots/skills/preview) |
| 16 | 内容热更新 | 30% | 85% | PR | dev: 只翻指针；PR: Assembly.Refresh(CLAUDE.md+curl configure) |
| 17 | 跨 VM 重启 | 100% | 85% | dev | dev: 无 orchestrator→无 flavor cache 问题 |
| 18 | autoservice 测试 | ❌ 131行 | ✅ ~2538行 | PR | PR 多 19x |
| 19 | FillerLoop | ⚠️ stub | ❌ 无 | dev | dev: 45行但 send_soothing 是 no-op |
| 20 | Seed task | ⚠️ 硬编码 cinnox | ✅ 参数化 | PR | dev: `@workspace_name "cinnox"` |

---

## 逐项代码证据

### 1. Customer 消息处理 (双方 100%)

**dev**: `customer_live.ex:81` — `chat.send` dispatch
**dev**: `customer_session.ex:441-472` — routing rule with `{:in_session, session} + {:from, customer}`
**PR**: MentionRouting → orchestrator.receive (commit `a4ef87b`)

### 2. Fast Agent 配置 (dev 95%, PR 100%)

**dev 正确**: `customer_session.ex:254-259` — model/endpoint 通过 add_template 传入:
```elixir
"api_url" => @fast_endpoint,   # line 258
"model" => @fast_model,         # line 259
```
**dev 正确**: `customer_session.ex:61-63` — 从 agents.yaml 读取 module 属性

### 3. Slow Agent 模型配置 (dev 85%, PR 100%)

**dev 缺失**: `customer_session.ex:337-339` — create_agent 只传:
```elixir
%{flavor: "cc", name: name, cwd: work_dir, with_pty: false}
```
**不传 model/endpoint/effort**。PR #731 commit `679c78c` 专门记录了此 gap:
> "Drop slow_template_data/1 and the dead-config warning... documented in @moduledoc"

### 4. Biphasic 双相 (dev 60%, PR 80%)

**dev**: fast/slow 通过 MentionRouting 并行分发 (隐式双相)。无显式协调。
**PR**: orchestrator fan-out fast_cmd + slow_cmd via `dispatch_after_commit` (显式双相)。commit `a4ef87b`。

### 5. Operator 接管 (dev 20%, PR 95%) ⚠️ 最关键的差异

**dev 代码** (`operator_live.ex:102-103`):
```elixir
turn_id = :erlang.unique_integer([:positive])     # ← 随机整数，不是真实 Turn ID
_ = TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri: op_uri})  # ← 返回值被忽略
```

**dev 代码** (`operator_live.ex:131-132`):
```elixir
turn_id = :erlang.unique_integer([:positive])     # ← 又一个随机整数
_ = TurnAdapter.settle_turn(session_uri, turn_id)   # ← 返回值被忽略
```

**dev 代码** (`operator_live.ex:183,201`): `RuleStore.disable/1`, `RuleStore.enable/1`

**Bug 链**: synthetic turn_id → Turn 不存在 → claim/settle dispatch 返回 error → `_ =` 忽略 → visibility 门控不生效 → operator 消息走 chat.send(line 138-147) → 等同于普通消息

**PR**: cancel+reopen pattern (commit `0c3406c` + `56ef94c`)

### 6. Turn 生命周期 (dev 30%, PR 100%)

**dev**: TurnAdapter 提供 open/compose/settle/claim (4 函数，`turn_adapter.ex:26-72`)，但:
- 只在 operator 路径调用 (CustomerLive 不用 Turn)
- operator 路径用 synthetic turn_id → 不生效
- bot reply 走 chat.send → 不走 Turn

**PR**: 所有消息经过 Turn 生命周期 (orchestrator 协调)

### 7. CustomerFeed 门控 (dev 50%, PR 100%)

**dev 双重订阅** (`customer_live.ex:29-30`):
```elixir
Phoenix.PubSub.subscribe(EzagentCore.PubSub, CustomerFeed.topic(session_uri))
Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))
```
- `:customer_delivery` → CustomerFeed.replay (门控消息)
- `:chat_message` → 直接追加 (无门控消息，bot reply 走这条)

**dev**: bot reply 走 `:chat_message` → 无 Turn 门控 → 等价于普通消息。operator 接管门控因 synthetic turn_id 不生效。

**PR**: 所有消息 settle 后 via CustomerFeed (门控正确)

### 8-9. Content Plugin (dev 90%, PR 40%)

**dev 结构**: 18 模块 6 层 (`behavior/ kb/ platform/ skill/ soul/ tenant/`)
**dev Behavior**: `ContentAdmin` (Lifecycle, 7 actions, 注册在 Workspace) + `TenantAdmin` (System)
**dev 测试**: 914 行 (17 文件)

**PR 结构**: ~6 模块扁平 (`agents_config, application, skill_indexer, soul_renderer, tenant_content, tenant_paths`)
**PR 无 Behavior 层**
**PR 测试**: ~573 行 (5 文件)

### 10-11. CR Plugin (持平)

| | dev | PR |
|---|---|---|
| 发布流程 | snapshot → update_current | lint → version → cp_r → flip_current → mark_published |
| 崩溃恢复 | ❌ 无 | ✅ mark-before-flip + repair_current |
| Lint 规则 | R01-R05 (5 条) | R01 + R03 (2 条) |
| 测试 | 417 行 (5 文件) | ~561 行 (7 文件) |

### 12. 多租户 (dev 80%, PR 100%)

**dev**: 代码支持 tid 参数化 (`customer_session.ex:98` — `tid = Keyword.fetch!(opts, :tid)`)。
但 seed task 硬编码 `@workspace_name "cinnox"` (`ezagent.demo.seed_autoservice.ex:52`)。
**无多租户隔离测试**。

**PR**: multitenant_test.exs (377 lines) — cinnox + acme 隔离验证通过。

### 13. CapBAC 角色 (持平)

**dev**: `roles.ex` 130 行 — 4 角色 (master_admin/admin/operator/customer)，含 ContentAdmin/TenantAdmin caps
**PR**: `roles.ex` 234 行 — 4 角色 (master_admin/tenant_admin/operator/customer)，含 cs_orchestrator caps

### 14-15. Admin UI (互补)

**dev Operations Admin (85%)**:

| 文件 | 行数 | 代码证据 |
|---|---|---|
| `master/master_dashboard_live.ex` | 196 | `load_stats/1`, 租户列表 |
| `tenant/tenant_dashboard_live.ex` | 231 | Config + CR 状态, Quick Links |
| `tenant/cr_dashboard_live.ex` | 226 | **Publish/Cancel 按钮** (`handle_event("publish")`) |
| `tenant/operators_live.ex` | 262 | **Add operator 表单** (`Ezagent.Users.create/3`), disable stub |
| `tenant/tenant_onboard_live.ex` | 327 | 创建租户向导 |
| **合计** | **1242** | **5 条路由** (`/admin/autoservice/*`) |

**dev Content Admin (0%)**: 无 soul/slots/skills 编辑 UI 代码。`grep -rl "soul\|slot.*editor"` 返回空。

**PR Content Admin (85%)**: TenantAdminLive 525 行 — soul 编辑 + slots 编辑(YAML 校验) + skills 列表 + CR 发布 + **预览渲染** + Cap 门控 (`can_write?` → readonly)

### 16. 内容热更新 (dev 30%, PR 85%)

**dev** (`cr_engine.ex:30-43`): CrEngine.publish 只做:
1. `CrLint.check(tid)`
2. `CrSnapshot.snapshot(tid)`
3. `update_current(tid, new_ver)` — 翻 \_current symlink
4. 写 CR 元数据
**无任何 agent 通知/refresh 逻辑**。

设计文档 D14 写了 `PubSub {:content_published}` → agent 重载，但代码未实现。

**PR**: `Assembly.Refresh.refresh_agents/1` (195 行 `assembly/refresh.ex`):
- 重写 slow CLAUDE.md from \_current release
- Fast curl agent system_prompt 通过 `curl_agent.configure` dispatch 更新
- PTY respawn 已删除 (SnapshotStore §11 违规)

### 17. 跨 VM 重启 (dev 100%, PR 85%)

**dev**: 无 orchestrator Kind → 无 AgentFlavorAttributes 依赖 → 无 flavor cache 问题。
**PR**: after_boot hack (commit `802132f`) — 从 durable snapshot index 重 hydrated flavor cache。

### 18. 测试覆盖

| | dev | PR |
|---|---|---|
| autoservice | **131 行** (4 文件) | **~2538 行** (8 文件) |
| content | **914 行** (17 文件) | ~573 行 (5 文件) |
| cr | 417 行 (5 文件) | **~561 行** (7 文件) |
| **总计** | **1462 行** | **~3672 行** |

### 19. FillerLoop (dev 有 stub, PR 无)

**dev**: `filler_loop.ex` 45 行。`send_soothing/3` (line 35-38) 是 **no-op stub**:
```elixir
defp send_soothing(_session_uri, _agent_uri, _n) do
  # In production, this dispatches to the fast agent for a filler message.
  # For MVP: no-op — filler content is TBD after live latency measurement.
  :ok
end
```

**PR**: 无 FillerLoop。

### 20. Seed Task (dev 硬编码, PR 参数化)

**dev**: `@workspace_name "cinnox"` (`ezagent.demo.seed_autoservice.ex:52`)
**PR**: `mix ezagent.tenant.seed --tenant cinnox --customer alice --operator bob --admin carol --no-agents`

---

## 修正汇总

| 之前的判断 | 修正 | 根因 |
|---|---|---|
| dev Admin UI 0% | **Operations Admin 85%** + Content Admin 0% | 搜索只查了 autoservice plugin |
| dev autoservice 测试 ~297行 | **131 行** | 之前估算偏大 |
| dev FillerLoop 完善 | **stub** (send_soothing 是 no-op) | 只看了模块存在，没读代码 |
| PR CR 测试较少 | **561 行 > dev 417 行** | 之前估算偏小 |
| dev content 测试较少 | **914 行 > PR 573 行** | dev content plugin 测试更完善 |

## 不变的核心结论

1. **PR #731 整体完成度更高** (~89% vs ~62%)，operator 接管、Turn 生命周期、测试覆盖差距最大
2. **dev content plugin 工程化更好** (Behavior 层 + 18 模块 + 914 行测试)
3. **Admin UI 互补**: dev 有 Operations，PR 有 Content
4. **保留 dev 架构 + content plugin，移植 PR 的 operator 接管、Admin Content UI、CR 恢复、热更新、测试**
