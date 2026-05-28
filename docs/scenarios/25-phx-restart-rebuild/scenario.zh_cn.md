# 场景 25：Phx 重启 — 快照重建 + ExternalMirror

**类别**：13 — 恢复 + 启动
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-28（Phase 1 PR #451 + `snapshot_restart_test.exs`）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 大量 seed 状态：
  - 2 个 workspace，共 5 个 agent
  - 跨 workspace 3 个 session，有成员 + 最近聊天历史
  - 1 个 Feishu 绑定
  - 至少 1 个非 admin 用户被授予 cap
- Admin 已登录

## 角色

- **调用方**：操作员（phx 重启触发器）
- **目标**：
  - `StateRebuilder`（PR #451）— 重放 EventLog
  - `SnapshotStore`（PR #451）— per-Kind r/w
  - `BootReconciler`（在 ExternalMirror）— 扫绑定
  - Kind 特定 `reconcile_after_load/2` 回调（PR #403）

## 步骤

### 重启前快照

1. 记录所有运行 PTY 的 OS PID（cc agent、np agent）。
2. 注意某个 session 中一个进行中对话的当前状态。
3. 注意非 admin 用户被授予的 cap。

### 重启

4. iex 中 `Ctrl+C` `Ctrl+C`；用 `iex -S mix phx.server` 重启。

### 重启后验证

5. 看 phx 启动日志；验证：
   - Kind worker 从 `kind_snapshots` 行 spawn。
   - `StateRebuilder` 重放 EventLog 补任何快照后事件。
   - `BootReconciler` 走 `external_mirror_bindings`；spawn worker；订阅 publisher（场景 23）。
   - Per-Kind `reconcile_after_load/2` 调和任何仅 DB 状态（例如 restore 后 session_members 联合 — PR #403 task #34）。
6. 验证 `/admin` LV mount；workspace 下拉填充。
7. 验证非 admin 用户仍可登录 + 有同样 cap。
8. 在某恢复的 session 发消息；验证 agent（cc / curl / echo）响应。
9. 在绑定 chat 发 Feishu 消息；验证路由回 session。
10. 验证旧 PTY OS PID **消失**；pid-file 中是新 OS PID。

## 预期结果

- **所有** Kind 恢复：agent、session、workspace、user、template、binding。
- **所有** cap 保留：快照含 `:identity.caps`（按 `cap_action_axis_snapshot_restore_test.exs`）。
- **所有**绑定重新激活：`ExternalMirrorWorker` 重新订阅（场景 23）。
- 无数据丢失，除了瞬态内存状态（例如飞行中的瞬态路由决策）。

## 失败模式

- 损坏的快照行：`term_to_binary` 解码失败；StateRebuilder 记日志 + 回退到新鲜 init（Decision #115 — "Q5: added Behavior 是 Map.merge(fresh, loaded) 保新 slice fresh init"）。
- EventLog 重放遇到已删除 Kind：跳过 + 记日志；启动不失败。
- 重启后写快照时磁盘满：Decision #115 — 记日志 + telemetry + 继续（let-it-crash **不**应用于磁盘满）。

## 交叉引用

- 相关 PR：
  - PR #115（Decision #115）— Snapshot per-Kind 真 r/w + 5 策略
  - PR #403 — snapshot reconcile_after_load（task #34）
  - PR #447 — feat(arch-p1b)：EventLog + EventSubscriber
  - PR #448 — feat(arch-p1c)：SnapshotStore + StateRebuilder
  - PR #449 — feat(arch-p1d)：SagaRunner
  - PR #450 — feat(arch-p1a)：Cmd、Router、Behavior 宏、Kind ext、LegacyAdapter
  - PR #451 — Phase 1 整合
  - PR #420 — ExternalMirrorWorker 冷启重新订阅
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5（StateRebuilder、SnapshotStore、EventLog）
- 测试：
  - `apps/ezagent_core/test/integration/snapshot_restart_test.exs` — **核心**不变式测试
  - `apps/ezagent_core/test/integration/cap_action_axis_snapshot_restore_test.exs`
  - `apps/ezagent_core/test/integration/session_survives_restart_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_e2e_test.exs` — cc 编排器重生

## 备注

- 这是 master README §6 优先级 2 — 快照恢复是 22-Behavior Phase 2 迁移的安全网。
- 按 `feedback_completion_requires_invariant_test`，`snapshot_restart_test.exs` 是架构 gate — 此处任何回归阻塞 Phase 2 PR。
- Phase 1 PR #451 deliverable 本身在生产重启场景中未测；EventLog 激活后首次真重启是 Phase 1 合并后的 smoke。
