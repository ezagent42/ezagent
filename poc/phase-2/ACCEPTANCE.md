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

## ✅ Soul-augmented customer reply (RESOLVED 2026-05-28)

Original gap: with a tenant soul attached, claude called the `reply`
tool with `session_uris: []` (empty list) — confirmed via WS frame in
the bridge log: `[..., "session_uris": []]`. `BridgeAdapter` then
silent-dropped because there was no session to send to. The Acme soul
(facts + tone) dominated claude's attention over the python bridge's
tool description, even though the description marked `session_uris`
required.

**Fix**: `cc_agent.ex::build_soul_args/2` now prepends a fixed
~20-line **channel-protocol preamble** to every tenant soul before
inlining as `--append-system-prompt`. The preamble explicitly tells
claude that (a) every `<channel source="esr-bridge">` is a USER
message, (b) reply via the `reply` tool ONLY (inline text invisible),
(c) `session_uris` MUST be `[meta.session]` from the inbound tag.
Tenant soul follows below the preamble with a guard "the protocol
above always wins on disagreement".

**Validated 2026-05-28** end-to-end:

```
curl POST /api/customer/acme/chat → SSE message event:
"Great question! Acme laptops come with a 12-month warranty
standard. If you have a Pro line laptop, you're covered for
24 months. Is there anything else I can help you with?"
```

Reply correctly surfaces soul-specific facts (12-month / 24-month
Pro line) AND friendly tone — full E2E with tenant personalization
working.

Implementation: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
`channel_preamble/0` + integration in `build_soul_args/2`.

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

## Phase 3 — Customer chat frontend (acceptance results, 2026-05-28)

Implemented per `8-customer-chat-frontend-design.md` + `-PLAN.md` (Approach A:
LiveView `/chat/:tenant` + iframe widget; code in `ezagent_plugin_liveview`
under the `CustomerChat` namespace). 13 unit tests green; our code
compiles warning-clean.

### Verified server-side (curl against running poc-phase2 server)

1. **Hosted page renders themed** — `GET /chat/acme` dead-render contains
   `Acme Support` (title), `--cc-primary: #e11d48` (acme rose from the
   `acme.json` fixture), `cc-root` + `CustomerChatPersist` hook,
   `Type your message…` placeholder, `connecting` status, disabled-composer
   classes. ✅ (criterion 1, structural)
2. **Embed mode** — `GET /chat/acme?embed=1` applies `bg-transparent` and
   drops the header. ✅ (criterion 2, render)
3. **Widget loader** — `GET /customer-chat/widget.js` returns
   `application/javascript` with the launcher+iframe loader (`data-tenant`,
   `/chat/`, `?embed=1`, `iframe`, `addEventListener`). ✅ (criterion 2)
   - **Bug caught + fixed by this e2e**: the route was initially under the
     `:browser` pipeline, whose `:protect_from_forgery` raised
     `Plug.CSRFProtection.InvalidCrossOriginRequestError` on the
     cross-origin `<script src>` fetch. Moved to a lean `:public_asset`
     pipeline (no session/CSRF). The unit test didn't catch it because
     `ConnCase` doesn't exercise the CSRF plug.
4. **No hardcoded tenant data** — zero `acme` in executable code; only in
   the `acme.json` fixture + two doc-comment examples. ✅ (criterion 5)

5. **Live cc round-trip + soul personalization** — `POST /api/customer/acme/chat`
   on the running build returned an AI reply with the acme soul facts:
   *"Acme laptops come with a 12-month warranty as standard … Acme Pro …
   24 months."* This exercises the SHARED `CustomerChat.Bootstrap`
   (`ensure_cc_for_conv` → `EagerBridge.ensure_bound!` → `dispatch_chat_send`
   → soul reply) — the exact code path `ChatLive` calls — so criterion 1's
   core (cc spawn + bridge + tenant personalization) is proven live. ✅
   (criterion 1, backend)

### Pending live-browser validation (require a connected browser / WebSocket)

Note: the Chrome extension was not connected during this run, so the
LiveView-WebSocket-only behaviors below were not driven. The backend they
ride on is proven (point 5). To validate, open `/chat/acme` in a browser.

- **criterion 1 (LiveView surface):** the proven cc reply rendering as a live
  stream_insert in the page (vs the SSE wire above).
- **criterion 4:** reload the page → same conversation thread restored
  (localStorage `conv`/`cid` resume).
- **criterion 3:** operator takes over from `/admin/customer_sessions` →
  customer page shows `客服已接管` + operator message live, no SSE timeout
  (the C3-tension fix — validated structurally; needs a live two-party run).

These three are interactive and are validated by opening the page in a
browser (the customer-facing payoff the whole task targets).
