# Scenario 05: cc agent — spawn → first-run → message → reply

**Category**: 2 — Agent lifecycle
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-22 (V1 sign-off + ongoing PR regression)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- `claude` CLI on PATH (real Anthropic TUI) — `claude --version` succeeds
- `uv` on PATH (runs the MCP bridge with PEP-723 inline metadata)
- Authenticated `claude` — see `docs/runbook/cc-agent-e2e.md` for credential-copy
- Admin logged in
- Sandbox cred seeded: `mix ezagent.demo.seed_cc_sandbox --name my-cc-agent --seed-template my-cc-agent`

## Actors

- **Caller**: admin (`entity://user/system/admin`)
- **Target**: cc agent `entity://agent/system/my_cc_agent` (Kind: `Ezagent.Entity.CcAgent`)
- **External systems**: spawned `claude` TUI binary; cc-bridge Phoenix Channel at `ws://127.0.0.1:10042/cc_socket/websocket`

## Steps

### Spawn

1. In `/admin/templates`, click "Create cc.agent template"; fill working_directory, claude_config_dir, default_caps; submit.
2. Navigate to `/admin/agents` (TODO — currently 404, use iex instead — see scenario 29).
3. iex equivalent:
   ```elixir
   {:ok, _} = Ezagent.Workspace.add_template(
     URI.new!("workspace://system"),
     "my-cc-agent",
     %{"class" => "cc.agent",
       "agent_uri" => "entity://agent/system/my_cc_agent",
       "cwd" => "/tmp/my-cc-cwd",
       "claude_config_dir" => "/tmp/my-cc-claude-dir"})
   ```
4. The cc Template Class spawns the agent; the PTY launches `claude` with `CLAUDE_CONFIG_DIR=/tmp/my-cc-claude-dir`.

### First-run

5. Watch `/admin/agents/<url-encoded-agent-uri>/terminal` (LV PTY mirror).
6. First-run shows a TUI theme picker; ezagent PTY handler types `<Enter>` blindly (PR #390 state machine: boot → first-run → ready).
7. Confirm the LV terminal shows the post-theme `claude` REPL prompt.

### Message + reply

8. In `/admin/sessions/<session-uri>`, send a message: "say hello in one sentence".
9. The chain:
   - admin → `chat.send` → Session fan-out
   - Agent `chat.receive` → `BridgeRegistry.lookup` (live claude joined `/cc_socket`)
   - `to_claude` push on Phoenix Channel
   - `notifications/claude/channel` on claude's MCP stdio
   - claude's LLM reads the channel + calls the `reply` MCP tool
   - `reply` event back over WS → `chat.send` dispatch from agent
   - Session events stream gets the reply
10. Admin sees the reply in `/admin/sessions/<session-uri>` (LV).

### Restart

11. From iex: `Ezagent.Kind.Runtime.dispatch(<cc_agent_uri>, :restart, %{})`.
12. The agent supervisor restarts; PTY relaunches; orphan reap (PR #385 + #388) ensures the old `claude` process is killed via pid-file lookup.
13. Verify the post-restart agent picks up the same `claude_config_dir` + workspace state.

## Expected outcomes

- `invocations` rows for: spawn, chat.send (admin), chat.receive (agent), chat.send (agent reply).
- `kind_snapshots` row for the cc agent updated `:on_change` (or `:on_terminate`, per Decision #115).
- PTY pid-file at `<config_dir>/pids/claude.pid` exists during ready state, cleaned on terminate.
- `/admin/sessions/<session-uri>` LV shows admin's message + agent's reply.

## Failure modes to test

- `claude` not on PATH: spawn fails with `:enoent`; supervisor logs + restarts capped at 3 attempts.
- Stale credentials (sandbox `.credentials.json` missing): claude prompts for login + PTY hangs at the prompt (this is the "first-run before credential-copy" failure mode).
- Bridge socket disconnect mid-reply: cc agent's MCP server detects `notifications/claude/channel` socket close + re-registers via `BridgeRegistry.register/2`.
- LLM API rate-limit: claude returns an error tool response; the reply MCP tool emits `chat.send` with the error text; admin sees the error in session.

## Cross-references

- Related PRs:
  - PR #385 — pty-orphan-restart fix (post_init hook + orphan reapers)
  - PR #388 — pid-file replaces `ps`-walk for orphan discovery
  - PR #389 — api-keys flipped from User to Agent Kind
  - PR #390 — PTY/Python phase state machine + LV visibility
  - PR #424 — agent_bridge PR-B: TokenStore + Registry promoted out of cc plugin
  - PR #428 — agent_bridge PR-C: Socket + Channel promoted
  - PR #432 — agent_bridge PR-E: removed domain_instance_message cc dependency
  - PR #436 — agent_bridge PR-G: added codex plugin (orthogonal cc validation point)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
- Tests:
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — deterministic CI e2e (FakeCcAgent stand-in)
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/real_claude_hotfixes_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/dev_channels_confirm_test.exs`
- Evidence + runbook:
  - `docs/runbook/cc-agent-e2e.md` (Test B — operator-driven real-claude smoke)
  - `docs/runbook/cc-agent-config.md` — operator config knobs

## Notes

- The deterministic CI e2e uses `FakeCcAgent` to stay within the umbrella test wall-clock budget; the runbook covers the real-binary smoke.
- Per `feedback_open_terminal_first_when_debugging`, any cc-agent debug session opens `/admin/agents/<uri>/terminal` FIRST.
- Bug A (config_dir atomic setup) — see scenario 27 — is the open gap on first-run idempotency.
