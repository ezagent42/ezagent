# 场景 14：LV 授予 cap（action 轴）

**类别**：5 — 能力管理（CapBAC）
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-27（PR #410 + #426 action-axis 修复）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 存在非 admin 用户 U：`entity://user/system/alice`
- 存在 agent A：`entity://agent/system/echo_x`

## 角色

- **调用方**：admin
- **目标**：用户 U（`entity://user/system/alice`）
- **能力主体**：5 轴 cap `{kind, behavior, action, instance, workspace_uri}`

## 步骤

1. 打开 `/admin/users/alice/caps`（或 `/admin/caps?subject=alice`）。
2. 点 "Grant cap"；填：
   - Kind：`Ezagent.Entity.Session`
   - Behavior：`Ezagent.Behavior.Chat`
   - Action：`:send`（action 选择器下拉 — 当前 gap 见 Notes）
   - Instance：`session://system/sess_a`（特定）或 `:any`
   - Workspace：`workspace://system`
3. 提交；验证 DB 中 `caps` 行 + 显示新 cap 的 flash。
4. 登录为 Alice（场景 02，但用 Alice 密码）。
5. 在 `/admin/sessions/sess_a` 发 "hello"；验证派发成功（cap 匹配）。
6. 尝试发到**不同** session `session://system/sess_b`；验证 `:unauthorized`（instance 窄）。
7. 尝试 `Ezagent.Behavior.Routing :add_rule`；验证 `:unauthorized`（behavior + action 窄）。

## 预期结果

- DB 中 `caps` 行携 5 轴 cap。
- U 的 `kind_snapshots` 行更新（cap 在 slice `:identity.caps`）。
- Allow 路径：匹配派发成功。
- Deny 路径：不匹配派发失败 `:unauthorized`（按 `authz_check`，Invocation §5.5）。

## 失败模式

- 授予 `:cross_workspace` cap（仅 admin）：非 admin 该 action 选择器选项应禁用。
- 授予 `action: :any` cap：今天 admin 经 "admin-role 豁免" 可做；非 admin 授予表单**不**应显示此选项（todo 条目）。
- 授予不存在 kind/behavior 的 cap：表单应拒绝（经 `BehaviorRegistry` 编译期检查）。
- 授予 + 撤销 + 授予：每次操作写新 `caps` 行；撤销是删除。

## 交叉引用

- 相关 PR：
  - PR #410 — feat：Capability struct 加 action 轴
  - PR #264 — CapabilityRegistry（初版 cap-needed 表）
  - PR #265 — Presence cap-gate
  - PR #356 — User-Kind Behavior 切出（cap-shape workaround）
  - PR #426 — fix：BindingPolicy 中 action-specific cap 授予
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-23-capability-registry.md`
  - `docs/superpowers/specs/2026-05-27-capability-action-axis.md`
  - `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
- 测试：
  - `apps/ezagent_core/test/integration/cap_action_axis_invariant_test.exs`（**核心**不变式）
  - `apps/ezagent_core/test/integration/cap_action_axis_snapshot_restore_test.exs`
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs`
  - `apps/ezagent_core/test/integration/non_admin_grant_flow_e2e_test.exs`
  - `apps/ezagent_core/test/integration/routing_cap_test.exs`
  - `apps/ezagent_domain_identity/test/ezagent/behavior/identity_grant_test.exs`
- 证据：
  - `docs/notes/caps-e2e-design.md` — 为何 cap "感觉看不见" + 测试设计
- Open bug / gap（todo）：
  - "Entity-caps LV grant form needs action-selector dropdown (post action-axis PR)" — 当前 admin-role 豁免桥接；将来 PR 加下拉。
  - "Admin promotion cap-lifecycle cleanup" — 临时提升 cap 在降级后存活。

## 备注

- Cap struct shape 是 `{kind, behavior, action, instance, workspace_uri}` — 5 轴（PR #410）。5 维全配才授权 action。
- Admin 持 `%{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}` — 结构性，不是 wildcard fallback（`feedback_let_it_crash_no_workarounds`）。
- 本场景是 master README §6 优先级 5 — 通过 Phase 2 迁移保留 action-窄授予是定义性不变式。
