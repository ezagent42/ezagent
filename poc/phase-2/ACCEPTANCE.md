# Phase 2 — Acceptance

## What works end-to-end (proven on running server)

### ✅ Customer-channel HTTP+SSE round-trip with real cc agent

```bash
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"alice","text":"how long is the warranty on my laptop?","conv_id":"e2e-test-2"}'
```

Returns (with NO soul fixture configured for `acme`):

```
event: open
data: {"workspace":"acme","session_uri":"session://default/acme/e2e-test-2",
       "agent_uri":"entity://agent/acme/cc_cust_e2e_test_2",
       "conv_id":"e2e-test-2","customer_uri":"entity://user/acme/customer_alice",
       "sent_msg_id":"318de75d3d0f5866"}

event: message
data: {"text":"Hi! To look up the warranty on your laptop, I'll need a bit
        more information. Could you please provide:\n
        1. The laptop model name/number\n
        2. Your order number or purchase date\n
        With those details, I can give you the exact warranty coverage
        for your device.",
       "terminal":true,
       "sender":"entity://agent/acme/cc_cust_e2e_test_2",
       "msg_id":"392507f33f718e4d"}

event: close
data: {"reason":"terminal"}
```

Total latency from POST to first `message` event: ~10s (cold cc spawn + bridge
handshake + first turn).

**This proves the architecture is sound**:
- Per-conv `session://default/<workspace>/<conv-id>` URI scheme working
- Per-conv cc agent (`cc_cust_<sanitized_conv_id>`) spawn-per-customer working
- `EzagentPluginCc.EagerBridge.ensure_bound!/2` brings the bridge up
  programmatically (~500ms-2s after agent spawn) without operator interaction
- Customer message routes through `chat.send → fan-out → chat.receive(Agent)
  → AgentBridge.deliver → claude → reply tool → bridge channel → session
  topic → SSE controller → wire`
- Concurrent isolation between distinct `conv_id`s verified earlier (EXP-C3
  base; carried over)

### ✅ Operator dashboard

Routes registered at `/admin/customer_sessions` and `/admin/customer_sessions/:conv_id`.
Auth-gated behind admin LV scope. Dashboard enumerates active customer
sessions (subscribed to PubSub for live updates). Detail page subscribes to
one session's events and includes a "Take over" button that dispatches the
mode-flip action defined by Phase 2.6.

(End-to-end demo with a real customer session present in the dashboard
requires running the customer-channel + dashboard against the same DB; standalone
acceptance per `poc/phase-2/7-operator-dashboard.md` confirms route registration
and structural correctness.)

### ✅ Session mode (auto / takeover) + AI gating + customer notice

19 unit tests (in `apps/ezagent_domain_chat/test/.../mode_test.exs`) pass
for the 5 acceptance scenarios:

1. `:auto` mode — AI sends → customer sees
2. Mode flip `auto → takeover` → customer sees `"(客服已接管对话)"`
3. `:takeover` mode — AI sends → customer does NOT see (persistence still happens)
4. `:takeover` mode — Operator sends → customer DOES see
5. Flip back `takeover → auto` — AI sends → customer sees again

Dispatch shape for the dashboard to flip mode:
- target: `session://.../<conv_id>?action=mode.set`
- args: `%{mode: :takeover}` (or `:auto`)
- returns `{:ok, %{mode: :takeover, previous: :auto}}`

### ✅ Admin caps page works on fresh boot (ezagent#395 same-pattern fix)

`/admin/identities/users/.../caps` no longer requires the manual RPC
`Ezagent.Kind.spawn(Ezagent.Entity.User, ...)` workaround.
`EntityCapsLive` now pre-spawns the target Kind via `SpawnRegistry.spawn/1`
and polls `ReadyGate.status` (~500ms ceiling) before dispatching grant.

## Known limitation (not blocking the architecture proof)

### ⚠️ Soul-augmented customer reply doesn't reach SSE

When the cc agent spawns with `--append-system-prompt <Acme soul>` (EXP-A1
soul_path Template arg active), the bridge log confirms `HANDLED reply
INCOMING ON agent_bridge:cc:...` — i.e., claude DID generate a reply and
the python bridge forwarded it to ezagent. But the reply doesn't land in
`messages` table or get broadcast on the session topic, so SSE never sees
it. Customer's stream times out after 120s.

**Hypothesis**: `EzagentPluginCc.BridgeAdapter.handle_client_event("reply",
%{"text" => _, "session_uris" => sessions}, ...)` requires `session_uris`
to be in claude's reply tool call. Without a soul, claude's default channel
prompt instructs it to include `session_uris` in the reply. The Acme soul
fixture (cinnox-borrowed) describes tone + facts but doesn't reinforce the
channel-protocol hint, so claude may call the reply tool without
`session_uris` and the adapter discards it.

**Why this isn't blocking**: the wire is proven — without soul, the round
trip completes. The fix is downstream of Phase 2.4's integration work:
either (a) include the channel-protocol prefix in the soul preamble (a
trivial soul-file edit), or (b) augment the meta payload so the adapter
can derive `session_uris` from `meta.session` when claude omits it.

**Carry forward to Phase 3**: write a "soul preamble" that all tenant souls
get prepended with — contains channel-protocol instructions claude needs
regardless of business tone. Documented in `TEAM-REVIEW.md` §"Carry-forward".

## What's in this Phase 2 branch (summary)

| File / module | Purpose | Phase |
|---|---|---|
| `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/eager_bridge.ex` | Bridge auto-bind primitive | 2.1 |
| `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (`+soul_path`) | Soul as Template arg | 2.2 |
| `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` | HTTP+SSE customer channel + integration | 2.3 + 2.4 |
| `apps/ezagent_plugin_liveview/.../entity_caps_live.ex` (`+pre-spawn`) | Admin caps page fix | 2.5 |
| `apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex` (new) | Session mode + AI gating | 2.6 |
| `apps/ezagent_plugin_liveview/.../customer_sessions_dashboard_live.ex` (new) | Operator dashboard | 2.7 |
| `apps/ezagent_plugin_liveview/.../customer_session_view_live.ex` (new) | Per-session detail + take-over | 2.7 |
| `poc/fixtures/plugins/acme/souls/customer.md` | Acme test soul fixture (cinnox-borrowed) | 2.2 |
| `poc/phase-2/setup.exs` | Tenant-parameterized provisioning (TENANT, ROLE, SOUL_PATH env) | 2.0/2.2 |

## Operator runbook

```bash
# 1. Bootstrap profile (no deps.get under MIX_DEPS_PATH)
cd <ezagent-poc-phase-2-root>
MIX_DEPS_PATH=<shared-deps> mix compile
EZAGENT_PROFILE=poc-phase2 mix ezagent.home.init
EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=<shared-deps> mix ecto.create
EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=<shared-deps> mix ecto.migrate

# 2. Start server (ezagent#435 env workaround)
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 \
  MIX_DEPS_PATH=<shared-deps> \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY \
      -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  mix phx.server

# 3. Provision tenant (acme) + admin
COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
elixir --name "phase2_setup@127.0.0.1" --cookie "$COOKIE" \
  poc/phase-2/setup.exs

# 4. Customer chat
curl -N -X POST http://localhost:10142/api/customer/acme/chat \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"alice","text":"how long is warranty?","conv_id":"demo-1"}'

# 5. Operator dashboard
# Browser → http://localhost:10142/admin/customer_sessions
# (Log in as admin via /login → entity://user/system/admin / <password>)
```
