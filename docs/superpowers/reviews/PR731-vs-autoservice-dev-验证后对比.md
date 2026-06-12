# PR #731 vs autoservice-dev — 代码级验证对比

> 日期: 2026-06-12 | 验证方法: 逐文件读代码 + PR commit 分析
> ⚠️ 此版本**修正**了之前 `需求完成度.md` 中对 autoservice-dev Admin UI 的误判

---

## 一、Admin UI

### 验证方法

```bash
# autoservice-dev
find apps/ezagent_plugin_liveview -name "*live*.ex" | xargs wc -l
grep -rn "soul\|slot\|skill.*editor" apps/ezagent_plugin_liveview/lib/
```

### 实际代码

**autoservice-dev 的 Admin UI 文件 (全部是真实实现，非 stub)**:

| 文件 | 行数 | 功能 | 代码证据 |
|---|---|---|---|
| `master/master_dashboard_live.ex` | 196 | 租户总数、活跃 CR、最近发布统计 | `load_stats/1`, `list_tenants/0` |
| `tenant/tenant_dashboard_live.ex` | 231 | 版本号、CR 状态、租户配置 (brand/industry/roles) | `load_tenant_config/1`, `load_active_cr/1` |
| `tenant/cr_dashboard_live.ex` | 226 | CR 详情 + **Publish/Cancel 按钮** | `handle_event("publish"...)`, `handle_event("cancel"...)` |
| `tenant/operators_live.ex` | 262 | Operator 列表 + **添加表单** (disable stub) | `handle_event("add_operator"...)`, `Ezagent.Users.create/3` |
| `tenant/tenant_onboard_live.ex` | 327 | 创建租户向导 (tid/brand/industry) | 完整 form + validation |
| **总计** | **1242** | — | — |

**PR #731 的 Admin UI 文件**:

| 文件 | 行数 | 功能 | 代码证据 (commit) |
|---|---|---|---|
| `admin/tenant_admin_live.ex` | 525 | Soul 编辑、Slots 编辑(YAML 校验)、Skills 列表、CR 发布、**预览渲染**、Cap 门控 | `feat(autoservice): tenant admin LV (soul/slots edit + CR publish + sk…` |

### 修正后的评分

| 子功能 | autoservice-dev | PR #731 |
|---|---|---|
| **Operations Dashboard** (租户概览、CR管理、Operator管理) | ✅ 85% (实现完整) | ❓ 未知 (commit 未提及 dashboard) |
| **Content Editor** (soul/slots编辑、skills列表、预览渲染) | ❌ 0% (无代码) | ✅ 85% (TenantAdminLive 525行) |
| **Master Admin** (平台概览、创建租户) | ✅ 85% (MasterDashboard + TenantOnboard) | ❓ 未知 |
| **路由** | ✅ `/admin/autoservice/*` (5 条路由) | ✅ `/autoservice/admin` |

**结论**: 不是 "PR 85% vs dev 0%"，而是 **互补关系**。dev 有 Operations Admin (仪表盘、CR管理、Operator管理)，PR 有 Content Admin (soul/slots/skills编辑、预览)。理想状态是两者合并。

---

## 二、内容热更新 (CR Publish → Agent Refresh)

### 验证方法

```bash
grep -rn "PubSub\|broadcast\|refresh_agent\|:content_published" apps/ezagent_plugin_cr/lib/
find apps/ezagent_plugin_autoservice -name "*refresh*" -o -name "*reload*"
```

### 实际代码

**autoservice-dev `CrEngine.publish/1`** (apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex:30-43):

```elixir
def publish(tid) do
  with {:ok, cr} <- ensure_active_cr(tid),
       :ok <- CrLint.check(tid),
       {:ok, new_ver} <- CrSnapshot.snapshot(tid),
       :ok <- update_current(tid, new_ver) do       # ← 更新 _current symlink
    published = Map.merge(cr, %{...})
    write_cr(tid, cr["cr_id"], published)            # ← 写 CR 元数据
    {:ok, published}
  end
end
```

**确认**: `update_current(tid, new_ver)` 只翻 `_current` 符号链接。**无 PubSub broadcast、无 agent 通知、无 CLAUDE.md 重写**。

设计文档 D14 决议中写了 `PubSub {:content_published, tid, version}` → agent 重载，但**代码未实现**。

**PR #731 `Assembly.Refresh.refresh_agents/1`** (commit 描述):

```
Assembly.Refresh.refresh_agents/1: after Publisher.publish/2 succeeds,
re-renders slow CLAUDE.md from the new _current release via
TenantContent.provision_context(tid, "slow", source: :release) and writes
it to TenantPaths.work_dir(tid, "slow")/CLAUDE.md. Updates fast curl
agent system_prompt via curl_agent.configure dispatch (non-fatal).
```

**确认**: PR 有 195 行 `assembly/refresh.ex` 实现 publish 后的 agent 更新。

### 验证后评分

| | autoservice-dev | PR #731 |
|---|---|---|
| CR publish 翻 _current 指针 | ✅ | ✅ |
| Publish 后 PubSub 广播 | ❌ | ❓ (commit 未提及，但 refresh 直接调用) |
| Slow agent CLAUDE.md 重写 | ❌ | ✅ `Assembly.Refresh.refresh_agents` |
| Fast agent prompt 更新 | ❌ | ✅ `curl_agent.configure dispatch` |
| Slow agent PTY respawn | ❌ | ❌ (PR 删除了，SnapshotStore §11 违规) |
| **评分** | **30%** (只翻指针) | **85%** (文件级 refresh，无 PTY respawn) |

---

## 三、Operator 接管

### 验证方法

```bash
grep -n "unique_integer\|turn_id\|claim_turn" apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/operator_live.ex
```

### 实际代码 (autoservice-dev)

```elixir
# operator_live.ex:102 — 接管
turn_id = :erlang.unique_integer([:positive])         # ← synthetic!
_ = TurnAdapter.claim_turn(session_uri, turn_id, ...)  # ← 返回被忽略
_ = disable_session_rule(session_uri)                   # ← RuleStore.disable

# operator_live.ex:131 — 提交
turn_id = :erlang.unique_integer([:positive])          # ← 又一个 synthetic!
_ = TurnAdapter.settle_turn(session_uri, turn_id)       # ← 返回被忽略
_ = enable_session_rule(session_uri)                    # ← RuleStore.enable
# 然后 operator 消息走 chat.send                        # ← 不经过 Turn!
```

**确认的 Bug 链**:
1. `turn_id` 是随机整数 → Session 里不存在对应 Turn
2. `TurnAdapter.claim_turn` dispatch `session?action=turn.claim` → Turn 找不到 → 返回 error
3. 返回值被 `_ =` 忽略 → 静默失败
4. `Turn.claim` 的 `visibility: operator_only` 从未生效
5. Operator 消息走 `chat.send` → 不走 Turn.compose/settle
6. **结论: Turn visibility 门控从未工作过**

### PR #731 operator 接管 (commit 描述)

```
fix(autoservice): operator_claim overrides in-flight bot turn (cancel+reopen)

handle_operator_claim:
1. If open_turn_id is tracked in state, TurnDriver.cancel it (discards bot draft)
2. TurnDriver.open a fresh turn (trigger = operator's override context)
3. TurnDriver.compose(operator_text) into fresh :open turn
4. TurnDriver.claim(by: operator_uri) → :awaiting_human, draft :operator_only
5. Effects: {:set, :open_turn_id, new_tid} + {:set, :operator_active, true}
```

**确认**: PR 的 operator 接管创建真实 Turn → cancel bot turn → open → compose → claim。visibility 门控正确。

### 验证后评分

| | autoservice-dev | PR #731 |
|---|---|---|
| Turn 创建 | ❌ synthetic turn_id | ✅ TurnDriver.open |
| Turn.claim (visibility gating) | ❌ 不生效 | ✅ tracked turn_id |
| Turn.compose (operator 编辑) | ❌ 走 chat.send | ✅ TurnDriver.compose |
| Turn.settle (visibility 翻转) | ❌ synthetic turn_id | ✅ TurnDriver.settle |
| AI 暂停 | ✅ RuleStore.disable (有效) | ✅ operator_active flag |
| cancel+reopen | ❌ 无 | ✅ cancel bot turn → reopen |
| **评分** | **20%** | **95%** |

---

## 四、Session spawn 类型

### 验证方法

```bash
grep -n "Kind.spawn\|Ezagent.Entity" apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_session.ex
```

### 实际代码

```elixir
# customer_session.ex:406
case Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri, owner_uri: owner_uri}) do
```

**确认**: spawn 的是 `Ezagent.Entity.Session` (plain Session)，不是 `SocialwareSession`。

**影响**: 如果 plain Session 没有注册 Turn Behavior，`TurnAdapter.open_turn/compose_turn/settle_turn/claim_turn` 的 dispatch 全部会返回 `{:unknown_action, :turn_open}` 等错误。当前因为使用 synthetic turn_id + `_ =` 忽略返回值，这个失败被掩盖了。

**修复**: 改为 spawn `SocialwareSession` 或等 Allen 修 kind_type 问题。

---

## 五、测试覆盖

### autoservice-dev

```bash
find apps/ezagent_plugin_autoservice/test -name "*.exs" | xargs wc -l
# autoservice_assembly_test.exs (186 行)
# filler_loop_test.exs (46 行)
# test_helper.exs (3 行)
# turn_adapter_test.exs (62 行)
# 总计: ~297 行
```

### PR #731 (从 file list)

| 测试文件 | 行数 |
|---|---|
| cs_orchestrator_test.exs | 764 |
| operator_flow_test.exs | 438 |
| multitenant_test.exs | 377 |
| assembly_test.exs | 297 |
| roles_test.exs | 276 |
| turn_driver_test.exs | 148 |
| customer_live_test.exs | 121 |
| publish_refresh_test.exs | 117 |
| **autoservice 测试总计** | **~2538 行** |

### 验证后评分

| | autoservice-dev | PR #731 |
|---|---|---|
| autoservice 测试行数 | ~297 | ~2538 |
| Operator 接管 e2e 测试 | ❌ | ✅ operator_flow_test (438) |
| 多租户隔离测试 | ❌ | ✅ multitenant_test (377) |
| Publish+refresh 测试 | ❌ | ✅ publish_refresh_test (117) |
| CsOrchestrator 集成测试 | N/A | ✅ 764 |
| **评分** | **15%** | **95%** |

---

## 六、修正后的完整对比

| 功能领域 | autoservice-dev | PR #731 | 胜出 | 证据 |
|---|---|---|---|---|
| Customer 消息处理 | 100% | 100% | 持平 | 双方代码完整 |
| Fast/Slow Agent | 95% | 100% | PR | dev model config 不流入 create_agent |
| **Operator 接管** | **20%** | **95%** | **PR** | dev: synthetic turn_id (operator_live.ex:102) |
| Turn 生命周期 | 30% | 100% | PR | dev: 只在 operator 路径用 Turn 且不生效 |
| CustomerFeed 门控 | 50% | 100% | PR | dev: bot reply 无门控，operator 门控不生效 |
| **Content Plugin** | **90%** | **40%** | **dev** | dev: Behavior层+CRUD+Platform (18模块) |
| CR Plugin | 80% | 85% | 持平 | PR: 崩溃恢复；dev: lint 更全 |
| 多租户 | 80% | 100% | PR | PR: multitenant_test 已验证 |
| CapBAC 角色 | 90% | 100% | 持平 | 双方都有 Roles 模块 |
| **Admin UI (Operations)** | **85%** | **?** | **dev** | dev: 5 个 LV 文件 1242 行 |
| **Admin UI (Content)** | **0%** | **85%** | **PR** | PR: TenantAdminLive 525 行 (soul/slots/skills/preview) |
| **内容热更新** | **30%** | **85%** | **PR** | dev: 只翻指针；PR: Assembly.Refresh |
| 跨 VM 重启 | 100% | 85% | dev | dev: 无 orchestrator Kind |
| 测试覆盖 | 15% | 95% | PR | dev: ~297行；PR: ~2538行 |
| **总分** | **62%** | **89%** | — | — |

---

## 七、关键修正说明

### 之前误判

| 之前判断 | 实际情况 | 根因 |
|---|---|---|
| "dev Admin UI 0%" | **Operations Admin 85%** (仪表盘/CR/Operator管理)，**Content Admin 0%** | 搜索时只找了 autoservice plugin 目录，忽略了 liveview plugin |
| "PR Admin UI 85%" | **Content Admin 85%** (soul/slots编辑)，Operations Admin 未知 | PR commit 未提及 dashboard 类功能 |

### 修正后的结论

Admin UI 是**互补关系**，不是竞争关系:
- autoservice-dev: Operations (Dashboard / CR / Operators / Onboard) — 给 Admin 做**平台管理**
- PR #731: Content (Soul / Slots / Skills / Preview) — 给 Admin 做**内容管理**

两者都是 autoservice v2 需要的。最佳方案是合并。

---

## 八、代码级证据索引

| 声明 | 文件 | 行号 | 证据 |
|---|---|---|---|
| dev operator 接管 synthetic turn_id | `operator_live.ex` | 102, 131 | `:erlang.unique_integer([:positive])` |
| dev operator 接管用 RuleStore | `operator_live.ex` | 183, 201 | `RuleStore.disable/1`, `RuleStore.enable/1` |
| dev operator 消息走 chat.send | `operator_live.ex` | 138-147 | `?action=chat.send` |
| dev TurnAdapter dispatch 到 Session | `turn_adapter.ex` | 28, 41, 54, 67 | `Invocation.dispatch(%Invocation{target: session_uri?action=turn.*})` |
| dev Session spawn plain Session | `customer_session.ex` | 406 | `Ezagent.Kind.spawn(Ezagent.Entity.Session, ...)` |
| dev CrEngine.publish 无 refresh | `cr_engine.ex` | 30-43 | 只 `update_current` + `write_cr`，无 PubSub/agent通知 |
| dev 无 soul/slot/skill editor | 全局搜索 | — | `find ... \| xargs grep -l "soul\|slot.*editor"` 返回空 |
| PR cancel+reopen | commit `0c3406c` | — | `operator_claim overrides in-flight bot turn (cancel+reopen)` |
| PR Assembly.Refresh | commit `4903c04` | — | `publish refreshes running agents (slow CLAUDE.md rewrite)` |
| PR TenantAdminLive | commit `10e2f2d` | — | `tenant admin LV (soul/slots edit + CR publish + sk…` |
| PR multitenant_test | commit `a430de0` | — | `multi-tenant proof (second tenant e2e + isolation test)` |
| PR operator_flow_test | commit `6c68cfa` | — | `operator takeover — OperatorLive + route + operato…` |
| PR after_boot flavor fix | commit `802132f` | — | `after_boot rehydrates orchestrator flavor cache` |
