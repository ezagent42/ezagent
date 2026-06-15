# Merge-v2 → PR #740 整合方案

> 日期: 2026-06-15 | 基准: PR #740 `045c76be` | 来源: feat/autoservice-v2-merge-v2 `6ea66d81`

---

## 一、双分支差异总览

### 架构差异

| 维度 | PR #740 (B-minimal) | merge-v2 (Session + Behavior) |
|------|---------------------|-------------------------------|
| 编排层 | 无 → TurnAdapter 直驱 | CsOrchestrator Behavior + TurnDriver |
| operator claim | `TurnAdapter.open→compose→claim` LV 层面串行 | dispatch → `cs_orchestrator.operator_claim` |
| operator settle | `TurnAdapter.settle_turn` | dispatch → `cs_orchestrator.operator_settle` |
| bot 暂停 | `RuleStore.disable` 单一 | `operator_active` + `RuleStore.disable` 双门控 |
| TurnDriver | 无 | 同进程直接调 `Turn.handle_*` (v3 §6.6.1) |
| customer 路由 | 不动 (直连 agents) | 加 session 作 MentionRouting receiver |
| operator send | 完全禁用 (NO-OP) | 非 claimed 可走 `chat.send` |

### 功能差异

| 功能 | PR #740 | merge-v2 | 建议 |
|------|---------|----------|------|
| CustomerFeed token | ✅ 已修复 | ❌ 未移植 | **取 PR #740** |
| Slow agent URI | ✅ 已修复 | ❌ 未移植 | **取 PR #740** |
| Slow agent grant | ✅ tolerate redundant | ✅ admin caller + bootstrap caps | **合并两者** |
| Session rehydrate | ✅ SocialwareSession | ❌ 未移植 | **取 PR #740** |
| Demo videos | ✅ 有 | ❌ 无 | **取 PR #740** |
| TenantAdminLive | autoservice/ 目录 | tenant/ 目录 + dev 适配 | **用 merge-v2 适配版** |
| Assembly.Refresh | refresh.ex (顶层) | assembly/refresh.ex | **取 PR #740 位置** |
| CR atomic rename | ✅ | ✅ | 一致 |
| Operator Turn caps | ✅ | ✅ | 一致 |
| Customer visibility | ✅ | ✅ | 一致 |
| chat_ui.ex | 简化（移除 submit attrs） | 保留可配置 | **取 PR #740 简化版** |

### 测试差异

| 测试文件 | PR #740 | merge-v2 |
|----------|---------|----------|
| operator_takeover_gating_test.exs | ✅ 175行 真实测试 | ✅ ported |
| turn_adapter_test.exs | ✅ 71行 真实测试 | ⚠️ 简化 stub |
| multitenant_isolation_test.exs | ✅ 313行 真实测试 | ✅ ported |
| tenant_admin_content_roundtrip_test.exs | ✅ 78行 真实测试 | ✅ ported |
| cr_repair_test.exs | ✅ 120行 真实测试 | ✅ ported |
| cs_orchestrator_test.exs | ❌ 无 | ✅ 16 tests 绿 |
| turn_driver_test.exs | ❌ 无 | ✅ 8 tests 绿 |
| 其他 6 文件 | ✅ 真实测试 | ❌ stub |

### PR #740 新增修复 (上次 review 后)

| 修复 | 内容 | 本分支状态 |
|------|------|-----------|
| CustomerFeed token | `CustomerLive` issue token → settled operator replies render live | ❌ 需移植 |
| Slow agent URI | `slow_agent_uri` drop stale `cc_` prefix | ❌ 需移植 |
| Creator grant | tolerate redundant grant for system principals | ⚠️ 不同方案 |
| Session rehydrate | `rehydrate_session` spawn SocialwareSession | ❌ 需移植 |
| Debug log drop | 移除 `ensure_joined` crashing debug log | ❌ 需移植 |

---

## 二、整合方案

### 原则

1. **以 PR #740 为基线**（已验证的 B-minimal + 全面测试）
2. **从 merge-v2 提取 CsOrchestrator 架构增量**（Session + Behavior 编排层）
3. **保留 PR #740 的所有修复和测试**（不移除已验证代码）

### Phase 1: 基线上 merge-v2 架构贡献

#### 1.1 新增文件（直接复制）

| 文件 | 说明 |
|------|------|
| `cs_orchestrator.ex` | CsOrchestrator Behavior (412行) — 编排核心 |
| `turn_driver.ex` | TurnDriver (87行) — 同进程 Turn 调用 |
| `cs_orchestrator_test.exs` | 单元测试 (16 tests) |
| `turn_driver_test.exs` | 单元测试 (8 tests) |

#### 1.2 修改文件（merge-v2 的改动合并进 PR #740）

| 文件 | merge-v2 改动 | 合并方式 |
|------|-------------|---------|
| `application.ex` | +Plugin.behaviors/0 注册 CsOrchestrator | 追加到 PR #740 版本 |
| `customer_session.ex` | +session receiver 路由 | 追加 `orch_receiver` 到 receivers |
| `operator_live.ex` | dispatch → cs_orchestrator.operator_claim/settle | **保留 PR #740 版本**（send disabled + cancel handler），在其基础上加 CsOrchestrator dispatch 路径 |
| `cr_engine.ex` | +repair_current at publish start | **保留 PR #740 版本**（已有） |

#### 1.3 不合并的文件（PR #740 版本更优）

| 文件 | 原因 |
|------|------|
| `chat_ui.ex` | PR #740 简化版更好 |
| `tenant_admin_live.ex` 位置 | PR #740 的 `autoservice/` 目录更合理 |
| `refresh.ex` 位置 | PR #740 的顶层位置更简洁 |
| 所有 test 文件 | PR #740 有真实测试，merge-v2 是 stub |

### Phase 2: merge-v2 修复贡献

将 merge-v2 的 3 个独立修复移植到 PR #740：

| 修复 | 内容 | merge-v2 commit |
|------|------|----------------|
| Seed ctx | admin caller + bootstrap caps（解决 slow agent） | `6ea66d81` |
| Content init | `TenantProvisioner.create_tenant` 初始化 sandbox | `6ea66d81` |
| Liveview deps | 加 content/cr/autoservice plugin deps | `1a631de4` |

### Phase 3: merge-v2 汲取 PR #740 最新修复

将 PR #740 的 5 个新修复移植到 merge-v2：

| 修复 | 文件 | 优先级 |
|------|------|--------|
| CustomerFeed token | `customer_live.ex` | 🔴 |
| Slow agent URI | `uris.ex`, `customer_session.ex` | 🔴 |
| Creator grant tolerate | `customer_session.ex` | 🟡 (已有替代方案) |
| Session rehydrate | `operator_live.ex` | 🔴 |
| Debug log drop | `customer_session.ex` | 🟢 |

---

## 三、实施步骤

### Step 1: 准备 PR #740 基线

```bash
git checkout feat/autoservice-v2-merge    # PR #740 分支
git checkout -b feat/autoservice-v2-merge-final  # 新整合分支
```

### Step 2: 从 merge-v2 cherry-pick 架构文件

```bash
# CsOrchestrator + TurnDriver + tests
git checkout feat/autoservice-v2-merge-v2 -- \
  apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex \
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_driver.ex \
  apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/cs_orchestrator_test.exs \
  apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/turn_driver_test.exs
```

### Step 3: 手动合并 application.ex + customer_session.ex

在 PR #740 版本基础上：
- `application.ex`: 加 `Plugin.behaviors/0` 注册
- `customer_session.ex`: 加 `orch_receiver` routing

### Step 4: 手动合并 seed 修复

- `mix_task_ctx`: admin caller + bootstrap caps
- `init_tenant_content`: TenantProvisioner.create_tenant

### Step 5: 手动合并 liveview deps

- `liveview/mix.exs`: 加 content/cr/autoservice deps

### Step 6: 验证

```bash
mix compile --warnings-as-errors
mix test                          # 全量通过
mix ecto.reset
mix ezagent.demo.seed_autoservice --with-slow  # 全部成功
mix phx.server                    # 启动并验证所有入口
```

---

## 四、验证清单

| 验证项 | 预期 |
|--------|------|
| 编译 | 全项目警告0 |
| 全量测试 | 全部绿色 |
| Fast agent | seed 无错误，greeting 发送 |
| Slow agent | seed 无错误，agent 创建 |
| /autoservice | CustomerLive 可用 |
| /autoservice/operator | OperatorLive 可用 |
| /autoservice/admin | TenantAdminLive 可用（soul/slots/skills/preview/CR） |
| /admin/autoservice | MasterDashboard 可用 |
| Content sandbox | souls/slots/skills/kb 目录存在 |
| CsOrchestrator | 3 actions 注册，测试全绿 |
| TurnDriver | 6 direct calls，测试全绿 |

---

## 五、取舍决策记录

| # | 决策 | 理由 |
|----|------|------|
| D1 | 以 PR #740 为基线 | 已验证，全面测试，demo 录屏 |
| D2 | 保留 CsOrchestrator 架构 | v3 设计，框架补齐后自动升级 |
| D3 | 保留 PR #740 B-minimal 路径 | 当前可正常工作，CsOrchestrator 是增量 |
| D4 | operator_live.ex 用 PR #740 版本 | send disabled + cancel handler 更完整 |
| D5 | chat_ui.ex 用 PR #740 简化版 | 移除 submit_event/label attrs |
| D6 | 测试用 PR #740 版本 | 真实测试 > stub |
| D7 | TenantAdminLive 用 merge-v2 适配版 | 已适配 dev 模块（TenantRuntime 等） |

---

## 六、不纳入的 merge-v2 内容

| 内容 | 原因 |
|------|------|
| 6 个 stub 测试 | PR #740 有真实测试 |
| assembly/refresh.ex 位置 | PR #740 的顶层位置更简洁 |
| tenant_admin_live.ex autoservice/ 位置 | PR #740 的位置更合理 |
| chat_ui.ex 改动 | PR #740 简化版更好 |
| customer_session.ex debug log | PR #740 已移除 |
