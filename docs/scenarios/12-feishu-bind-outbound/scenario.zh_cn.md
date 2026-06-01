# 场景 12：Feishu chat ↔ session 绑定 + outbound

**类别**：4 — Feishu 集成
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-27（PR #420 冷启 fix Allen 已验证）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Feishu sidecar 进程运行 + 可达（经 `EZAGENT_FEISHU_*` env 配置）
- Feishu app 凭据已配（app_id、app_secret）
- 有可用的测试 Feishu chat（dev chat：`oc_83a4f1ff0bf627ffe26aa60647e5b04a`）
- Admin 已登录
- 存在一个 session：`session://system/feishu-test`

## 角色

- **调用方**：admin（绑定侧）；session 成员 agent（出站侧）
- **目标**：外部镜像绑定 `<chat_id, app_id> → session://system/feishu-test`
- **外部系统**：Feishu sidecar；Feishu Open API

## 步骤

### 绑定

1. 打开 `/admin/sessions/<session-uri>/external-mirror`（或 `/admin/external-mirror`）。
2. 点 "Bind Feishu chat"；填 `chat_id = oc_83a4f1ff0bf627ffe26aa60647e5b04a`、`app_id = <dev_app_id>`。
3. `Behavior.ExternalMirror :bind` action 跑：
   - Cap 检查（admin 有）
   - 目标拥有检查（admin 拥有 session）
   - Workspace 隔离检查（绑定 workspace 与 session workspace 匹配）
   - 持久化 `external_mirror_bindings` 行
   - 为绑定 spawn `ExternalMirrorWorker`（`Registry` 以 `{chat_id, app_id}` 为 key）
4. Worker 订阅 session publisher（`Ezagent.Session.PublisherPubSub`）。

### 出站

5. 在 `/admin/sessions/<session-uri>` 发："hello from ezagent"。
6. Session publisher 发出 chat 事件。
7. `ExternalMirrorWorker` 收到事件 + 调 `FeishuAdapter.event_to_payload/1` 构造 Feishu 消息 JSON。
8. Worker 经 JSON-RPC POST 到 Feishu sidecar；sidecar 调 Feishu Open API。
9. 验证消息出现在 dev Feishu chat。

## 预期结果

- `external_mirror_bindings` 行持久。
- Worker 注册在 `Registry.lookup({:via, Registry, {Ezagent.ExternalMirror.WorkerRegistry, {chat_id, app_id}}})`。
- `invocations` 行：`bind`。
- 出站：sidecar 日志记录 1 次 Feishu API 调用。

## 失败模式

- Sidecar 不可达：出站写重试 N 次；绑定行持久；sidecar 恢复后，缺失事件**不**重放（gap — 见 Notes）。
- 同 `{chat_id, app_id}` 重复 bind：`:already_bound`。
- Bind 到不同 workspace 的 session：`:cross_workspace_denied`。
- Bot 已从 Feishu chat 被踢：出站 API 报错；worker 应自动 unbind（PR #418 部分覆盖）。

## 交叉引用

- 相关 PR：
  - PR #312 — PR-EM-CORE（ExternalMirror 基础设施）
  - PR #418 — unbind projection 同步 + session routing 导航
  - PR #420 — worker 在冷启时重新订阅 session publisher（task #49）
  - PR #334 — facade-audit IMPL
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  - `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
- 测试：
  - `apps/ezagent_domain_external_mirror/test/ezagent/external_mirror/facade_test.exs`
  - `apps/ezagent_domain_external_mirror/test/ezagent/external_mirror/binding_row_test.exs`
  - `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_reconcile_test.exs`
  - `apps/ezagent_domain_external_mirror/test/invariants/no_pubsub_bypass_in_external_mirror_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_chat_binding_test.exs`
  - `apps/ezagent_plugin_feishu/test/feishu_adapter_test.exs`
- Open bug / gap（todo 条目）：
  - "AdapterRegistry / BindingRegistry `:public` ETS hardening" — CRIT 推迟
  - "Facade-auth-model security audit" — PR-EM-3 5 轮的 META finding
  - "AdapterInstall ordering vs BindingRegistry atomicity" — 部分失败时 split-brain
  - "bind spawn-before-persist split-brain" — `:bind` 在 persist 前 spawn worker

## 备注

- 按 Allen 2026-04-XX `feedback_register_lookup_key_parity`，`{chat_id, app_id}` key 必须在 register 时 + lookup 时一致。
- Sidecar 恢复时缺失事件重放是 open gap — 当前未工程化。
- `feedback_plugin_external_integration_is_receiver_kind`（2026-05-17）规则是驱动整个 `ExternalMirror` domain 提取的教训。
