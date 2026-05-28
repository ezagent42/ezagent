# 场景 13：Feishu 入站消息 → 路由到 agent

**类别**：4 — Feishu 集成
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-27

## 前置条件

- Phx + Feishu sidecar 运行
- 场景 12 setup（`oc_83a4f1ff0bf627ffe26aa60647e5b04a` 的绑定存在）
- 一个 cc / curl / echo agent 是绑定 session 的成员
- 路由规则使 agent 接收 mention
- Feishu app webhook target 是 sidecar 公网 URL

## 角色

- **调用方**：在绑定 chat 中发消息的 Feishu 用户（可能是 Allen）
- **目标**：从 mention 或 `$session_members` 扇出解析的 agent
- **外部系统**：Feishu Open API webhook → sidecar → ezagent

## 步骤

1. 从 Feishu app（移动或桌面），在绑定 chat 发：`@<bot_name> hello agent`。
2. Feishu Open API POST webhook 到 sidecar。
3. Sidecar 解析 webhook + 经 JSON-RPC `incoming_message` POST 到 ezagent。
4. `Ezagent.PluginFeishu.FeishuAdapter.receive/1` 处理消息：
   - 经 `user_binding` 表解析发送用户（Feishu user_id → ezagent user URI）
   - 经 `inbound_chat_lookup` 解析 chat → session（`chat_id → session_uri`）
   - 验证 BindingPolicy（PR #426 — action-specific cap 授予）
   - 构造 Invocation：对 session 的 `chat.send`，`ctx.caller` = 解析出的用户
5. Session 扇出 + mention-gated 路由决定接收 agent（场景 10）。
6. Agent 处理 + 回复；回复经场景 12 出站流回。

## 预期结果

- `inbound_chat_lookup` 表有 `{chat_id, app_id, session_uri}` 行。
- `feishu_user_bindings` 表有入站用户绑定行。
- `invocations` 行：`chat.send`，`ctx.caller = entity://user/.../<feishu-resolved>`。
- Feishu 用户在 chat 看到 agent 回复。

## 失败模式

- Feishu 用户未绑定到 ezagent 用户：BindingPolicy 决定（按策略：拒绝 / 自动创建 / 配对提示）。见 `binding_policy_test.exs`。
- Webhook 签名无效：sidecar 拒绝；从不到达 ezagent。
- Sidecar 解析错误：400 给 Feishu；ezagent 不受影响。
- 绑定 session 已销毁：`:target_not_found`；sidecar 日志记死绑定供 admin 清理。
- Bot 被 mention 但无 agent 成员：PR #406 mention_failed（跨侧）。

## 交叉引用

- 相关 PR：
  - PR #426 — fix：BindingPolicy 中 action-specific cap 授予（§3.6.1(b)）
  - PR #403 — snapshot reconcile_after_load（restore 后 binding 联合）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  - `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
- 测试：
  - `apps/ezagent_plugin_feishu/test/inbound_chat_lookup_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_chat_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/binding_policy_test.exs`
  - `apps/ezagent_plugin_feishu/test/user_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/behavior/user_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/webhook_attachments_test.exs`
  - `apps/ezagent_plugin_feishu/test/sender_resolver_test.exs`
  - `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs`

## 备注

- Sidecar 是唯一持 Feishu app 凭据的进程；ezagent 从不直接看见。
- 按 Decision Log #298（GLOSSARY），Feishu webhook payload 可携非字符串 meta 值；PR #390 把这记为静默丢失风险（claude TUI 形态，非 Feishu，但底层教训通用）。
- 入站消息 + 出站消息 = Feishu 集成规范回路。
