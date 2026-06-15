# 向 PR #740 合入 merge-v2 方案

> 日期: 2026-06-15 | 基线: PR #740 `045c76be` | 源: feat/autoservice-v2-merge-v2 `6ea66d81`

---

## 一、方向确认

```
PR #740 (基线) ← 合入 merge-v2 的 CsOrchestrator + 其他价值内容

编排层: CsOrchestrator Behavior + TurnDriver ✅ 已决策
其他:   逐项评估，取最优
```

## 二、从 merge-v2 合入 PR #740 的内容

### 🔴 架构层（必须合入）

| 内容 | 文件 | 行数 | 说明 |
|------|------|------|------|
| CsOrchestrator Behavior | `cs_orchestrator.ex` | 412 | 注册在 SocialwareSession，3 actions，P22 fan-out |
| TurnDriver | `turn_driver.ex` | 87 | 同进程调 Turn handler（v3 §6.6.1），apply_turn_effects |
| Plugin 注册 | `application.ex` | +3行 | `behaviors/0` → 注册 3 个 action |
| Customer routing | `customer_session.ex` | +4行 | session 作 MentionRouting receiver → cs_orchestrator.process_message |
| CsOrchestrator tests | `cs_orchestrator_test.exs` | 16 tests | stateful ctx, handler 单元测试 |
| TurnDriver tests | `turn_driver_test.exs` | 8 tests | lifecycle, claim, cancel, error cases |

### 🟡 修复层（合入）

| 内容 | 文件 | 说明 |
|------|------|------|
| seed ctx 修复 | `seed_autoservice.ex` | admin caller + bootstrap caps → slow agent 可用 |
| content sandbox 初始化 | `seed_autoservice.ex` | `TenantProvisioner.create_tenant` → souls/slots/skills/kb |
| liveview plugin deps | `liveview/mix.exs` | 加 content/cr/autoservice deps → TenantAdminLive 可用 |
| TenantAdminLive dev 适配 | `tenant_admin_live.ex` | 模块引用适配（PR #740 的 autoservice/ 目录位置保留） |
| CR atomic rename | `cr_engine.ex` | ln_s → :file.rename 原子翻指针（已一致，确认） |

### 🟢 增量层（合入到 PR #740 已有文件）

| 内容 | 文件 | 合并方式 |
|------|------|---------|
| `operator_live.ex` | 在 PR #740 版本上，加 CsOrchestrator dispatch 路径 | 追加，不替换 B-minimal 路径 |
| `customer_session.ex` | PR #740 版本上加 `orch_receiver` routing | 在现有 receivers 里加一条 |
| `cr_engine.ex` | PR #740 已有 mark-before-flip + repair_current，确认一致 | 无需改动 |

### ❌ 不合入（PR #740 版本更优或不需要）

| 内容 | 原因 |
|------|------|
| merge-v2 的 `operator_live.ex` 全部 | PR #740 的 B-minimal + send disabled + cancel handler 更完整 |
| merge-v2 的 `chat_ui.ex` | PR #740 简化版（移除 submit_event/label attrs）更好 |
| merge-v2 的 6 个 stub 测试 | PR #740 有 5 个真实测试 |
| merge-v2 的 `assembly/refresh.ex` | PR #740 的 `refresh.ex` 顶层位置更简洁 |
| merge-v2 的 `turn_adapter.ex` | PR #740 已增强（operator caps 驱动 + cancel_turn） |

---

## 三、实施步骤

### Step 1: 准备 PR #740 工作分支

```bash
git checkout feat/autoservice-v2-merge   # PR #740 分支
git checkout -b feat/autoservice-v2-merge-integrated
```

### Step 2: 新增文件（从 merge-v2 直接复制）

```bash
# 架构核心
cp feat/autoservice-v2-merge-v2:apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex \
   apps/ezagent_plugin_autoservice/lib/ezagent/behavior/
cp feat/autoservice-v2-merge-v2:apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_driver.ex \
   apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/

# 测试
cp feat/autoservice-v2-merge-v2:apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/cs_orchestrator_test.exs \
   apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/
cp feat/autoservice-v2-merge-v2:apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/turn_driver_test.exs \
   apps/ezagent_plugin_autoservice/test/ezagent_plugin_autoservice/
```

### Step 3: 修改已有文件（手动合并）

**3a. `application.ex`** — 加 behaviors/0:

```elixir
def behaviors do
  [
    {Ezagent.Entity.SocialwareSession, :process_message, Ezagent.Behavior.CsOrchestrator},
    {Ezagent.Entity.SocialwareSession, :operator_claim, Ezagent.Behavior.CsOrchestrator},
    {Ezagent.Entity.SocialwareSession, :operator_settle, Ezagent.Behavior.CsOrchestrator}
  ]
end
```

**3b. `customer_session.ex`** — 在 `install_routing` 中加 orch_receiver:

```elixir
receivers = [fast_uri | slow_receivers(slow_uri)]
orch_receiver = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=cs_orchestrator.process_message")
receivers = [orch_receiver | receivers]
```

**3c. `liveview/mix.exs`** — 加 deps:

```elixir
{:ezagent_plugin_content, in_umbrella: true},
{:ezagent_plugin_cr, in_umbrella: true},
{:ezagent_plugin_autoservice, in_umbrella: true},
```

### Step 4: 移植 seed 修复

从 merge-v2 cherry-pick `6ea66d81`:
- `mix_task_ctx`: admin caller + bootstrap caps
- `init_tenant_content`: TenantProvisioner.create_tenant

### Step 5: TenantAdminLive dev 适配

将 PR #740 的 `autoservice/tenant_admin_live.ex` 中的模块引用替换为 dev 版本：
- `TenantPaths.sandbox_dir` → `TenantRuntime.sandbox_path`
- `CrStore.get` → `TenantConfig.read_cr(tid, "active")`
- `Lint.run` → `CrLint.check`
- `Publisher.publish` → `CrEngine.publish`（返回 shape 适配）
- `TenantContent.provision_context` → sandbox 文件直读

### Step 6: 验证

```bash
mix compile --warnings-as-errors
mix test                     # 全量通过
mix ecto.reset && mix ezagent.demo.seed_autoservice --with-slow   # 0 errors
mix phx.server               # 所有入口可达
```

---

## 四、合入后 PR #740 的结果

```
PR #740 基线:
  B-minimal operator 路径 ✅      (send disabled + cancel + TurnAdapter caps)
  全面测试 (5 文件) ✅
  CustomerFeed token ✅
  Slow agent URI fix ✅
  Session rehydrate ✅
  refresh.ex ✅
  chat_ui 简化版 ✅

+ merge-v2 贡献:
  CsOrchestrator Behavior ✅    (编排层)
  TurnDriver ✅                 (同进程 Turn)
  cs_orchestrator_test ✅       (16 tests)
  turn_driver_test ✅           (8 tests)
  seed 修复 ✅                  (admin caller + content init)
  liveview deps ✅              (TenantAdminLive 可用)
  TenantAdminLive dev 适配 ✅
  customer routing ✅           (session receiver)

= 最终:
  31 tests (23 PR #740 + 8 merge-v2)
  双路径: B-minimal (已验证) + CsOrchestrator (增量架构)
  框架补齐后自动升级到完整 Turn-for-everything
```

---

## 五、取舍决策

| # | 决策 | 理由 |
|---|------|------|
| D1 | PR #740 为基线 | 已验证，全面测试，demo 录屏 |
| D2 | CsOrchestrator 作为增量合入 | v3 设计决策，不改 B-minimal 已验证路径 |
| D3 | operator_live.ex 保留 PR #740 版本 | send disabled + cancel + TurnAdapter 审计 = 更完整 |
| D4 | chat_ui.ex 保留 PR #740 版本 | 简化版移除 submit attrs |
| D5 | 测试保留 PR #740 版本 | 真实测试 > stub |
| D6 | refresh.ex 保留 PR #740 位置 | 顶层更简洁 |
| D7 | seed 用 merge-v2 修复 | admin caller 解决 slow agent |
| D8 | content init 用 merge-v2 | TenantProvisioner 补全沙箱 |
| D9 | liveview deps 用 merge-v2 | TenantAdminLive 需要 content/cr/autoservice |
| D10 | TenantAdminLive 用 merge-v2 适配 | 模块引用已适配 dev 代码库 |
| D11 | customer_session routing 用 merge-v2 | session receiver 是 CsOrchestrator 必需的 |
| D12 | CsOrchestrator 不替换 B-minimal | 两者共存：B-minimal 用于 operator 接管，CsOrchestrator 用于 customer → fan-out → Turn.open |
