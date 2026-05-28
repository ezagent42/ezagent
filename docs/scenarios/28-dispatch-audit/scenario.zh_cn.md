# 场景 28：派发审计行（invocations → EventLog）

**类别**：16 — 审计 + 可观测
**状态**：⏳ partially-implemented
**最近验证**：2026-05-28（EventLog 在 PR #447 落地；审计迁移是 Phase 2）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 有派发活动（例如场景 09 + 14 刚跑过）
- Admin 已登录
- Phase 1（PR #451）合并：EventLog 表存在，EventSubscriber 活跃

## 角色

- **调用方**：任何派发调用方
- **目标**：`invocations` 表（今天）、`event_log` 表（Phase 2 后）

## 步骤

### 今天（Phase 1）

1. 从 iex 或 `/admin/snapshots` LV 查询最新 `invocations` 行。
2. 每次 `Invocation.dispatch/1` 写一行：
   - `caller_uri`
   - `target_uri`
   - `behavior`
   - `action`
   - `args`（已 sanitize — 无 api-key；PR #389 清理）
   - `result`（`:ok` / `:unauthorized` / `:cross_workspace_denied` 等）
   - `inserted_at`
3. Telemetry 事件也触发：
   - `[:ezagent, :authz, :granted]` / `[:ezagent, :authz, :denied]`
   - `[:ezagent, :invocation, :start]` / `[:ezagent, :invocation, :stop]`
4. 验证拒绝场景（场景 15）写 `:authz_denied` 行。

### Phase 2 后（设想）

5. Phase 2 把 per-domain Behavior 迁移到新 `action/3` 宏后，新 `EventLog` 成为规范事件表。
6. 来自 `handle_<action>/2` 的每个 effect 可能向 `EventLog` 发出零或多个事件。
7. `StateRebuilder` 在启动时重放 `EventLog` 行（场景 25）以重建 Kind 状态。
8. `/admin/events` LV（**新** — 尚未发布）按 aggregate / workspace / 时间查询 `EventLog`。

### Telemetry dashboard（今天）

9. 注册 `:telemetry_metrics` 后，暴露到 Prometheus / 自定义 LV dashboard。
10. 追踪：invocations/sec、authz_denial_rate、平均派发延迟、top-10 调用方。

## 预期结果

- 今天：每次派发的完整 `invocations` 审计追踪。
- Phase 2 后：`EventLog` 承载可重放事件；`invocations` 可能保留（compat）或折入 EventLog。
- `args` 中无 api-key / 凭据泄漏（PR #389 sanitize 后）。

## 失败模式

- 审计写失败（磁盘满）：`Ezagent.Audit` writer 记日志 + 发 telemetry；派发继续（按 Decision #115，let-it-crash **不**应用）。
- Telemetry handler 崩溃：分离 + 记日志（Phoenix.LiveDashboard 处理）。
- 保留：今天无自动保留；手工 SQLite vacuum 是操作员选项。生产 GA 需保留策略 SPEC。

## 交叉引用

- 相关 PR：
  - PR #447 — feat(arch-p1b)：EventLog + EventSubscriber
  - PR #448 — SnapshotStore + StateRebuilder（消费 EventLog）
  - PR #389 — args sanitize（invocation args 中剥离 api-key）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5 — EventLog 作为一等原语
  - `docs/notes/2026-05-24-notification-log-audit.md` — 当前状态审计
- 测试：
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs` — 检查 `:authz_denied` 审计行
  - Phase 1 PR #447 在 `feat/p1b-events` 子分支的测试
- Open bug / gap：
  - **`/admin/events` LV 不存在**于今天。
  - **无保留策略** SPEC。
  - **Phase 2 迁移计划** for `invocations` → `EventLog` 是下一 SPEC（Phase 1 稳定后）。

## 备注

- 本场景追踪审计演进，从当前 `invocations` 表 → SPEC #445 的 `EventLog`。两者在 Phase 2 共存；Phase 3 删除旧路径。
- 按 `feedback_completion_requires_invariant_test`，审计完整性不变式 — "每次派发 ⇒ 恰好一行 events" — 是 Phase 2 架构 gate。
