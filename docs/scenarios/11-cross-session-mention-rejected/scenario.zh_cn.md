# 场景 11：跨 session @-mention 被拒

**类别**：3 — Session 流程
**状态**：⚠️ implemented-with-gaps
**最近验证**：从未作为 codified 场景（规则隐式强制）

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
  - 无专门的跨 session mention 拒绝测试。`mention_gated_routing_test.exs` 仅覆盖 in-session mention。
- Open bug / gap：
  - **无跨 session 泄漏防护的回归测试**。这是安全属性；应加不变式测试断言 "不在 session 的 agent 永不收到来自该 session 的 chat.receive invocation"。

## 备注

- 路由解析器在派发时 per-session 评估 `$session_members`；自然阻止跨 session 泄漏但未作为不变式断言。
- ⚠️ 状态反映：生产行为正确，但 codified 场景 + 不变式测试不存在。
- 推荐在 Phase 2 把 `Chat.Behavior` 迁移到新 `action/3` 宏前加本场景 — 见 master README §6 次级投资。
