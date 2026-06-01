# 场景 23：ExternalMirrorWorker 冷启重新订阅

**类别**：11 — External mirror 绑定
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-27（PR #420 修复 task #49）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Feishu sidecar 运行
- 存在绑定：`{chat_id, app_id} → session://system/feishu-test`
- 对应 session 已冷启（即当前不在内存；从快照加载）

## 角色

- **调用方**：phx 启动时的 BootReconciler（或冷启时的 session loader）
- **目标**：绑定的 `ExternalMirrorWorker`

## 步骤

### 触发冷启

1. 停 phx（iex 中 `Ctrl+C` 两次）。
2. 验证 OS 级 `ExternalMirrorWorker` GenServer 消失（随 phx 终止）。
3. 重启 phx（`iex -S mix phx.server`）。
4. BootReconciler 跑：
   - 扫 `external_mirror_bindings` 表。
   - 对每行，确保 `WorkerRegistry` 中存在 worker。
   - 对**新** worker（冷启），调 `Worker.init/1`：
     - 加载绑定数据
     - 解析绑定的 `session_uri`
     - **订阅该 session 的 publisher PubSub**（PR #420 修复点）

### 验证

5. 在绑定 session 发消息。
6. Session publisher 发出事件。
7. 冷启的 worker 收到事件（因为在 init 订阅了）。
8. 出站到 Feishu sidecar 触发。
9. 验证消息出现在 Feishu chat。

## 预期结果

- BootReconciler 在 phx 启动窗口内完成。
- 启动后所有绑定都有 live worker。
- 冷启 worker 收到其绑定 session 的后续事件（只要事件发生在 worker init 之后无缺失）。

## 失败模式

- DB 中有绑定行但 session 已删除：BootReconciler 应标记绑定 `:orphaned` + 记日志供 admin 清理。（PR #418 部分覆盖）。
- Worker init 失败（例如 session pid 尚不可用 — session loader race BootReconciler）：经退避重试；PR #403 加 `reconcile_after_load` 解决。
- BootReconciler 扫描中崩溃：SagaRunner（PR #449）标记 operator-repair（Phase 1 在此层未测）。

## 交叉引用

- 相关 PR：
  - PR #312 — PR-EM-CORE
  - PR #334 — facade-audit IMPL
  - PR #403 — snapshot reconcile_after_load（restore 后 DB projection 联合 — task #34）
  - PR #418 — unbind projection 同步
  - PR #420 — worker 在冷启时重新订阅 session publisher（**核心** task #49 修复）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
- 测试：
  - `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_reconcile_test.exs`
  - `apps/ezagent_domain_external_mirror/test/invariants/no_pubsub_bypass_in_external_mirror_test.exs`
  - `apps/ezagent_core/test/integration/snapshot_restart_test.exs`（跨重启不变式）

## 备注

- 这是 worker 层的规范 "register/lookup key parity" 教训（`feedback_register_lookup_key_parity`）— 当 session 从快照重启时，其 publisher 订阅必须重建。
- 按 `feedback_north_star_plugin_isolation`，修复在 `ExternalMirror` Worker init 中，**非** Feishu plugin 代码。
