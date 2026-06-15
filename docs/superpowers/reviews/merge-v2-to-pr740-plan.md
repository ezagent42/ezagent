# 向 PR #740 合入 merge-v2 — 完整方案

> 日期: 2026-06-15 | 基线: PR #740 `045c76be` | 源: feat/autoservice-v2-merge-v2 `6ea66d81`

---

## 一、方向确认

```
PR #740 (基线) ← CsOrchestrator + TurnDriver 全面替换 B-minimal operator 路径

编排层: CsOrchestrator Behavior + TurnDriver → 替换 TurnAdapter 直驱
其他:   逐项评估，取最优
```

---

## 二、CsOrchestrator 替换论证

| operator 功能 | B-minimal (PR #740) | CsOrchestrator (merge-v2) | 选择 |
|---------------|---------------------|--------------------------|------|
| 接管: cancel bot turn | ❌ 无 | ✅ cancel_stale_turn | CsOrch |
| 接管: open fresh | ✅ TurnAdapter.open | ✅ TurnDriver.open | 等价 |
| 接管: compose 真实文本 | ✅ TurnAdapter.compose | ✅ TurnDriver.compose | 等价 |
| 接管: claim | ✅ TurnAdapter.claim | ✅ TurnDriver.claim | 等价 |
| 接管期间 operator_active | ❌ 无（仅 RuleStore.disable） | ✅ 双门控 | CsOrch 更安全 |
| 接管: settle | ✅ TurnAdapter.settle | ✅ TurnDriver.settle | 等价 |
| 接管: 放弃(cancel) | ✅ TurnAdapter.cancel | 可调用 TurnDriver.cancel | 等价 |
| 审计 | ✅ operator caps 传 TurnAdapter | ✅ operator caps 传 dispatch ctx | 等价 |
| P22 fan-out | ❌ MentionRouting 直连 | ✅ dispatch_after_commit | CsOrch 更安全 |

**CsOrchestrator 在所有维度上 ≥ B-minimal，没有理由共存。**

---

## 三、从 merge-v2 合入 PR #740 的完整清单

### 🔴 架构核心（完全替换 B-minimal operator 路径）

| 内容 | 文件 | 说明 |
|------|------|------|
| CsOrchestrator Behavior | `cs_orchestrator.ex` (new) | 3 actions，P22 fan-out，operator_active 双门控 |
| TurnDriver | `turn_driver.ex` (new) | 同进程 Turn 调用 + apply_turn_effects |
| Plugin 注册 | `application.ex` (+3行) | behaviors/0 → process_message, operator_claim, operator_settle |
| Customer routing | `customer_session.ex` (+4行) | session?action=cs_orchestrator.process_message 作 receiver |
| CsOrchestrator tests | `cs_orchestrator_test.exs` (new) | 16 tests |
| TurnDriver tests | `turn_driver_test.exs` (new) | 8 tests |

### 🟡 修复层（合入，不冲突）

| 内容 | 说明 |
|------|------|
| seed ctx: admin caller + bootstrap caps | 解决 slow cc agent 创建 |
| content sandbox init: TenantProvisioner.create_tenant | souls/slots/skills/kb 目录初始化 |
| liveview deps: +content/cr/autoservice | TenantAdminLive 引用可用 |
| CR atomic rename: ln_s → :file.rename | 已在两边一致 |

### 🟢 operator_live.ex: 从 PR #740 保留 + CsOrchestrator 改造

PR #740 的 `operator_live.ex` 有几个 merge-v2 没有的好东西：
- 🔴 send 在接管期间完全禁用（NO-OP）
- 🟡 cancel handler（operator 放弃接管）
- 🟡 注释完整（B-minimal flow 描述）

改造方案：
```
保留 PR #740 版本，将其 claim/settle handler 内部逻辑从 TurnAdapter 改为 CsOrchestrator dispatch:
  claim  →  dispatch cs_orchestrator.operator_claim (已有 operator text 参数)
  settle →  dispatch cs_orchestrator.operator_settle
  cancel →  dispatch cs_orchestrator.operator_settle + 或 单独 cancel
  send   →  NO-OP in claimed mode (保留 PR #740 逻辑)
```

### ❌ 不合入（用 PR #740 版本）

| 内容 | 文件 | 原因 |
|------|------|------|
| chat_ui 简化 | `chat_ui.ex` | 移除 submit_event/label attrs，接管时 composer 用 claim event |
| CustomerFeed token | `customer_live.ex` | PR #740 修复 settled replies render live |
| Slow agent URI | `uris.ex` | `cc_slow-` → `slow-` 与 Workspace.create_agent 一致 |
| Session rehydrate | `customer_session.ex` | spawn SocialwareSession |
| Debug log drop | `customer_session.ex` | 移除 crashing debug log |
| refresh.ex | 位置 | PR #740 的顶层更简洁 |
| Demo videos | docs/ | 已有录制 |
| 全部测试 | test/ | PR #740 的 5 个真实测试 |

---

## 四、实施步骤

### Step 1: 准备基线

```bash
git checkout feat/autoservice-v2-merge     # PR #740
git checkout -b feat/autoservice-v2-merge-integrated
```

### Step 2: 新增架构文件

从 merge-v2 复制 4 个新文件：
- `cs_orchestrator.ex`
- `turn_driver.ex`
- `cs_orchestrator_test.exs`
- `turn_driver_test.exs`

### Step 3: 修改已有文件

| 文件 | 改动 |
|------|------|
| `application.ex` | 加 `behaviors/0` |
| `customer_session.ex` | 加 orch_receiver routing |
| `liveview/mix.exs` | 加 content/cr/autoservice deps |
| `seed_autoservice.ex` | admin caller + content init |
| `operator_live.ex` | claim/settle handler 内部改为 CsOrchestrator dispatch（保留 send disabled + cancel） |
| `tenant_admin_live.ex` | 模块引用 dev 适配 |

### Step 4: 验证

```bash
mix compile
mix test                    # 全量通过（~31 tests）
mix ecto.reset && mix ezagent.demo.seed_autoservice --with-slow  # 0 errors
mix phx.server              # 所有入口可达
```

---

## 五、合入后架构

```
operator 接管:
  OperatorLive → cs_orchestrator.operator_claim (cancel → open → compose → claim)
              → cs_orchestrator.operator_settle (settle)
              → send disabled during takeover
  → CsOrchestrator 完全替换 B-minimal TurnAdapter 路径

customer 消息:
  chat.send → MentionRouting → session?action=cs_orchestrator.process_message
  → CsOrchestrator.handle_process_message → Turn.open + dispatch_after_commit fan-out

bot reply:
  bridge → chat.send → Chat → PubSub (即时投递，与 B-minimal 一致)

operator_active 双门控:
  CsOrchestrator 抑制 fan-out + RuleStore.disable 暂停 MentionRouting
```

---

## 六、决策记录

| # | 决策 | 理由 |
|---|------|------|
| D1 | CsOrchestrator 全面替换 B-minimal operator 路径 | 功能超集，无需共存 |
| D2 | PR #740 为基线 | 已验证，全面测试，demo |
| D3 | operator_live.ex 从 PR #740 改造 | 保留 send disabled + cancel，改 dispatch 目标 |
| D4 | chat_ui.ex 用 PR #740 | 简化版，submit_event/label 不再需要 |
| D5 | 测试用 PR #740 + merge-v2 架构测试 | 合计 ~31 tests |
| D6 | refresh.ex 用 PR #740 位置 | 顶层更简洁 |
| D7 | seed 用 merge-v2 修复 | admin caller + content init |
| D8 | liveview deps 用 merge-v2 | TenantAdminLive 需要 |
