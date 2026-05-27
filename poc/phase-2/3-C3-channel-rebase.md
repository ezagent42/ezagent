# Phase 2.3 — EXP-C3 HTTP+SSE Customer Channel Rebased onto Phase 2

**Branch**: `poc/phase-2-C3-channel-rebased` (off `poc/phase-2-customer-service`)
**Profile**: `poc-phase2-c3`, port `10123`, runtime `ezagent_runtime_phase2_c3@127.0.0.1`
**Worktree**: `/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2-C3`

## Goal

Pull EXP-C3's HTTP+SSE customer chat controller onto the post-agent_bridge Phase 2 base (ezagent main f243a58, agent_bridge PRs #421-432 landed, `EzagentDomainChat.create_session/3` returning the new 3-tuple). Lock in the per-conversation session model (`session://default/<ws>/<conv-id>`), make workspace come from URL path, validate workspace existence, leave the synthetic reply intact as a Phase 2.4 swap-out point.

## What changed vs EXP-C3

| Surface | EXP-C3 | Phase 2.3 |
|---|---|---|
| Route | `POST /api/customer/:workspace/chat` | unchanged |
| Workspace source | URL path param (already) | URL path param + **validated** against `Ezagent.Workspace.Store.get_by_name/1`; 404 if absent |
| Session URI | `session://default/<workspace>/<conv_id>` (already) | unchanged — confirmed correct per verdict §2 |
| Session lifecycle | pre-created in setup.exs for known conv_ids only | auto-created on first sight via `EzagentDomainChat.create_session/3`; idempotent |
| `create_session` return shape | 2-tuple `{:ok, uri}` | 3-tuple `{:ok, uri, meta}` per ezagent#408 |
| `conv_id` missing | defaults to `"default"` | generates `Base.url_encode64(8 random bytes)` |
| Synthetic reply | inline | unchanged behavior, but boxed in `PHASE_2.4_TODO` comments + `spawn_synthetic_reply/2` clearly marked as the swap-out point |

## Cherry-pick

`git cherry-pick 9ff61b5` (EXP-C3 commit) applied clean — no conflicts on `router.ex` or anywhere else. The agent_bridge work between EXP-C3's base and Phase 2's base didn't touch the EXP-C3 files at all.

The integration work was forward-only: the controller had to adapt to the new `create_session/3` 3-tuple shape (`{:ok, session_uri, %{orchestrator_uri, orchestrator_status, ...}}`). EXP-C3 didn't call `create_session` from the controller — it relied on setup.exs pre-creating sessions, so the new code is the first time the controller hits the 3-tuple. Handled in `ensure_session/2`.

## Phase 2.4 swap-out point

**Single file, single function**: `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex`, `defp spawn_synthetic_reply/2`.

The function is bracketed by a `PHASE_2.4_TODO` comment block that documents the 3-step replacement:

1. `EzagentPluginCc.EagerBridge.ensure_bound!(cc_agent_uri, _opts)` — Phase 2.0's investigation confirmed bare `\r` writes to the PTY trigger the bridge handshake in ~500ms-1s; EagerBridge will wrap that in `write_input + poll BridgeRegistry`.
2. `Invocation.dispatch(chat.receive)` to the cc agent URI, message in args.
3. cc's reply lands on the same `esr:session:<session_uri>:events` topic the controller is already subscribed to; the SSE `stream_loop` relays it unchanged.

The `@agent_uri_str` module attribute is the only other thing that needs to flip — from the synthetic `entity://user/__synthetic__/echo_agent` to the real per-workspace cc URI resolved from session membership. The `terminal` check stays identical.

## Red-line greps (constraint #1)

Run from worktree root, per `docs/ezagent-migration/migration-design-constraints.md` §1 reviewer recipe:

```bash
grep -rnE '"(acme|cinnox)"' apps/*/lib/                              # tenant names
grep -rnE '"workspace://[a-z_-]+"' apps/*/lib/ | grep -v test         # workspace URI
grep -rnE '"entity://agent/[a-z_-]+/' apps/*/lib/ | grep -v test      # cc agent URI
grep -rnE '"session://[a-z_-]+/[a-z_-]+/' apps/*/lib/ | grep -v test  # session URI
```

Against the **two new files** in this PR (`customer_chat_controller.ex`, `router.ex` 4-line addition) the combined grep returns **empty** — no tenant-specific literals introduced.

The unchanged-from-main hits visible on a global scan are pre-existing and legitimate per constraint #1's "what's not tenant-specific" table:

- `workspace://system` (system workspace constant, not a tenant)
- `entity://agent/system/echo_default`, `entity://agent/system/cc_demo` — system-tier seeded demo agents
- `entity://agent/team-alpha/...` — placeholder strings in moduledoc examples / UI form placeholders
- `"acme"` literal in `onboarding_controller.ex` HTML placeholder attribute (UX hint, not business code)
- `session://default/system/main` — the system shared session, also a constant

None of those came from this PR.

## Acceptance test output

Server: `ezagent_runtime_phase2_c3@127.0.0.1` on port 10123. Setup script confirms `admin spawned | workspace acme created`. Sessions auto-created by the controller on first request.

### Single round-trip

```
$ curl -sN -X POST http://localhost:10123/api/customer/acme/chat \
    -H 'Content-Type: application/json' \
    -d '{"customer_id":"alice","text":"how long is warranty?","conv_id":"c1"}'

event: open
data: {"workspace":"acme","session_uri":"session://default/acme/c1","conv_id":"c1","customer_uri":"entity://user/acme/customer_alice","sent_msg_id":"78f068fd65e1c6aa"}

event: message
data: {"text":"Echo: how long is warranty?","terminal":true,"sender":"entity://user/__synthetic__/echo_agent","msg_id":"bf87cbae5fd29a2b"}

event: close
data: {"reason":"terminal"}
```

### Concurrent isolation

Two simultaneous requests on distinct `conv_id`s (c1/c2):

```
$ curl ... conv_id=c1 text=msg-A > /tmp/a.out &
$ curl ... conv_id=c2 text=msg-B > /tmp/b.out &
$ wait

=== /tmp/a.out ===                      === /tmp/b.out ===
event: open                              event: open
  ...session://default/acme/c1...          ...session://default/acme/c2...
event: message text="Echo: msg-A"        event: message text="Echo: msg-B"
event: close terminal                    event: close terminal

msg-A in a.out: 1   ✓ self
msg-B in a.out: 0   ✓ NO cross-pollination
msg-A in b.out: 0   ✓ NO cross-pollination
msg-B in b.out: 1   ✓ self
```

Per-conv session URI is doing its job — distinct sessions mean distinct PubSub topics mean zero leakage. This is the same finding EXP-C1/C2 *failed* and EXP-C3 *passed*; carrying it into Phase 2 deliberately.

### 404 on unknown workspace

```
$ curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    http://localhost:10123/api/customer/nonexistent/chat \
    -H 'Content-Type: application/json' -d '{"customer_id":"x","text":"y"}'
404
```

### Auto-generated conv_id when omitted

```
$ curl -sN -X POST http://localhost:10123/api/customer/acme/chat \
    -H 'Content-Type: application/json' -d '{"customer_id":"alice","text":"no conv id"}' | head -2

event: open
data: {"workspace":"acme","session_uri":"session://default/acme/rJw8IGEETy8","conv_id":"rJw8IGEETy8",...}
```

8-byte URL-safe base64 — sufficient entropy for an interactive turn, no DB lookup needed to mint.

## Subtleties around ezagent#408 (3-tuple `create_session`)

`EzagentDomainChat.create_session/3` now returns `{:ok, uri, %{orchestrator_uri, orchestrator_status, orchestrator_error}}`. `ensure_session/2` ignores the meta map for now — the controller doesn't need the orchestrator info because the synthetic reply path doesn't go through the orchestrator. **Phase 2.4 will care**: when EagerBridge dispatches to the cc agent, the orchestrator URI is the right place to look for the per-session cc agent's URI (it's what `Session.spawn_from_template` registers). The plumbing is already there — just unwrap one more field.

The `:already_started` adoption path is also still possible if a race lands two concurrent customer messages on the same fresh `conv_id`; the post-#409 global-lock serialization in `do_create_session` handles it server-side, and the controller treats either `{:ok, _, _}` or `{:error, {:already_started, _}}` as success.

## Files

- `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` — controller (333 lines; 227 from cherry-pick + 106 added/restructured)
- `apps/ezagent_web/lib/ezagent_web/router.ex` — single new `post` line in the `:api` scope (cherry-picked clean)
- `poc/phase-2/3-setup.exs` — runtime setup (admin + acme workspace; sessions no longer pre-created)
- `poc/phase-2/3-query_audit.exs` — audit query helper (carried from EXP-C3, unchanged)

## What's deliberately deferred to Phase 2.4

1. Real cc bridge reply (replace `spawn_synthetic_reply/2`).
2. Wiring `EagerBridge.ensure_bound!/2` (Phase 2.1's deliverable).
3. Resolving the **actual** cc agent URI from session membership instead of the synthetic constant — needs Phase 2's `cs_main` cc agent to be created at workspace-bootstrap time.
4. Auth on the customer-chat endpoint (bootstrap caps everywhere is fine for PoC; production needs per-tenant API keys, see verdict §6 open question).
