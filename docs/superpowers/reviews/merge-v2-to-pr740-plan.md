# 向 PR #740 合入 merge-v2 — 完整方案 v3

> 日期: 2026-06-15 | 基线: PR #740 `045c76be` | 源: feat/autoservice-v2-merge-v2 `6ea66d81`

---

## 一、方向确认

```
PR #740 (基线) ← CsOrchestrator + TurnDriver 全面替换 B-minimal operator 路径

编排层: CsOrchestrator Behavior + TurnDriver
operator: 从 PR #740 的 TurnAdapter 直驱 → CsOrchestrator dispatch
其他:    逐项评估，取最优
```

## 二、CsOrchestrator 替换论证

| operator 功能 | B-minimal (PR #740) | CsOrchestrator (merge-v2) | 选择 |
|---------------|---------------------|--------------------------|------|
| 接管: cancel bot turn | ❌ 无 | ✅ cancel_stale_turn | CsOrch |
| 接管: open fresh | ✅ TurnAdapter.open | ✅ TurnDriver.open | 等价 |
| 接管: compose 真实文本 | ✅ TurnAdapter.compose | ✅ TurnDriver.compose | 等价 |
| 接管: claim | ✅ TurnAdapter.claim | ✅ TurnDriver.claim | 等价 |
| 接管期间 fan-out 抑制 | ❌ 仅 RuleStore.disable | ✅ operator_active + RuleStore | CsOrch 更安全 |
| 接管: settle | ✅ TurnAdapter.settle | ✅ TurnDriver.settle | 等价 |
| 接管: 放弃(cancel) | ✅ TurnAdapter.cancel | ✅ TurnAdapter.cancel（复用） | 等价 |
| P22 fan-out | ❌ MentionRouting 直连 | ✅ dispatch_after_commit | CsOrch 更安全 |
| customer→Turn.open | ❌ 无 | ✅ cs_orchestrator.process_message | CsOrch 独有 |

**结论: CsOrchestrator 全面替换，无共存。**

---

## 三、合入清单

### 🔴 架构核心（从 merge-v2 新增）

| # | 文件 | 说明 |
|---|------|------|
| 1 | `cs_orchestrator.ex` (new, 412行) | 3 actions, P22 fan-out, operator_active |
| 2 | `turn_driver.ex` (new, 87行) | 同进程 Turn + apply_turn_effects |
| 3 | `cs_orchestrator_test.exs` (new, 16 tests) | stateful ctx 单元测试 |
| 4 | `turn_driver_test.exs` (new, 8 tests) | lifecycle, claim, cancel, error |

### 🟡 修改已有文件（从 merge-v2 合入改动）

| # | 文件 | merge-v2 改动 | 合并注意 |
|---|------|-------------|---------|
| 5 | `application.ex` | +`behaviors/0` 注册 3 个 action | 追加到 PR #740 文件末尾 |
| 6 | `customer_session.ex` | routing: orch_receiver **替换** fast/slow receivers | CsOrchestrator 接管 fan-out，避免 agent 收到重复消息 |
| 7 | `liveview/mix.exs` | +content/cr/autoservice deps | PR #740 缺少这些 deps |
| 8 | `seed_autoservice.ex` | admin caller + content sandbox init | cherry-pick `6ea66d81` |
| 9 | `tenant_admin_live.ex` | 模块引用 dev 适配 | PR #740 的 `autoservice/` 位置不变，改 alias + 函数调用 |

### 🟢 operator_live.ex — 从 PR #740 版本改造

PR #740 的 `operator_live.ex` 保留了需要的东西：
- ✅ chat_ui.ex **已有** `submit_event`/`submit_label` attrs（带默认值 `send`/`发送`）
- ✅ send handler: NO-OP during takeover
- ✅ cancel handler: TurnAdapter.cancel + enable rules + unsubscribe
- ✅ claim handler: accept `%{"text" => text}` from composer
- ✅ rehydrate_session: spawn SocialwareSession
- ✅ 双 composer: claimed 时 `submit_event="claim" submit_label="接管并发送"`

改造：将 claim/settle handler 内部从 TurnAdapter 调用 → CsOrchestrator dispatch:

```elixir
# claim: TurnAdapter.open→compose→claim (5行) → dispatch cs_orchestrator.operator_claim (Invocation.dispatch, 同模式)
# settle: TurnAdapter.settle (1行) → dispatch cs_orchestrator.operator_settle
# cancel: 保持 TurnAdapter.cancel（轻量路径，不需要 CsOrchestrator action）
# send: 保持 NO-OP（PR #740 已验证）
```

### 🔵 保持 PR #740 不动的内容

| 文件 | 原因 |
|------|------|
| `chat_ui.ex` | 已有 submit_event/label attrs，与 operator 双 composer 兼容 ✅ |
| `customer_live.ex` | CustomerFeed token 修复、visibility filter ✅ |
| `uris.ex` | `cc_slow-` → `slow-` fix ✅ |
| `refresh.ex` | 顶层位置简洁，已接线 publish 按钮 ✅ |
| `roles.ex` | Turn caps 一致 ✅ |
| `turn_adapter.ex` | 已增强 operator caps + cancel_turn ✅ |
| `cr_engine.ex` | mark-before-flip + repair_current + 原子 rename ✅ |
| 所有测试文件 | PR #740 真实测试 ✅ |
| demo 文件 | 已录制 ✅ |

> ⚠️ **测试适配**: `operator_takeover_gating_test.exs` 测试 TurnAdapter 直驱路径。
> operator_live.ex 改为 CsOrchestrator dispatch 后，需将此测试的验证目标
> 从 TurnAdapter 改为 CsOrchestrator（或新增 CsOrchestrator gating test，
> 保留 TurnAdapter test 用于 cancel 路径）。

---

## 四、实施步骤

### Step 1: 准备

```bash
git checkout feat/autoservice-v2-merge     # PR #740
git checkout -b feat/autoservice-v2-merge-final
```

### Step 2: 新增 4 个架构文件

从 merge-v2 直接复制:
- `apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex`
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_driver.ex`
- `apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/cs_orchestrator_test.exs`
- `apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/turn_driver_test.exs`

### Step 3: 修改 6 个已有文件

| 文件 | 操作 |
|------|------|
| `application.ex` | 追加 `behaviors/0` |
| `customer_session.ex` | `install_routing`: orch_receiver **替换** fast/slow（避免重复投递） |
| `liveview/mix.exs` | 追加 content/cr/autoservice deps |
| `seed_autoservice.ex` | 替换 mix_task_ctx + 加 init_tenant_content |
| `tenant_admin_live.ex` | 模块引用替换为 dev 版本（TenantRuntime 等） |
| `operator_live.ex` | claim/settle handler → CsOrchestrator dispatch |

### Step 4: 验证

```bash
mix compile --warnings-as-errors
mix test                          # ~31 tests (23 PR740 + 8 merge-v2)
mix ecto.reset
mix ezagent.demo.seed_autoservice --with-slow  # 0 errors
mix phx.server                    # 所有入口可达
```

---

## 五、合入后测试分布

| 测试文件 | 来源 | tests |
|----------|------|-------|
| operator_takeover_gating_test.exs | PR #740 | ~6 |
| turn_adapter_test.exs | PR #740 | ~5 |
| multitenant_isolation_test.exs | PR #740 | ~4 |
| tenant_admin_content_roundtrip_test.exs | PR #740 | ~2 |
| cr_repair_test.exs | PR #740 | ~4 |
| publish_refresh_test.exs | PR #740 | ~2 |
| cs_orchestrator_test.exs | merge-v2 | 16 |
| turn_driver_test.exs | merge-v2 | 8 |
| **合计** | | **~47** |

---

## 六、决策记录

| # | 决策 | 理由 |
|---|------|------|
| D1 | CsOrchestrator 全面替换 B-minimal | 功能超集，无需共存 |
| D2 | PR #740 为基线 | 已验证，demo，全面测试 |
| D3 | operator_live.ex 从 PR #740 改造 | 保留 send disabled + cancel + rehydrate |
| D4 | chat_ui.ex 用 PR #740 | submit_event/label attrs 保留（默认值），兼容双 composer |
| D5 | cancel 保持 TurnAdapter | 轻量放弃路径，不需要 CsOrchestrator action |
| D6 | refresh.ex 用 PR #740 位置 | 顶层简洁 |
| D7 | seed 用 merge-v2 修复 | admin caller 解决 slow agent + content init |
| D8 | liveview deps 用 merge-v2 | TenantAdminLive 需要 |
| D9 | TenantAdminLive dev 适配用 merge-v2 | 模块引用已适配 dev 代码库 |
| D10 | customer_session routing 用 merge-v2 | orch_receiver 是 CsOrchestrator 必需 |
| D11 | tenant_admin_live.ex 位置用 PR #740 | `autoservice/` 目录（与 customer_live/operator_live 同目录） |
