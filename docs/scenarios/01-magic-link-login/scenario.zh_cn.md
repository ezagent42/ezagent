# 场景 01：Magic-link 邮件登录

**类别**：1 — 认证 / Identity
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-21（Allen，Phase 9 demo）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Mailer dev 后端捕获已发邮件（`Swoosh.Adapters.Local`）；收件箱在 `/dev/mailbox`
- Dev 邮件传输：消息显示在 Phoenix 收件箱 UI，非真实 SMTP
- 存在已验证邮箱的用户；默认 seed 是 admin（`entity://user/system/admin`）

## 角色

- **调用方**：匿名浏览器 session
- **目标**：`entity://user/<workspace>/<username>`（例如 `entity://user/system/admin`）
- **外部系统**：Mailer（dev 用 Swoosh 本地适配器）

## 步骤

1. 在 agent-browser（headless Chrome）打开 `http://100.64.0.27:10042/login`。
2. 在 magic-link 字段输入用户邮箱；点 "Send link"。
3. 第二个标签打开 `http://100.64.0.27:10042/dev/mailbox`；点最近的消息。
4. 从邮件正文提取 magic-link URL（`/auth/magic/<token>`）。
5. 在原标签访问该 URL。
6. 验证 LV 重定向到 `/admin` 且 session 已认证为目标用户。

## 预期结果

- `users.last_login_at` 被更新。
- 写入一行 `invocations`，`behavior=Ezagent.Behavior.Identity action=:magic_link_login`。
- 浏览器 session 在 LV socket assigns 中携带 `user_uri`。
- 后续导航到 `/admin/sessions/...` 成功（LV mount）。

## 失败模式

- Magic-link token 过期（>15 分钟）：预期 "Link expired" flash + 重定向到 `/login`。
- Magic-link token 重用：预期 "Link already consumed" flash。（当前**未**强制 — 见 Notes。）
- 邮箱未注册：预期通用 "If the email exists, a link was sent" 消息（无枚举）。

## 交叉引用

- 相关 PR：
  - 无直接 PR；controller 可追溯到 Phase 1
- 相关 SPEC：无 — magic-link 早于 SPEC 纪律
- 测试：
  - `apps/ezagent_web/test/integration/magic_link_invariants_test.exs` — 只覆盖 token 生成 + 过期
- Open bug / gap：
  - Magic-link 重用**未**阻止（过期窗口内重用 token 会再次登录）。值得加单测 + one-shot-token 强制。
  - 跨 workspace magic-link（多 workspace 用户登录后默认到哪个 workspace）未规约。见场景 17。

## 备注

- 仅 dev 用 Swoosh local 适配器；生产需要 SES/Resend 接入（暂无 SPEC）。
- `feedback_uuid_is_canonical_identifier`：magic-link token 引用用户 UUID，不是 username。
- 本场景标 ⚠️ 因为重用 + 多 workspace gap 未 codified 为测试。
