# AgentBridge PR-F：按 PTY 行为检测 Agent 生命周期

父 SPEC：`docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md` §3.6、§4.1、§5 PR-F。

## 变更

`Ezagent.Domain.Agent.lifecycle_status/1` 不再针对 `"cc"`、`"echo"`、`"curl"` 或未知 flavor 字符串写分支。只要共享的 Agent Kind 已存活，Domain.Agent 就检查同一个 agent URI 是否存在 live 的 `Ezagent.Domain.Pty`。

- 如果 PTY sidecar 存活，返回 `:alive`，并带上 `Ezagent.Domain.Pty.status/1` 的 detail。
- 如果没有 PTY sidecar，仍返回 `:alive`，detail 为空 map。
- flavor 仍从 URI name prefix 推导，但只用于展示。

## 原因

Codex 和未来 agent flavor 必须复用 `Ezagent.Entity.Agent` 与 `Ezagent.Domain.Pty`，不能继续在 domain 代码里增加 flavor 专用分支。PTY 支持现在按行为检测：任何带 live Domain.Pty sidecar 的 agent 都能获得 terminal 生命周期 detail。

## 验证

Focused test：

```sh
mix test apps/ezagent_domain_chat/test/ezagent/domain/agent_test.exs
```

结果：7 tests, 0 failures。

