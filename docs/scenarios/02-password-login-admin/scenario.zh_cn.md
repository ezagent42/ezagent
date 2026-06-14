# 场景 02：密码登录 — admin

**类别**：1 — 认证 / Identity
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-21（Allen，Phase 9 demo 截图）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 默认 admin 用户 seed：`entity://system/user/admin`，密码 `8bdemo`
- Dev seed 在首次启动经 `EzagentCore.Bootstrap` 运行（见 `mix ezagent.bootstrap`）

## 角色

- **调用方**：匿名浏览器 session
- **目标**：`entity://system/user/admin`

## 步骤

1. 在 agent-browser 打开 `http://100.64.0.27:10042/login`。
2. 输入 username `admin`、workspace `system`、密码 `8bdemo`。
3. 点 "Sign in"。
4. 验证 LV 重定向到 `/admin`。
5. 验证 workspace 下拉（右上）显示 `system` 已选。
6. 给 `/admin` 拍 agent-browser 截图，显示 workspace + chat 面板。

## 预期结果

- LV session 的 `assigns.current_user.uri == entity://system/user/admin`。
- LV session 的 `assigns.current_user.caps` 包含 `admin_caps()`（5 轴 `:any`）。
- 发出 telemetry `[:ezagent, :auth, :login_succeeded]`。
- `users.last_login_at` 被更新。

## 失败模式

- 错密码（3 次）：今天无锁定（dev 故意；生产需要 rate-limit）。
- 错 workspace 名：返回 "User not found in workspace 'foo'"。
- 缺 workspace 字段：表单重渲染 + 验证错误。

## 交叉引用

- 相关 PR：
  - PR #356 — `Behavior.WorkspaceUserAdmin :create_user`（按 cap-shape 限制单独 Behavior 切出）
  - PR #389 — api-key 从 User 翻到 Agent Kind（厘清了哪个 Kind 持有登录状态）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-20-username-and-auth-design.md`
- 测试：
  - `apps/ezagent_web/test/integration/magic_link_invariants_test.exs`（覆盖 Identity Behavior shape）
  - `apps/ezagent_core/test/integration/caps_denial_e2e_test.exs`（覆盖登录后 cap 行为）
- 证据：
  - `docs/notes/phase-9-demo-2026-05-21.md` — admin 登录 + admin dashboard 截图

## 备注

- Admin cap 是结构性的（5 轴 `:any`），不是 wildcard fallback — 见 `feedback_let_it_crash_no_workarounds`。
- 按 `feedback_uuid_is_canonical_identifier`，username 是可变的显示字段；LV 在登录时解析 username → UUID。
- 按 `feedback_e2e_prefers_non_admin_user`，cap-grant 流程的规范 e2e 使用非 admin 用户 — admin 登录是 setup 前置，不是受测单元。
