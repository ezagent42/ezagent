# 指南：给 agent 供给凭证（operator 车道）

> 凭证供给面的操作指引（任务 B，handoff
> `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §4）。socialware
> 安装因缺凭证 skip 角色槽时，operator 按本文供源并补物化。

## 角色为什么会被 skip

自动物化车道（socialware 角色槽）拒绝创建无法认证的 agent
（`Ezagent.Agent.CredentialPrecondition`，链 C）：槽位被**响亮地** skip ——
session 的 `unfilled_agent_role_slots` 落 durable 行（world UI 渲染）、
`Logger.error`、telemetry `[:ezagent, :socialware, :definition_agents, :skipped]`。

skip 的 `reason` 告诉你走哪条供给车道：

| reason | 含义 | 修法车道 |
|---|---|---|
| `:missing_credentials` | 文件型凭证 flavor（如 `cc` 的 `.credentials.json`）对该 installer 无源可解 | 下方 §1 或 §2 |
| `:missing_provider_credential` | 环境型 flavor 的 provider key 不可用（今日 deepseek；cc-custom profiles） | 在部署环境设 provider key |
| `:unavailable` | 其他失败——**配凭证修不了** | 看 server log / telemetry 的 raw reason |

## 1. 用户默认源（owner × workspace × flavor）

把一个已有凭证的 agent 认养为该用户的默认源：

```bash
mix ezagent.credential.adopt <owner-uri> --flavor cc [--source <agent-uri>]
```

该用户之后的安装优先解析这个 pointer（`Ezagent.Credential.UserDefaultSource`）。

## 2. workspace 共享源（workspace × flavor）

workspace 管理员经 cap-checked 生产写入器
（`Ezagent.ActionSet.WorkspaceSharedCredentialSource`，注册在 Workspace Kind，
CLI 树自动派生）绑定共享 service-account 源：

```bash
mix ezagent workspace set_workspace_shared_credential_source \
  --workspace <workspace-uri> --flavor cc --source-uri <agent-uri>
```

校验 fail-closed：源必须存在（snapshot）、同 workspace、同 flavor。非 admin
installer 在自己没有默认源时解析这一层（`用户默认 → workspace 共享 → NONE`）。

> 宿主 operator 自己的 Claude 登录**永不**流向 co-tenant 造出的 agent（#161）
> —— skip 正是这条规则的表达，不是 bug。

## 3. 补物化被 skip 的角色

供源**不会**追溯回填既有会话——skip 行是安装时刻快照。重跑（幂等的）安装管道：

```bash
mix ezagent.session.reinstall_socialware <session-uri>
```

凭证已可解析的角色加入会话；其 skip 行清掉（重跑用新 summary 全量重写
`unfilled_agent_role_slots`）。已加入的角色被跳过（不重复建员）。凭证仍缺的
角色继续响亮地 skip——补物化是显式 operator 动作，不是自动重试环。

## 验证

集成覆盖：
`apps/ezagent_plugin_cc/test/integration/socialware_credential_rematerialize_test.exs`
（skip → 供源 → 重装 → 成员加入 + 行清空 → 幂等重跑）、
`.../socialware_credential_skip_telemetry_test.exs`（telemetry）、
`apps/ezagent_domain_session/test/.../unfilled_role_slot_reason_test.exs`
（三类 reason 区分）。
