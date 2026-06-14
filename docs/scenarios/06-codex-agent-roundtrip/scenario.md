# Scenario 06: codex agent — spawn → bridge → reply

**Category**: 2 — Agent lifecycle
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-28 (PR #441 UDS WS fix verified by Allen)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- `codex` CLI on PATH (OpenAI codex TUI)
- `codex` is authenticated against your provider (OpenAI / Azure / etc.)
- Bridge sidecar `app-server` listening on UDS socket — usually started by `mix ezagent.bootstrap` post-PR #436
- Admin logged in

## Actors

- **Caller**: admin (`entity://system/user/admin`)
- **Target**: codex agent `entity://agent/system/my_codex` (Kind: `Ezagent.Entity.CodexAgent`, via PR #436)
- **External systems**: codex TUI binary; bridge_sidecar JSON-RPC over UDS WebSocket

## Steps

1. Create codex.agent template via `/admin/templates` or iex (analogous to scenario 05 cc.agent).
2. Spawn the codex agent.
3. Watch the bridge sidecar log:
   - Codex TUI connects to UDS WS at `${EZAGENT_HOME}/sockets/codex-bridge.sock`
   - JSON-RPC handshake establishes `thread_id`
4. From `/admin/sessions/<session-uri>`, send a message: "write a haiku about Erlang".
5. Verify routing:
   - `chat.send` → Session fan-out
   - codex agent `chat.receive` → bridge writes a turn to the UDS WS
   - codex CLI ingests + LLM responds
   - bridge writes the response back via the same UDS WS using the SAME `thread_id`
   - codex agent dispatches `chat.send` (the reply)
6. Admin sees the reply in the session LV.

## Expected outcomes

- TUI + bridge share `thread_id` (PR #437 fix). Verifiable by reading codex's bridge thread log.
- `invocations` rows for spawn + chat.send + chat.receive + chat.send (reply).
- The UDS WS does not drop frames or reorder turns (PR #441 fix).

## Failure modes to test

- Bridge sidecar not running: codex agent spawn fails with `:bridge_unavailable`.
- Codex CLI exits mid-turn: bridge detects EOF; codex agent transitions to `:degraded`; supervisor restarts with backoff.
- Stale `thread_id` (codex TUI restarted but bridge thinks it has a thread): smoke script `codex_app_server_thread_repro.py` is the canonical regression.
- LLM API key invalid: codex CLI errors; bridge surfaces the error to the session as a chat message.

## Cross-references

- Related PRs:
  - PR #421 — SPEC: AgentBridge domain extraction (PR-A)
  - PR #424 — PR-B TokenStore + Registry
  - PR #428 — PR-C Socket + Channel
  - PR #429 — PR-D route Agent chat through BridgeAdapter
  - PR #432 — PR-E remove domain_instance_message cc dependency
  - PR #425 — PR-F detect PTY lifecycle by behavior
  - PR #436 — PR-G add codex agent plugin
  - PR #437 — TUI bridge thread resume
  - PR #439 — operator e2e bootstrap unblock
  - PR #441 — fix: app-server UDS WebSocket frame handling
- Related SPECs:
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
  - `docs/agent-bridge-pr-b-tokenstore-registry.md` through `docs/agent-bridge-pr-g-codex-plugin.md`
- Tests:
  - `apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_domain_agent_bridge/test/...` (PR-A scaffolding)
- Smoke scripts:
  - `scripts/codex_app_server_thread_repro.py` — bridge UDS WS regression
  - `scripts/codex_bridge_thread_smoke.py` — thread continuity

## Notes

- The bridge architecture is shared with cc (`Ezagent.Domain.AgentBridge`), making cc-codex a parallel-flavor pair.
- Per `feedback_north_star_plugin_isolation`, both cc and codex must consume the bridge as a black box; the bridge does not embed cc-specific or codex-specific logic.
- The ⚠️ status is due to no automated e2e against the real codex binary today (operator-driven via `codex_app_server_thread_repro.py`). (The former scenario 04 "cross-workspace delegated token" — once floated as a codex-v2 prerequisite — was removed 2026-06-14 as YAGNI; if codex-v2 ever needs cross-workspace acting-as dispatch it starts as a fresh SPEC.)
