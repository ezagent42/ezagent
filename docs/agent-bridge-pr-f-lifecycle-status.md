# AgentBridge PR-F: Flavor-Agnostic PTY Lifecycle Detection

Parent SPEC: `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md` §3.6, §4.1, §5 PR-F.

## Change

`Ezagent.Domain.Agent.lifecycle_status/1` no longer special-cases `"cc"`, `"echo"`, `"curl"`, or unknown flavor strings. Once the shared Agent Kind is alive, Domain.Agent checks whether `Ezagent.Domain.Pty.alive?/1` is true for the same agent URI.

- If a PTY sidecar is alive, status is `:alive` with `Ezagent.Domain.Pty.status/1` detail.
- If no PTY sidecar is alive, status is still `:alive` with empty detail.
- Flavor is still derived from the URI name prefix for display only.

## Why

Codex and future agent flavors must reuse `Ezagent.Entity.Agent` plus `Ezagent.Domain.Pty` without adding new flavor-specific branches in domain code. PTY support is now detected by behavior: any agent with a live Domain.Pty sidecar gets terminal lifecycle detail.

## Verification

Focused test:

```sh
mix test apps/ezagent_domain_instance_message/test/ezagent/domain/agent_test.exs
```

Result: 7 tests, 0 failures.

