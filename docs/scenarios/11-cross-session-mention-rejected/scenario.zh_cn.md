# 场景 11：跨 session @-mention 被拒

**类别**：3 — Session 流程
**状态**：✅ implemented-and-tested
**最近验证**：2026-06-14 — 核心「跨 session 泄漏」不变式已 codified 于 `apps/ezagent_domain_instance_message/test/e2e/category_10_scenarios_10_11_mention_routing_test.exs`，describe `"Scenario 11 — cross-session mention rejected"`（4 个测试，绿）。`mention_failed` 通知（步骤 5）由 PR #406（`mention_failed_notification`，见场景 10）单独覆盖。

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 同 workspace 中 2 个 session：`session://system/sess_a` 和 `session://system/sess_b`
- Agent `entity://agent/system/echo_x` 是 `sess_a` 成员但**不是** `sess_b` 成员

## 角色

- **调用方**：admin（在 `sess_b`）
- **目标**：`echo_x`（**不是** `sess_b` 成员）

## 步骤

1. 打开 `/admin/sessions/sess_b`。
2. 发：`@echo_x hello from b`。
3. 验证路由解析器从接收者中排除 `echo_x`（它不在 `sess_b` 的 `$session_members`）。
4. 验证 `echo_x` **不**收到 `chat.receive` invocation。
5. 按 PR #406，admin 应看到 `mention_failed` 通知："@echo_x is not a member of this session"。

## 预期结果

- `echo_x` 的 `chat.receive` invocation 数为 0（无跨 session 泄漏）。
- `mention_failed` 通知在 `sess_b` LV 可见。
- 审计追踪条目显示 mention 尝试 + 路由决策拒绝。

## 失败模式

- `echo_x` 是两个 session 的成员：mention **确实**派达（这是 happy path；非失败）。
- Admin 先手工把 `echo_x` 加入 `sess_b`，再 mention：派达成功；这是显式允许路径。

## 交叉引用

- 相关 PR：
  - PR #406 — mention_failed 通知
  - PR #120（Decision #120）— `$session_members` 魔法 receptor token
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - （跨 session 泄漏防护在路由解析器设计中隐式）
- 测试：
  - `apps/ezagent_domain_instance_message/test/e2e/category_10_scenarios_10_11_mention_routing_test.exs`，
    describe `"Scenario 11 — cross-session mention rejected"`（4 个测试，2026-06-14 绿）：
    - mention 一个**不在**当前 session 成员中的 agent → 0 接收者（泄漏防护）；
    - 正向对照：in-session mention **确实**派达；
    - `$mentions` 里的跨 workspace 成员 URI 被丢弃；
    - `$mentions` 里的 session URI（跨 session 路由）被丢弃。
  - `mention_gated_routing_test.exs` 覆盖 in-session mention happy path。
- Open bug / gap：
  - `mention_failed` 通知（步骤 5）通过 PR #406 的 `mention_failed_notification` 测试（见场景 10）覆盖，不在本路由解析器测试内。
  - 审计追踪条目（预期结果 3）尚无专门断言。

## 备注

- 路由解析器在派发时 per-session 评估 `$session_members`；自然阻止跨 session 泄漏，且现已作为不变式断言（见「测试」）。
- 该安全不变式是 socialware 基座化（im→session→agent）拆分的承重回归守卫：跨 session 泄漏防护位于 session 域的路由解析器，因此在 PR-9a/9b 路由/解析器代码迁移期间必须保持绿。
