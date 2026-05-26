# EXP-C3 — Web customer channel via HTTP+SSE

## Variant Summary

A single `POST /api/customer/:workspace/chat` endpoint that opens a
`text/event-stream` response, dispatches `chat.send` into the addressed
session, subscribes to the session events topic, and streams every
subsequent agent-side message back as SSE events until a terminal reply,
client disconnect, or 30 s timeout. Stateless per-request — each
customer turn is a fresh POST, reconnection is just another POST.

## Implementation

- **Files touched** (new code only — no ezagent core modified):
  - `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` — 227 LOC
  - `apps/ezagent_web/lib/ezagent_web/router.ex` — +4 LOC (route)
  - `poc/exp-C3/setup.exs` — 92 LOC (RPC bootstrap, workspace + 2 sessions)
  - `poc/exp-C3/query_audit.exs` — 49 LOC (RPC audit-row probe)
- **Controller module + route**:
  `EzagentWeb.CustomerChatController.chat/2`, mounted under the
  existing `/api` scope: `post "/customer/:workspace/chat", CustomerChatController, :chat`.
- **SSE event format chosen** (raw bytes, exactly what the wire saw):

  ```
  event: open
  data: {"workspace":"acme","session_uri":"session://default/acme/c1","conv_id":"c1","customer_uri":"entity://user/acme/customer_alice","sent_msg_id":"f9da2e..."}

  event: message
  data: {"text":"Echo: warranty?","terminal":true,"sender":"entity://user/__synthetic__/echo_agent","msg_id":"9c1e..."}

  event: close
  data: {"reason":"terminal"}
  ```

  Three named SSE events: `open` (handshake / echo back to client),
  `message` (each `{:chat_message, _, %Ezagent.Message{}}` not from
  the customer themselves), `close` (terminal-reason envelope —
  `terminal` | `timeout`).
- **Synthetic customer URI scheme**:
  `entity://user/<workspace>/customer_<customer_id>` — re-uses the
  `entity://user/...` scheme so audit/PubSub/Routing treat the
  customer as a first-class entity URI. No `entity://user` Kind is
  ever spawned for them; they exist only as a sender identifier in
  `Ezagent.Message`.
- **conv_id semantics**: maps 1:1 to a session URI
  `session://default/<workspace>/<conv_id>`. setup.exs pre-creates
  `c1` and `c2`. A real deployment would either pre-create
  per-customer sessions or lazily call `EzagentDomainChat.create_session`
  inside the controller — both work, EXP-C3 picked the simpler
  "session must exist" contract.
- **Cap model used for dispatch**: admin URI + `system://bootstrap`
  cap bundle, identical to Phase 0. EXP-C3 explicitly does NOT try to
  solve "what cap does an anonymous third-party-IM customer hold" —
  that's CapBAC design work, not transport-shape work.
- **Termination strategy**: the receive loop closes on whichever of
  three things happens first — (a) a message whose `sender ==
  agent_uri_str` (the synthetic agent), in which case we emit a
  `close` event then return the conn; (b) absolute deadline
  (`@reply_timeout_ms = 30_000`); (c) `Plug.Conn.chunk/2` returns
  `{:error, :closed}` (client hung up). No GenServer, no monitor —
  the receive loop is just a tail call on the controller process.
- **Total new code**: ~280 LOC product + 141 LOC PoC harness ≈ ~420 LOC.

### The agent-reply path is synthetic

Per Phase 0 FINDINGS (cc bridge handshake gap), EXP-C3 does NOT route
to a real cc agent. After the controller dispatches `chat.send`, it
spawns a 500 ms `Task` that calls
`Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, {:chat_message,
session_uri, %Ezagent.Message{sender: agent_uri, body: %{text: "Echo:
" <> customer_text}}})`. The synthetic reply bypasses
`MessageStore.write` — it is NOT persisted, only broadcast. This is
fine for validating the SSE shape but is the explicit "agent half" of
the integration we're punting on. The synthetic agent URI is the
fixed string `entity://user/__synthetic__/echo_agent` so the receive
loop has a known sentinel to recognise as terminal.

## Acceptance

- **Single-customer round-trip works (curl)**: yes.

  ```
  $ curl -N -X POST http://localhost:10203/api/customer/acme/chat \
      -H 'Content-Type: application/json' \
      -d '{"customer_id":"alice","text":"warranty?","conv_id":"c1"}'
  event: open
  data: {"workspace":"acme","session_uri":"session://default/acme/c1","conv_id":"c1","customer_uri":"entity://user/acme/customer_alice","sent_msg_id":"901be5b551a1138a"}

  event: message
  data: {"text":"Echo: warranty?","terminal":true,"sender":"entity://user/__synthetic__/echo_agent","msg_id":"44aa191f1645a8b3"}

  event: close
  data: {"reason":"terminal"}
  ```

- **Audit row in invocations table**: yes. `query_audit.exs` returns:

  ```
  %{caller: "entity://user/system/admin",
    target: "session://default/acme/c1?action=chat.send",
    action: "send", authz: "granted",
    workspace_uri: "workspace://system", ...}
  ```

  Two `granted` rows per turn (dispatch + downstream re-entry through
  Resolver). `workspace_uri = workspace://system` because the
  invocation is initiated by the admin User, not by an
  `entity://*/acme/*` caller — `Capability.workspace_of/1` resolves
  off the caller. That's a wart of dispatching as admin rather than
  as a per-customer URI, but it's a CapBAC question, not an SSE one.

- **Concurrent 2-customer test result**: pass.

  Test:
  ```bash
  (curl -N -s -X POST .../chat -d '{"customer_id":"alice","text":"alice-msg","conv_id":"c1"}' > alice.sse) &
  (curl -N -s -X POST .../chat -d '{"customer_id":"bob",  "text":"bob-msg",  "conv_id":"c2"}' > bob.sse) &
  wait
  ```
  Verification:
  ```
  $ grep -c "bob"            alice.sse  ->  0
  $ grep -c "alice"          bob.sse    ->  0
  $ grep -c "Echo: alice-msg" alice.sse ->  1
  $ grep -c "Echo: bob-msg"   bob.sse   ->  1
  ```
  Cross-contamination zero; each stream contains exactly its own
  synthetic reply. Topic-per-session subscription model is doing the
  isolation work for us — there is no per-controller filtering logic
  needed beyond the "skip the customer's own echo" guard.

## Subjective Evaluation

### ezagent-nativeness (score: 4/5)

Pretty native. The controller leans on three primitives the rest of
ezagent already uses heavily:

1. `Ezagent.Invocation.dispatch/1` with the standard
   `caller/caps/reply` ctx, exactly mirroring how the LV chat panel
   sends messages.
2. `EzagentDomainChat.Behavior.Chat.session_events_topic/1` — the same
   PubSub topic the in-process LV chat stream subscribes to.
3. `Ezagent.Message.new/2` for the payload — same struct everywhere.

The non-native bit is the SSE framing itself (`Plug.Conn.chunk/2` +
`text/event-stream` content type). Phoenix has first-class
`Phoenix.Channel` for streaming, but Channel requires a WebSocket
client; HTTP+SSE is intentionally a different transport with
different operational characteristics. Losing one point because
no existing ezagent code does SSE — there is no established pattern
to copy, so the framing decisions (event names, JSON shape, close
semantics) are all ours. That is exactly the question the PoC
exists to answer, not a code smell.

### Stateless-ness rating

**Genuinely stateless.** The only state on the server between
requests is what `chat.send` itself writes (audit row in
`invocations`, persisted message in `messages`, downstream PubSub
fan-out). The controller process holds:

- a Phoenix.PubSub subscription, scoped to the connection lifetime
- a `Plug.Conn` with a chunked response open
- a 30 s deadline timer (just `System.monotonic_time` arithmetic, no
  GenServer)

Drop the connection -> controller process exits -> subscription
auto-released. Reconnect = brand new POST = brand new
subscription. There is no per-customer ETS row, no GenServer
per-conversation, no socket session token. If a client retries with
the same `conv_id`, the request lands cleanly on the same session
URI and is indistinguishable from a fresh first request —
because there is literally nothing to reconcile.

The one fudge: the session URI for a `conv_id` must already exist
(setup.exs pre-creates `c1` and `c2`). Lazy session creation in
the controller would remove even that — trivial to add, deferred
because it muddies the LOC count for the comparison.

### Comparison vs AutoService's General Bot SSE

AutoService's General Bot API (spec
`2026-04-27-general-bot-sse-http-api-design.md`) is structurally
very similar — `POST /chat/{tenant_id}`, SSE response, per-tenant
Bearer-token auth, message-then-terminal event sequence. The
shape ports cleanly. Three places AutoService's design would need
to adjust to fit ezagent's contract:

1. **Auth surface**: AutoService keeps SHA-256 hashed Bearer keys
   at `.autoservice/sandbox/<tid>/api_keys.json` with its own
   `issue_general_bot_key.py` mint script. ezagent already has
   `entity://agent/<ws>/.../api-keys` (the AgentApiKeysLive page
   added 2026-05-26). The cleaner ezagent shape is one API key per
   per-tenant *bridge agent* (e.g.
   `entity://agent/acme/cinnox_bridge`), with the key resolving to
   that agent's caps via the existing identity machinery. Then the
   controller's "anonymous customer admin-dispatch" hack
   disappears — caller becomes the bridge agent, caps come from
   its existing grant, audit attributes correctly to the
   integration. EXP-C3 punted on this; AutoService's
   port-it-as-is would forfeit the audit-attribution win.

2. **Conversation identity**: AutoService threads
   `(tenant_id, customer_id, conv_id)` through its session/CRM
   layer separately from the agent's reply path. ezagent has
   exactly one identifier — the session URI. The mapping
   `(workspace, conv_id) -> session://default/<ws>/<conv_id>` we
   used is the natural compression but takes one design
   decision: does each `conv_id` get its own session forever, or
   is `conv_id` more like a per-turn correlation ID and one
   session per customer? Phase 0 used `session://default/acme/main`
   (singleton per workspace). For inbound integrations, per-customer
   sessions are probably right — customers don't share state.

3. **Terminal signal**: AutoService streams deltas
   (`event: delta`, `event: terminal`) — its pipeline owns the
   render loop and *knows* when it's done. ezagent's
   `chat.receive` is broadcast-driven; there is no built-in
   "agent is done streaming this turn" marker. EXP-C3 used a
   sender-equals-agent-URI sentinel, which works for single-reply
   echo but is brittle for real cc agents (which may emit
   side-channel directives, KB probes, etc.). The right
   long-term answer is probably a per-turn message-metadata flag
   (`terminal: true`) at the chat.receive layer; AutoService's
   shape lets us crib the flag name.

### Production readiness gap

- No auth / rate-limiting on `/api/customer/*/chat`. Currently
  accepts any JSON body; trivially DOS-able. Need Bearer key
  scheme (per item #1 above).
- Synthetic agent reply is hardcoded — real cc bridge integration
  is the Phase 0.5 work item.
- `conv_id -> session_uri` mapping requires session to pre-exist.
  Lazy `create_session` in the controller is ~3 LOC but needs
  caps for the customer (item #1 again).
- Customer URI is constructed but never validated against any
  allow-list, so the audit log records arbitrary
  `entity://user/<workspace>/customer_<whatever-you-typed>`.
  Probably fine when the bridge agent has its own auth (one bridge
  -> one trust boundary), but a CINNOX-style integration may want
  per-customer URI stability across calls.
- The 30 s SSE timeout is hardcoded; should be configurable per
  workspace.
- No metrics: turn count, time-to-first-event, terminal-vs-timeout
  rate are not emitted as telemetry. Add `:telemetry.execute` in
  the receive loop's exit branches.
- The `workspace_uri` on audit rows is `workspace://system` (admin
  caller heuristic). Correct attribution requires the bridge-agent
  caller model.

### Friction points

- **Cookie discovery for setup script**: `~/.ezagent/<profile>/runtime/cookie`
  isn't documented anywhere obvious; copied the pattern from
  Phase 0. A `mix ezagent.runtime_node_info` task that prints
  node name + cookie path would save the friction.
- **`mix ezagent.bootstrap` insists on running `mix deps.get`** as
  Phase 2 — fails under `MIX_DEPS_PATH=...shared-deps` because
  Hex won't fetch into a path it didn't manage. Worked around by
  running `ecto.create + ecto.migrate` directly. The bootstrap
  task could detect a populated `_build` and skip Phase 2.
- **`Ezagent.Audit.Writer` only handles `:flush` as a `cast`/`info`,
  not `:call`** — my first audit-query script tried
  `GenServer.call(..., :flush)` and crashed. Worked around with
  `send(..., :flush) + Process.sleep(800)`. The writer should
  expose a sync `flush_sync/0` for test/PoC use.
- **Cross-PoC node-name collisions**: `epmd -names` still listed
  `ezagent_runtime`, `ezagent_runtime_exp_a1`, etc. from earlier
  PoCs. Profile-scoping the node name (e.g.
  `ezagent_runtime_<profile>@127.0.0.1` automatically) would
  remove a class of "Protocol 'inet_tcp' name in use" startup
  fights.
- **Bandit chunked-response back-pressure**: not tested. A slow
  consumer with a fast `chat.receive` fan-out could fill the
  Plug send buffer. `chunk/2` returning `{:error, :closed}` is
  handled, but `{:error, :send_buffer_full}` (if Bandit emits
  it) is not.

## Critical Files for Reviewer

- `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` — the entire transport (~230 LOC, single module).
- `apps/ezagent_web/lib/ezagent_web/router.ex` (the one-line route addition near the existing `/api` scope).
- `poc/exp-C3/setup.exs` — shows the minimum runtime state (workspace + sessions, NO agent) needed for the SSE path to function end-to-end.
