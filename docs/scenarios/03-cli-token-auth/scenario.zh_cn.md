# 场景 03：Token CLI 认证 — mint / list / revoke

**类别**：1 — 认证 / Identity
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-26（PR #386 重命名 smoke）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 操作员在 LV 登录为 admin（场景 02）
- `mix ezagent` CLI 可用（PR #386 从 `mix esr` 重命名后）
- `EZAGENT_HOME=~/.ezagent` 已设（或默认）

## 角色

- **调用方（LV mint）**：admin（`entity://user/system/admin`）
- **调用方（CLI 派发）**：持有 mint 出的 token 的终端用户 agent
- **目标**：`entity://user/<workspace>/<username>` — token 的主体
- **Behavior**：`Ezagent.Behavior.UserTokens`（`:mint_token`、`:list_tokens`、`:revoke_token`）

## 步骤

### Mint

1. 在 LV `/admin/users/<username>/tokens`，点 "Mint token"。
2. 提供 label "ci-runner-2026"；提交。
3. 从一次性 flash 抓取明文 token（**永远不**在服务端明文存储）。
4. 把 token 存到 CLI 可访问位置（例如 `~/.ezagent/token`）。

### 使用

5. 另一个 shell：
   ```
   EZAGENT_TOKEN=<token> mix ezagent identity list_api_keys --user entity://user/system/admin
   ```
6. 验证 CLI 经分布式 Erlang RPC 命中**同一个** BEAM（按 Decision #130 — CLI 不可启动自己的 VM）。
7. 验证响应打印 masked api-key 列表。

### 列表 + 撤销

8. 在 LV `/admin/users/<username>/tokens`，观察 token 行 label "ci-runner-2026"，last-used 时间戳已更新。
9. 点 "Revoke"；确认。
10. 用同一 token 重跑步骤 5；验证 CLI 返回 `:unauthorized`。

## 预期结果

- mint 后 `user_tokens` 行存在；revoke 后删除（或标记 revoked）。
- 每一步写一行 `invocations`，`behavior=Ezagent.Behavior.UserTokens`。
- CLI `--user` URI 经 `EzagentCli.Dispatch.build_target_uri/5` 流转到与 LV mount 相同的 Invocation shape（CLI↔LV parity 见 `cli_lv_same_server_invariant_test.exs`）。

## 失败模式

- 已撤销 token：`:unauthorized`（步骤 10 验证）。
- Token 用于用户无 cap 的 workspace：`:cross_workspace_denied`。
- Token 用于用户无 cap 的 action：`:unauthorized`（PR #410 action-axis 后）。
- Token 撤销时飞行中的 CLI 调用：**当前不**会失效 — 见 Notes。

## 交叉引用

- 相关 PR：
  - PR #356 — User-Kind 操作切出到 `WorkspaceUserAdmin` Behavior（cap-shape 限制 workaround）
  - PR #386 — `mix esr` → `mix ezagent` 重命名
  - PR #410 — Capability action 轴
  - PR #438 — URI canonicalization（CLI 直传完整 `entity://...` URI）
- 相关 SPEC：
  - `2026-05-20-username-and-auth-design.md`
  - `2026-05-27-uri-canonicalization.md`
- 测试：
  - `apps/ezagent_cli/test/integration/cli_dispatch_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`
  - `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`
- Open bug / gap（todo "Codex PR #356 r1 HIGH/MED deferred"）：
  - **HIGH-1**：User-Kind action（`mint_token`、`set_password`、`grant_cap`）的 CLI 集成测试尚不存在。多数现有测试覆盖 Session-Kind，非 User-Kind。加并行 User-Kind 套件是下一个 gap。
  - **HIGH-2**：`UserTokens` Behavior 携带 `mint/list/revoke` — 三者同一 cap 主体。Action-axis（PR #410）让 cap struct 更细，但 cap-narrow grant 路径仅 admin 可用（todo "Entity-caps LV grant form needs action-selector dropdown"）。
  - **HIGH-4**：LV 侧 `EzagentPluginLiveview.UsersLive` 仍直接调 `Ezagent.Users.create/3`（绕过派发）。迁移到派发路径待办。

## 备注

- Token revoke + 飞行中 CLI session：当前行为是 "下次调用拒绝"，但进行中的流式派发不被中断。生产 GA 前考虑是否需改。
- `feedback_test_commands_before_suggesting`：本场景任何 CLI 示例应能用 `esr exec ezagent identity list_api_keys ...` 跑通后再交给操作员。
