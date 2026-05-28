# 场景 10：@-mention 派发 — mention-gated 路由

**类别**：3 — Session 流程
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-26（PR #406 + PR #422）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 一个多成员 session：admin + 2 个 agent（例如 `entity://agent/system/echo_1` + `entity://agent/system/echo_2`）
- 默认路由规则激活：`always() → ["$session_members"]`（系统默认，仅 admin 可禁用）

## 角色

- **调用方**：admin
- **目标**：mention 命名的特定 agent
- **旁观者**：**未**被 mention 的另一个 agent
- **Behavior**：`Ezagent.Behavior.Chat`，action `:send`（mention 解析器 + 路由解析器）

## 步骤

1. 在 `/admin/sessions/<session-uri>` 发：`@echo_1 hello only you`。
2. 验证 mention 解析器识别 `@echo_1` 为 mention；路由解析器把接收者收窄到 `[entity://agent/system/echo_1]`。
3. 验证 `echo_1` echo 回。
4. 验证 `echo_2` **未**接收（无对应 `chat.receive` invocation 行）。
5. 发非 mention：`hello everyone`。
6. 验证两个 echo **都**接收（系统默认 `always → $session_members` 规则扇出）。

## 预期结果

- Mention 消息：1 个 `chat.receive` invocation（只 `echo_1`）。
- 非 mention：2 个 `chat.receive` invocation（两个 echo）。
- `Ezagent.Routing.MentionParser` 正确提取 `@echo_1`（URI 后缀 + workspace-prefix-aware）。
- 无 `mention_failed` 通知（mention 解析成功）。

## 失败模式

- `@nonexistent-agent`：PR #406 向 admin 触发 `mention_failed` 通知；消息**不**派给任何人。
- `@echo_1 @echo_2 hi`：两者被 mention → 两者接收，但不扇出到其他成员（mention-gated）。
- 前导空格 mention `   @echo_1`：解析器仍解析。
- 代码块内 mention：解析器**应当**跳过反引号内的 mention（TBD — 当前解析器**不**跳过）。

## 交叉引用

- 相关 PR：
  - PR #406 — 丢失 @-mention 的 mention_failed 通知
  - PR #422 — chore：修 umbrella-wide baseline（含 mention-routing 修复）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
- 测试：
  - `apps/ezagent_core/test/integration/mention_gated_routing_test.exs`
  - `apps/ezagent_plugin_feishu/test/mention_parser_test.exs`（Feishu 侧解析器；ezagent 侧解析器在 chat 测试覆盖）
- Open bug / gap：
  - 代码块 / 引用 / 词中的 mention 在 `MentionParser` 测试覆盖中未去重。

## 备注

- 系统默认 `always → $session_members` 规则让 "非 mention" 消息扇出；仅 admin 可禁用，不可删除（PR #120，Decision #120）。
- 按 Decision #80（`#80-#82`）和 SPEC `2026-05-22-mention-gated-routing.md`（现在 `superpowers/specs/`），mention-gating 是系统默认规则之上的**默认**行为。
