# Scenario 26: Codex bridge UDS WS thread continuity (PR #441 regression)

**Category**: 14 — Codex bridge
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-28 (PR #441 Allen sign-off)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Bridge sidecar `app-server` running with UDS WS at `${EZAGENT_HOME}/sockets/codex-bridge.sock`
- A codex agent registered + connected (scenario 06)
- Codex TUI in tmux (so a session crash + relaunch is observable)

## Actors

- **Caller**: codex TUI + ezagent bridge sidecar
- **Target**: shared `thread_id` consistency across reconnects

## Steps

### Establish thread

1. Start codex TUI; observe bridge log connection establishment.
2. Send a message in `/admin/sessions/<session-uri>` to the codex agent.
3. Bridge JSON-RPC over UDS WS carries the turn; codex CLI returns; bridge writes back to the same WS.
4. Note the `thread_id` printed in bridge logs.

### Crash + reconnect (the PR #441 regression test)

5. Kill codex TUI (`Ctrl+C` twice in its tmux pane).
6. Restart codex TUI from the SAME `claude_config_dir`.
7. Codex CLI reconnects to the bridge's UDS WS; bridge recognizes the `thread_id`.
8. Send a new message in the session; verify codex responds with awareness of the previous turn (thread state continuity — PR #437).
9. Verify the UDS WS does NOT drop or reorder frames mid-handshake (PR #441 specific fix).

### Bridge-side reconnect

10. Kill the bridge sidecar; restart it.
11. Codex TUI reconnects (auto-retry); thread_id is renegotiated; conversation continues.

### Smoke scripts

12. Run `scripts/codex_app_server_thread_repro.py` — exercises the JSON-RPC handshake + thread reuse.
13. Run `scripts/codex_bridge_thread_smoke.py` — exercises a full chat turn over the bridge.

## Expected outcomes

- `thread_id` is consistent across TUI restart + bridge restart (PR #437 + #441).
- The UDS WS handles partial frames + reconnects without state loss.
- A complete `chat.send → codex turn → reply` cycle works after EVERY restart variant.

## Failure modes to test

- UDS socket file removed: bridge re-binds; codex TUI re-connects when socket re-appears.
- Permission issue on socket path: bridge cannot bind; operator-visible error in logs.
- Two codex TUIs connecting simultaneously: bridge assigns each its own `thread_id` (independent threads).
- A `chat.receive` arriving DURING handshake: PR #441 buffers + dispatches post-handshake.

## Cross-references

- Related PRs:
  - PR #437 — fix(codex): resume TUI on bridge thread
  - PR #439 — fix(codex): unblock operator e2e bootstrap
  - PR #441 — fix(codex): use app-server UDS websocket
- Related SPECs:
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
- Tests:
  - `apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_bridge_test.exs` (related cc-side; orthogonal to codex but exercises the bridge primitives)
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_e2e_test.exs`
- Smoke scripts (operator-driven):
  - `scripts/codex_app_server_thread_repro.py`
  - `scripts/codex_bridge_thread_smoke.py`

## Notes

- PR #441 was the canonical "frame handling on UDS WS" lesson. JSON-RPC over WS over UDS has 3 framing layers; getting them right took 2 iterations.
- Per `feedback_study_mature_projects_first`, the bridge design borrowed from established WebSocket app-server patterns (LiveView Phoenix.Socket, Hotwire stream sockets).
- The two smoke scripts are intentionally operator-runnable (no `mix test` needed) per `feedback_codex_companion_no_mix`.
