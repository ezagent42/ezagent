# 场景 15：撤销 cap + 非 admin 拒绝

**类别**：5 — 能力管理（CapBAC）
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-25（PR #356 r4 + cap-cleanup PR 系列）

## 前置条件

- 场景 14 刚跑过（Alice 持有发到 `sess_a` 的 cap）
- Alice 当前已登录

## 角色

- **调用方**：admin（撤销方）
- **目标**：Alice（`entity://user/system/alice`）
- **旁观者**：Alice 的活跃 LV/CLI session

## 步骤

### 撤销

1. 作为 admin 在 `/admin/users/alice/caps` 找到 Alice 的 cap 行；点 "Revoke"。
2. 确认。
3. 验证 DB `caps` 行删除（或标记 revoked，按 `caps_cleanup_v1` 实现）。
4. 验证 Alice 的 `kind_snapshots` slice `:identity.caps` 不再含该 cap。

### 拒绝测试

5. 作为 Alice（另一个浏览器 session），返回 `/admin/sessions/sess_a`。
6. 尝试发消息。
7. 验证派发失败 `:unauthorized`；LV flash 显示 "You don't have permission to send to this session"。
8. 经 CLI：`EZAGENT_TOKEN=<alice_token> mix ezagent chat send --target session://system/sess_a --message "test"`。
9. 验证 CLI 返回同 `:unauthorized`（CLI↔LV parity）。

### 审计

10. 在 `/admin/events`（或经 SQLite `select * from invocations where target_uri = '...' order by id desc limit 5`），验证两行 `:authz_denied` telemetry：一行 LV 尝试，一行 CLI 尝试。

## 预期结果

- 撤销写审计行（与 invocations 分离，若 cleanup-v1 r4 完整实现则在 `caps_audit`）。
- Allow 路径不再工作；deny 路径工作。
- LV + CLI 都显示一致 `:unauthorized`（`feedback_test_commands_before_suggesting`）。

## 失败模式

- Alice 派发中途撤销（race）：TOCTOU 窗口。今天派发开始后无 per-dispatch cap 重检；飞行中派发完成。
- 撤销不存在的 cap：`:not_found` + 幂等（admin 可重点不报错）。
- 撤销 admin 自己的 cap：admin role 豁免（`Ezagent.Entity.User.admin_caps/0`）是结构性的；经 LV 不可撤销（不在 `caps` — 见 Notes）。

## 交叉引用

- 相关 PR：
  - PR #356 — User-Kind 操作切出
  - PR #410 — Capability action 轴
  - cap-cleanup-v1 SPEC + r4-impl SPEC — `docs/superpowers/specs/2026-05-25-caps-cleanup-v1*.md`
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
- 测试：
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs`
  - `apps/ezagent_core/test/integration/non_admin_grant_flow_e2e_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`

## 备注

- Admin 的 `admin_caps/0` 是**模块函数**，非 `caps` DB 行 — 经 LV 表单不可撤销。这是结构性 admin 旁路。
- 按 `feedback_completion_requires_invariant_test`，cap 拒绝不变式测试是任何 Phase 2 Behavior 迁移的 gate。
- 按 `feedback_e2e_prefers_non_admin_user`，Alice 是 cap-grant E2E 流的规范用户。
