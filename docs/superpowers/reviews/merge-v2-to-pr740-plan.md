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
| `turn_adapter.ex` | 已增强 operator caps + cancel_turn ✅ |
| `cr_engine.ex` | mark-before-flip + repair_current + 原子 rename ✅ |
| demo 文件 | 已录制 ✅ |

### 🔴 PR #740 文件中需要修改的内容（Codex 发现）

| 文件 | 问题 | 修复 |
|------|------|------|
| `roles.ex` | operator bundle 只授权 Turn caps，不授权 CsOrchestrator caps → 所有 cs_orchestrator.operator_claim/settle dispatch 返回 `:unauthorized` | 追加 `operator_cs_orchestrator_caps`（process_message/operator_claim/operator_settle） |
| `operator_live.ex` settle | 调用 `enable_session_rule` 但 settle 走 CsOrchestrator 后应由其管理 | 移除 settle 中的 RuleStore 调用，由 CsOrchestrator 的 operator_settle 效果管理 |
| `operator_live.ex` cancel | 调用 `enable_session_rule` + 不重置 CsOrchestrator 的 `open_turn_id` | 保留 RuleStore 调用（cancel 是轻量 TurnAdapter 路径），但需额外 dispatch 重置 CsOrchestrator state |
| `operator_live.ex` claim | 调用 `disable_session_rule` | 保留（与 CsOrchestrator operator_active 组成双门控），待后续 CsOrchestrator 内部接管 RuleStore 管理后移除 |
| `operator_live.ex` settle | 不 unsubscribe CustomerFeed topic | settle 后加 unsubscribe |
| `cs_orchestrator.ex` | `handle_operator_claim` 只设 `operator_active=true`，不 disable routing rules | 当前由 operator_live 外部管理 RuleStore；后续迭代应移入 CsOrchestrator 效果列表 |
| `cs_orchestrator.ex` | `normalize_message/1` 用 `String.to_existing_atom/1` → runtime 遇未知 key 崩溃 | 改用 `String.to_atom/1` 或白名单匹配 |
| `customer_session.ex` routing | orch_receiver **前置**于 fast/slow，若 Resolver 匹配所有 receivers 则造成 agent 重复收消息 | 确认框架行为：若 Resolver 只投递**首个匹配** receiver，则追加安全；若全量投递，则必须移除 fast/slow。实施时验证 |

### ⚠️ 测试适配

| 测试 | 问题 | 修复 |
|------|------|------|
| `operator_takeover_gating_test.exs` | 测试 TurnAdapter 直驱 + Turn caps；CsOrchestrator dispatch 需要 CsOrchestrator caps | 改为 dispatch cs_orchestrator.operator_claim/settle，用包含 CsOrchestrator caps 的 operator bundle |
| `operator_live.ex` cancel | 改为 dispatch cs_orchestrator.action 重置 state | 或保留 TurnAdapter.cancel + 追加 state reset dispatch |
| `turn_driver_test.exs` | merge-v2 新增，与 PR #740 无冲突 | 直接复制 ✅ |

### ⚠️ 其他注意

| 项 | 说明 |
|----|------|
| `seed_autoservice.ex` | PR #740 路径为 `apps/ezagent_plugin_autoservice/lib/mix/tasks/ezagent.demo.seed_autoservice.ex`，与 merge-v2 相同路径 ✅ |
| version 冲突 | PR #740 `application.ex` version `"0.2.0"`，merge-v2 `"0.3.0"` → 用 `"0.3.0"` |
| 死代码 | `handle_agent_reply` (~30行) 因框架约束 #2 暂不可达，保留待框架升级 |
| 测试数 | 预计 ~47，但 `operator_takeover_gating_test` 需重写 → 实际约 40-45 |

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
| D12 | 双门控：RuleStore + operator_active | operator_live 继续管理 RuleStore；后续迭代移入 CsOrchestrator 效果 |
| D13 | routing 保留 fast/slow 为 fallback | 若框架匹配全部 receivers 则需移除；实施时验证 |

---

## 七、Codex Review 摘要 (2026-06-15)

**结论: 方案方向正确，发现 10 个具体问题（3 HIGH / 4 MEDIUM / 3 LOW），已全部纳入计划。**

| # | 严重度 | 问题 | 状态 |
|---|--------|------|------|
| 1 | 🔴 HIGH | `roles.ex` operator bundle 缺 CsOrchestrator caps → `:unauthorized` | 已纳入修改清单 |
| 2 | 🔴 HIGH | `operator_live.ex` settle/cancel 的 RuleStore 调用与 CsOrchestrator 双门控冲突 | 已纳入修改清单 |
| 3 | 🔴 HIGH | `handle_operator_claim` 不 disable routing rules | 双门控设计，operator_live 外部管理 |
| 4 | 🟡 MEDIUM | routing `[orch, fast, slow]` — 需验证框架是否全量匹配 | 实施时验证 |
| 5 | 🟡 MEDIUM | settle handler 不 unsubscribe CustomerFeed | 已纳入修改清单 |
| 6 | 🟡 MEDIUM | `normalize_message` `String.to_existing_atom` 崩溃风险 | 已纳入修改清单 |
| 7 | 🟡 MEDIUM | `seed_autoservice.ex` 路径确认 | 已确认与 merge-v2 相同 |
| 8 | 🟢 LOW | cancel 不重置 CsOrchestrator `open_turn_id` | 轻量 TurnAdapter 路径，可接受 |
| 9 | 🟢 LOW | `handle_agent_reply` 死代码 ~30行 | 保留待框架升级 |
| 10 | 🟢 LOW | version 冲突 0.2.0 vs 0.3.0 | 用 0.3.0 |
