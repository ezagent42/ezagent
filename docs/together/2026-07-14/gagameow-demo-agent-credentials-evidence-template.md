# demo agent 凭证验收模板（脱敏）

> 本模板只记录状态与正式产品调用证据。禁止填写 credential 内容、token、hash、
> 环境变量、完整 config path、shell trace 或认证码。

## 元数据

- `operator`：`<github/feishu identity>`
- `checked_at`：`<ISO-8601 GMT+8>`
- `deployment`：`<canary/stable>`
- `deployment_sha`：`<sha>`
- `prerequisite_1375`：`merged=<true|false>` / `deployed=<true|false>`
- `deadline_status`：`<on_time|late|deferred|out_of_scope>`

## 1. Live inventory

权威来源：已认证 World → Identities → Agent detail。不得以仓库 grep 结果代替
部署现场清单。

| Agent URI | Flavor | Before status | Checked at | Owner/creator verified |
|---|---|---|---|---|
| `<entity://.../agent/...>` | `<cc/codex/...>` | `<missing/expired/authenticated/unknown>` | `<time>` | `<yes/no>` |

只列 credential-bearing flavors。`test-zyli-cc-1` 必须出现，除非部署现场已不存在，
此时记录 detail 的 `not_found` 结果，不猜测替代 URI。

## 2. 授权与隐私前置检查

- [ ] 操作者是目标 Agent 的创建者，或明确记录 admin/operator 授权。
- [ ] 目标 Agent detail 显示创建者持有该实例的 Manage authority。
- [ ] 非授权测试账号无法读取目标 PTY buffer。
- [ ] 非授权测试账号无法订阅目标 PTY live chunks。
- [ ] 证据中不出现 `/data/...`、`CLAUDE_CONFIG_DIR` 或 credential source path。

若 #1375 尚未合入并部署，本节直接记为 `BLOCKED_BY_1375`，不得用 admin-only
路径冒充 creator flow。

## 3. Provision action

首选正式路径：

```text
World Agent Detail → Terminal → claude /login
```

记录：

- `method`：`creator_terminal_login`
- `started_at`：`<time>`
- `completed_at`：`<time>`
- `result`：`<completed|cancelled|blocked>`

禁止记录登录 URL、认证码、token 或终端中出现的 secret。

仅在 lead 明确批准且 credential source 合法时，才可记录：

```text
method=demo_seed_cc_sandbox
target_dir_source=current_agent_detail
force=false
```

不得记录 `--credentials-file` 或 `--sandbox-dir` 的真实值。

## 4. After status

| Agent URI | After status | Checked at | Status surface |
|---|---|---|---|
| `<entity://.../agent/...>` | `authenticated` | `<time>` | `World Agent detail` |

文件存在不是验收；必须由 normalized credential status 返回 `authenticated`。

## 5. 正式产品调用

- `entry_surface`：`<session/hello/kanban formal entry>`
- `target_agent_uri`：`<URI>`
- `request_nonce`：`<non-secret nonce>`
- `requested_at`：`<time>`
- `responded_at`：`<time>`
- `result`：`<success|failure>`

脱敏 transcript：

```text
USER: <non-secret request containing nonce>
AGENT: <short response proving the target handled the request>
```

## 6. Restart persistence

- `restart_surface`：`<sanctioned product/operator action>`
- `restart_at`：`<time>`
- `post_restart_status`：`authenticated`
- `post_restart_call_result`：`success`
- `post_restart_transcript_ref`：`<redacted evidence ref>`

禁止使用 raw RPC、arbitrary eval、直接 DB setter 或裸进程操作完成重启。

## 7. DoD reconciliation

- [ ] Live credential-bearing Agent 清单完整。
- [ ] `test-zyli-cc-1` 已核对或有 `not_found` 实证。
- [ ] Before status 有证据。
- [ ] 创建者正式 Terminal `/login` 可用且隐私门禁成立。
- [ ] After status 为 `authenticated`。
- [ ] 正式产品入口调用成功。
- [ ] 重启后 status 与调用仍成功。
- [ ] 文档无 credential 正文、hash、token、env dump、shell trace、认证码或敏感路径。

## 8. 提交前脱敏扫描

```bash
rg -n "Bearer|Authorization:|credentials.json|CLAUDE_CONFIG_DIR|/data/|sha256|token=|code=" \
  docs/together/2026-07-14/gagameow-demo-agent-credentials-evidence.md
```

预期：无秘密值；若命中字段说明，只允许保留本模板级别的禁止性文字。
