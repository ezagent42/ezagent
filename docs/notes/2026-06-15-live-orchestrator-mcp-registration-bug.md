# Bug: live cc orchestrator can't register its MCP bridge on a fresh stack (E2E finding, 2026-06-15)

**Severity:** high — on a fresh stack the cc orchestrator never reaches readiness, so
`create_session` always rolls back → the admin dashboard (`AdminLive.ensure_main_session`)
+ all agent functionality are blocked. Found via the LIVE E2E on the disposable docker
stack (`ezagent-disp:10044`, built from `main@09277952` = 9c + PR #723).

**NOT masked by the deterministic suite:** the gate tests signal orchestrator readiness
via `register_orchestrator_mcp_context` directly (test-mode), bypassing the real
claude→MCP→`McpChannel.join` path — so this only shows up with a live claude orchestrator.

## Precise trace

1. `create_session` step 5 `Session.ensure_orchestrator/3` spawns the cc orchestrator
   and POLLS `Orchestrator.LiveJoinRegistry.joined?/1` on a 90s deadline
   (`session/orchestrator.ex` `gate_orchestrator_readiness`). `joined?` is marked by
   `McpChannel.join/3`.
2. The orchestrator's claude starts; PR #723's auto-prompt correctly answers BOTH startup
   dialogs (trust-folder + **MCP-trust** — confirmed: `auto-prompt mcp_trust_dialog matched
   — sending "\r"`), and the bridge channel registers (`JOINED agent_bridge:cc:… in 75µs`).
3. claude's MCP server (`esr-bridge`) connects + authenticates
   (`CONNECTED TO Ezagent.Orchestrator.McpSocket`), then tries to join
   `Ezagent.Orchestrator.McpChannel`.
4. **The join is rejected `:orchestrator_not_registered` (fail-closed), repeatedly** —
   so `LiveJoinRegistry.mark_joined` never runs → `joined?` stays false → 90s timeout →
   `{:orchestrator_ensure_failed, {:orchestrator_not_ready_within, 90000}}` → full
   create_session rollback (revokes caps, kills PTY+Kind, deletes session).

## Root cause

`McpChannel.join` → `McpServer.ensure_registered/1` → (ETS miss) `rebuild_from_durable/1`
→ `resolve_session/1` → **`find_session_for_orchestrator/2` returns nil** (mcp_server.ex:212).
That function scans `KindSnapshot.list_in_workspace(ws)` for `kind_type == "session"`
snapshots whose stored working-copy `:orchestrator_uri` (via `stored_orchestrator_uri/1`
→ `load_chat_slice/1` reading `%{session: chat_slice}` → `orchestrator_working_copy/1`
→ `Map.get(wc, :orchestrator_uri)`) equals the connecting orchestrator URI.

At MCP-connect time (during the create's readiness wait) **no persisted session snapshot
has a working-copy `:orchestrator_uri` matching the orchestrator** — so registration is
skipped and the join fails. Likely cause (to confirm): an ordering/slice-resolution issue
post-基座化 — the session working-copy's `:orchestrator_uri` is written to the snapshot
AFTER claude connects (or the slice-key/working-copy read no longer resolves it post
chat→session rename). Either way the register-on-MCP-connect path can't find the session.

Chicken-and-egg shape: readiness (step 5) needs the MCP join, the join needs the durable
session→orchestrator binding, and that binding isn't observable in the snapshot at
connect-time during the same create.

## Fix directions (to verify on the disposable stack — needs live iteration)

- Ensure the session working-copy `:orchestrator_uri` is **persisted to the session
  snapshot before** the orchestrator's claude can connect (i.e. write the binding inside
  `ensure_orchestrator`/`finalize_spawned_orchestrator` BEFORE the readiness poll begins),
  so `find_session_for_orchestrator` resolves on the first MCP-connect.
- OR register the orchestrator in `McpRegistry` at spawn/finalize time (not only at step-7
  `register_orchestrator_mcp_context`), so `McpChannel.join` is accepted during the wait.
- Verify `load_chat_slice/1`'s `%{session: chat_slice}` decode + `orchestrator_working_copy/1`
  still resolve post chat→session rename (9b) — a stale key would also produce this.

## Relation to existing tasks

- #58 (cc-orchestrator default-SessionTemplate coupling — `create_session(default)` edge):
  same area; this is the live manifestation.
- #57 (relocate `OrchestratorReadinessPort` im→core): same readiness subsystem.
- PR #723 (merged) fixed the upstream MCP-trust dialog; this is the next blocker behind it.

## Repro

Fresh disposable stack (`docker/docker-compose.disp.yml`, main ≥ 09277952) → set admin
password → log in → load `/admin/sessions` (or `/sessions`) → watch logs:
`McpChannel: … not a registered orchestrator (:orchestrator_not_registered)` looping, then
`ensure_orchestrator: … did NOT join its live MCP bridge within 90000ms`.
