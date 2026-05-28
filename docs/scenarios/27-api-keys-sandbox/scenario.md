# Scenario 27: Per-agent api-keys + sandbox isolation

**Category**: 15 — Resource management
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-26 (PR #389 + #390; Bug A "config_dir atomic setup" deferred)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Two agents in the same workspace: cc agent A1 + curl agent A2
- A1's `claude_config_dir` is set to `/tmp/A1-claude-dir`
- A2 has an api-key for DeepSeek
- Admin logged in

## Actors

- **Caller**: admin + the agents themselves (during runtime)
- **Targets**:
  - cc agent's sandboxed `.claude/` directory
  - curl agent's api-key slice (post-PR #389 on Agent Kind)
- **Behaviors**: `Ezagent.Behavior.ApiKeys` (per PR #389) on Agent Kind

## Steps

### Sandbox isolation (cc)

1. From shell: `ls /tmp/A1-claude-dir/` — observe `.credentials.json`, `settings.json`, `mcp_servers.json`, `pids/`.
2. From `/admin/sessions/<sess>` send a message to A1; verify A1 responds using ITS config_dir's credentials (not the host's `~/.claude/`).
3. From the SAME phx, spawn a second cc agent A1b with `claude_config_dir = /tmp/A1b-claude-dir` (distinct).
4. Verify A1 and A1b operate independently — no cross-contamination of session history, MCP cache, or credentials.

### API-key isolation (curl)

5. From `/admin/agents/<A2-uri>/api-keys`, observe the masked DeepSeek key.
6. Try to read A2's api-key from a DIFFERENT agent's slice (via `Ezagent.Kind.Runtime.dispatch(<other_agent_uri>, :get_api_key, %{...})`): expect `:unauthorized` if caller lacks the cap.
7. Verify the api-key is NEVER logged or appears in any session message.

### Config_dir atomic setup (Bug A — DEFERRED)

8. Spawn a cc agent with a `claude_config_dir` that points to a NON-existent path.
9. Bug A: today, the cc Template Class creates the directory + writes config files NON-atomically. If the agent restarts mid-setup, partial state is left.
10. Intended fix: atomic create-and-populate (Phase 2 PR 8 per SPEC #445 §3.3 lifts these to `resource://` URIs).

## Expected outcomes

- Each cc agent's `.claude/` is isolated (sandbox).
- api-keys are per-agent (post-PR #389), readable only via the cap-gated `:get_api_key` action.
- No leaked keys in logs / audit / sessions.

## Failure modes to test

- `claude_config_dir` cannot be created (permission denied): cc agent fails to spawn; supervisor logs.
- api-key revoked while agent is mid-call: next dispatch fails; in-flight call uses the cached key.
- Two agents share a `claude_config_dir` (operator misconfiguration): they corrupt each other's session history + credentials. Mitigation: doc warning in `docs/runbook/cc-agent-config.md`; should be a config-time validation.

## Cross-references

- Related PRs:
  - PR #389 — refactor(api_keys): flip ApiKeys Behavior from User Kind to Agent Kind
  - PR #390 — PTY/Python phase state machine
  - PR #385 — orphan reapers
- Related SPECs:
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §3.3 — Resource pattern (Phase 2 PR 8 lifts config_dir + api-keys to `resource://` URIs)
- Tests:
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
- Open bugs / gaps (todo entries):
  - **Bug A**: config_dir atomic setup — deferred to Phase 2 SPEC #445 §3.3 Resource pattern.
  - **No invariant test for api-key non-leak** in logs / audit. Worth adding a property test.

## Notes

- Per `feedback_north_star_plugin_isolation`, Resources (config_dir, api-keys, bindings, cap-grants) are first-class URIs in the SPEC #445 design — but Phase 1 (PR #451) ships only the Router/Behavior/Kind primitives; Phase 2 will retrofit Resources.
- The sandbox isolation today is "by convention" (each agent's config_dir is a different path); a stricter enforcement (e.g. cgroups, namespaces) is not in scope.
