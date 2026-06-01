# 场景 07：curl agent — spawn → DeepSeek 往返

**类别**：2 — Agent 生命周期
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-19（PR #126 证据）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 手头有 DeepSeek API key（`sk-deepseek-...`）
- Admin 已登录
- 一个非 admin 用户（按 `feedback_e2e_prefers_non_admin_user` 优先）持 api-key

## 角色

- **调用方**：admin 或非 admin 用户
- **目标**：curl agent `curl-agent://my-deepseek`（Kind：`Ezagent.Entity.CurlAgent`）
- **外部系统**：`https://api.deepseek.com/chat/completions`（或 OpenAI 兼容）

## 步骤

1. 登录非 admin 用户 U。
2. 打开 `/admin/users/<U>/api-keys`；点 "Add api key"；provider `deepseek`，key `sk-deepseek-...`。
3. 验证 key 在 LV 显示为 mask（如 `sk-06a5...0a7c`）。
4. 打开 `/admin/templates`；点 "Create curl.agent template"；填：
   - `class = curl.agent`
   - `agent_uri = curl-agent://my-deepseek`
   - `provider = deepseek`
   - `api_url = https://api.deepseek.com/chat/completions`
   - `owner_uri = entity://user/system/<U>`（api-key 所在）
5. 打开 `/admin/routing`；为 session 添加规则 `{:always} → ["curl-agent://my-deepseek"]`。
6. 在 `/admin/sessions/<session-uri>` 发："DeepSeek say hello in one sentence please"。
7. 验证 curl agent 向 DeepSeek POST + 把回复 append 到 session。

## 预期结果

- User Kind 的 `:api_keys` slice 含 key（按 PR #389，api-key Behavior 在 Agent Kind，但场景链仍从 User → Agent）。
- 派发链：user `chat.send` → 路由 → `curl-agent://my-deepseek` `chat.receive` → http POST → 回复 → agent 的 `chat.send`。
- Session 显示 admin 消息 + agent 回复。
- 任何日志、审计行、session 消息中均无 api-key（`apps/ezagent_plugin_curl_agent/lib/ezagent/...` mask）。

## 失败模式

- 无效 api-key：DeepSeek 返回 401；curl agent 发 `chat.send` "Error: 401 unauthorized" — admin 在 session 看到错误（**不**泄漏 key）。
- DeepSeek 不可达：`:httpc` 重试 N 次，然后向 session 抛超时错误。
- 用户无 api-key：`:get_api_key` 派发失败；curl agent 向 session 抛 "missing api-key for provider deepseek"。

## 交叉引用

- 相关 PR：
  - PR #126 — curl-agent plugin（初始）
  - PR #389 — api-key flip 到 Agent Kind
- 相关 SPEC：无（PR #126 早于 SPEC 纪律）
- 测试：
  - `apps/ezagent_plugin_curl_agent/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs`（api-key slice）
- 证据 + runbook：
  - `docs/notes/curl-agent-walkthrough.md`
  - `docs/notes/evidence/pr126-curl-agent-deepseek-e2e.webm`
  - `docs/notes/evidence/pr126-04-deepseek-reply.png`

## 备注

- curl agent 用 `:httpc`（Erlang stdlib）做 HTTP，与 Feishu plugin 的 stdlib-only 选择一致 — 无新 dep。
- URI scheme 是 `curl-agent://`（与 `agent://` 区分），按 Decision Log 拥有自己的 `(Kind, action)` registry 项。
- 这是今天 per-user-key、per-agent-instance 场景最干净的示例。
