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

### Live browser run (2026-05-28, user-driven in Chrome)

- ✅ **Test 1 + Test 2 PASS** — `http://localhost:10142/chat/acme` renders the
  themed page (rose customer bubbles, "Acme Support" header). Customer sent
  "你好" → AI greeted in Chinese; sent "How long is the warranty on my Acme
  laptop?" → AI replied *"Acme laptops come with a 12-month warranty … Acme
  Pro … 24 months."* Live AI reply + soul personalization + multilingual,
  end-to-end in the real LiveView page (not curl). (criterion 1, full)
- ✅ **Test 3 (reload resume) PASS** — navigating to bare `/chat/acme` (no
  params) triggered the localStorage hook to redirect to
  `?conv=…&cid=…`; `load_history` restored the full thread (customer Q + AI
  reply) from MessageStore.
- ✅ **Test 4 (widget) confirmed** — embedding on a cross-origin host page
  (`http://localhost:8088/widget-test.html`) loads the iframe
  (`/chat/acme?embed=1`). The launcher bubble (`position:fixed; right:20px`)
  was just hidden behind the right-docked DevTools panel.
- ✅ **Test 5 (operator dashboard) PASS** — after switching to the `acme`
  workspace, `/admin/customer_sessions` lists live sessions (conv_id + Auto
  mode badge + last-message preview + timestamp). The detail view shows the
  live transcript.
- ✅ **Test 6 (operator takeover) PASS** — clicked "Take over": dashboard
  flipped to **Takeover** + posted the `(客服已接管对话)` notice from
  `system://chat-router`; sent an operator message. On the CUSTOMER tab,
  live with no reload: the `客服已接管` banner appeared, the takeover notice
  bubble showed, and the operator's message arrived as a green "客服" bubble.
  This proves the C3-tension fix — operator → customer in real time, no
  120 s SSE window.

**Full E2E (Test 1–6) PASS, driven in Chrome 2026-05-28.**

### Re-verified after merging latest ezagent main (2026-05-28)

Merged `origin/main` (incl. #439 create_agent-through-template, #438 URI
canonicalization, #434 workspace cap-visibility, + codex agent_bridge work)
into the branch — clean auto-merge (6 overlapping files, no conflicts).
Applied the new `DropWorkspacesVisible` migration, recompiled, restarted, and
re-ran the full flow in Chrome on the merged tree: customer LiveView live AI
reply + soul facts ✅, operator dashboard + takeover (notice + operator
message reach the customer live) ✅, SSE round-trip ✅, 13 unit tests ✅.
The merge broke nothing. Known minor (pre-existing, not a regression): the
very first send right after a fresh mount can occasionally land in the
`:connecting` race and be dropped — retry works; follow-up is to gate the
first send until `status == :ready` is confirmed client-side.

### Findings during the live run (non-blocking)

- **Operator workspace scoping** — the dashboard lists sessions for the
  operator's CURRENT workspace. The admin defaults to `workspace://system`;
  customer chats live in the tenant workspace (`acme`). The operator must
  switch to the tenant's workspace (top-left switcher) to see/take-over its
  sessions. This is correct (workspace-scoped visibility) but worth a UX note
  for productionization (operators provisioned per-tenant, or a cross-tenant
  super-operator view).
- **Cosmetic, live-append path only — FIXED (commit `fa87dbce`), re-verified
  in Chrome:**
  1. Welcome bubble was a static child inside the `phx-update="stream"`
     container → rendered below messages. Moved OUTSIDE the stream container;
     now hides correctly once messages exist.
  2. Composer didn't clear after send (LiveView resets the value *attribute*
     but preserves the value *property* across patches — confirmed via
     `attr:"" / prop:"…"`). Fixed by binding the form value + clearing the
     property on submit in the `CustomerChatPersist` hook.
  - Bonus during re-verify: confirmed phone soul fact too ("6-month warranty,
    no extensions").

### Bugs found + fixed during live validation

1. **Assets not built on fresh boot** — `/assets/js/app.js` 404 → LiveView
   socket never connected → page stuck "connecting…". Root cause: esbuild
   `NODE_PATH` points at repo-local `deps/`, absent under shared
   `MIX_DEPS_PATH`. Fix: symlink `deps/ → shared cache` + build bundles
   (documented in MANUAL-TEST-PLAN appendix). Env/dev-setup issue, not a code
   defect.
2. **widget.js blocked by CSRF** — served via `:browser` pipeline whose
   `protect_from_forgery` raised `InvalidCrossOriginRequestError` on the
   cross-origin `<script>` fetch. Fix: dedicated `:public_asset` pipeline
   (commit `c386ebb9`).
3. **iframe blocked cross-origin by CSP** — `/chat` sent
   `content-security-policy: frame-ancestors 'self'`, blocking embedding on a
   business's site. Fix: `:customer_chat_browser` pipeline keeps CSRF/session
   but relaxes `frame-ancestors` (commit `4762a943`).

## Plugin extraction — acceptance (2026-05-30)

Extracted the customer-service surface into `ezagent_plugin_customer_chat`
(spec/plan `10-customer-chat-plugin-extraction-*.md`), 11 tasks via
subagent-driven dev (each substantive task got spec + code-quality review).
Re-verified end-to-end in Chrome on the extracted + latest-main-merged tree:

- ✅ **Plugin registers** — `/plugins` shows a "Customer Service" card linking
  to `/operator` (via `config_surface: %{kind: :route, ...}`). `PluginRegistry`
  lists `customer_chat | Customer Service`.
- ✅ **Customer chat + soul** — `/chat/acme`: themed page, live AI reply with
  acme soul facts (12-mo / 24-mo Pro). (SSE headless path also re-verified.)
- ✅ **Reload-resume** — hard-reload restored the thread.
- ✅ **`/operator/:tenant` direct entry** — logging in then going straight to
  `/operator/acme` lands on the dashboard for acme **with no workspace switch**
  (the friction the extraction set out to remove). Lists live sessions.
- ✅ **Operator takeover** — `/operator/acme/<conv>` → "Take over" → operator
  message reaches the customer page live (banner + `(客服已接管对话)` notice +
  green 客服 bubble), no SSE timeout.
- ✅ **Old-link redirect** — `/admin/customer_sessions[/:id]` → `/operator`
  (302; bounces through `/login` for anon, as gated).
- ✅ **No hardcoded tenant** in `ezagent_plugin_customer_chat/lib` (grep clean).
- ✅ **13 unit tests** green under the new app; our code `--warnings-as-errors` clean.

### Bugs found + fixed during extraction (each by the review/e2e gate)

1. **Soul-root hop count** (T3) — the old `customer_chat/` subdir added a path
   level the flat plugin layout drops; `..` count 6→5. Caught by the implementer
   verifying the resolved path.
2. **Operator cap field name** (T8) — `OperatorAuth` used `Capability.workspace`
   but the field is `workspace_uri`; the wrong key returned `nil` → the gate
   silently denied ALL non-admin operators (fail-closed). Caught by spec review
   (compiler also warned `unknown key`).
3. **`handle_info` KeyError guard + old `:id` redirect + action-name shadow**
   (T8) — code-quality review items, fixed.
4. **Tailwind `@source` regression** (T11 e2e) — the new app's lib path wasn't in
   the Tailwind v4 content globs, so its classes were purged → broken layout +
   missing theme. Caught only by the live browser run (compile/tests were green).
   Fixed by adding `@source "../../../ezagent_plugin_customer_chat/lib"`.

Deferred (documented, not regressions): escalation signal, CINNOX EM adapter,
operator-cap legacy-`:any` tolerance, picker filtering of `workspace://system`,
`servable_tenants` N-dispatch refactor.

---

## Scope #1 — Editable Soul (2026-05-30, home machine)

Spec/plan: `11-admin-edit-soul-{design,PLAN}.md`. Implemented T1–T7 via
subagent-driven TDD (commits `9721c30d` SoulStore, `915a00f4` bootstrap delegate,
`3215146c` ConfigAuth, `f4641c8c` ConfigLive, `f6abd36a` route, `f793f80f`
dashboard link, + cinnox fixture seed). All on `poc/phase-2-customer-service`.

### Verified ✅
- **Unit:** SoulStore 6 tests (edited→fixture→nil resolution; write snapshots
  `.prev`; revert; reset) + ConfigAuth 6 tests (admin via capability — NOT a
  membership bypass; workspace-admin admits; per-tenant isolation; responder
  `Mode.set` excluded; action-axis). Full app suite **24 tests, 0 failures**;
  our-app `--warning-as-errors` clean.
- **Route:** `mix phx.routes` → `/plugins/customer-chat/:tenant/config` resolves
  to `EzagentPluginCustomerChat.ConfigLive` (scope-alias gotcha avoided).
- **Mechanism — edit → new conversation uses it (PROVEN live at spawn):** with a
  distinctive edited soul written to the cinnox sandbox edited-path, a **new**
  conversation's cc-agent spawn command carried
  `--append-system-prompt = channel_preamble() <> <EDITED soul body>` (captured in
  the server log) — the new conv picked up the **edited** soul (not the fixture)
  via `SoulStore.effective_path` at spawn. Core scope-#1 claim, end-to-end through
  T1+T2+cc_agent.
- **Reset reverts (PROVEN live at the resolution layer):** in the running config,
  `read_effective("cinnox","customer")` returned `source: :edited` with the edit
  present, then `source: :fixture` (the seeded cinnox soul) after `reset/2`;
  `edited?` back to `false`.

### Blocked (environment, NOT this feature) ⚠️
- **Live AI reply round-trip** (customer sends → claude replies per the soul) is
  blocked on this machine: the cc agent is a `claude` **PTY** subprocess spawned
  via erlexec, and `exec-port` crashes the `:exec` manager with **`:einval` on the
  `:pty` spawn** (`Application erlexec exited: shutdown` → later spawns `:no_pty`).
  OTP 28 / macOS 12 / Intel `exec-port` build. Platform agent-execution layer,
  orthogonal to scope #1, and it **blocks the reply via the browser too** (same
  PTY path). Handoff flags cc/PTY e2e as work-machine territory (cc agents already
  run there). Web/LiveView/SoulStore-writes/auth are unaffected (server up on
  :10142) — the UI is manually testable; only the reply needs the working PTY.
- **To get a full live reply here** (optional): rebuild erlexec for OTP 28
  (`mix deps.compile erlexec --force`) or bump erlexec (see the `erlexec-elixir`
  skill) — OR run the reply round-trip on the work machine.

### Browser UI e2e (live, 2026-05-30 — Claude-in-Chrome)

Driven live against the running server (login `entity://user/system/admin`):
- ✅ Gated **"Configure soul"** link shows on `/operator/cinnox` for the admin.
- ✅ Editor loads at `/plugins/customer-chat/cinnox/config` (fixture soul,
  **"default"** badge, **Revert disabled** with no prior version).
- ✅ Edit → **Save** → badge → **"customized"** + file written to the sandbox
  edited-path (disk-confirmed).
- ✅ 2nd Save → **Revert enabled** (`.prev` snapshotted) → **Revert** restored v1.
- ✅ **Reset** → reverts to fixture, badge → **"default"**, Revert disabled,
  sandbox edited+`.prev` deleted (disk-confirmed).

UI fix during this run (`bd9d71ce`): replaced the Reset `data-confirm` (native
`window.confirm`, which blocks the renderer + is unstyled) with an **inline
LiveView two-step confirm** ("Reset to default? · Confirm reset · Cancel") —
non-blocking + styled; re-verified live. Only the AI *reply* remains PTY-blocked
(separate task).

### PTY blocker FIXED + corrected diagnosis (2026-05-30, pulled from sub-task)

The "PTY-env-blocked" note above was on the right track but the root cause was
**env *size***, not PTY/OTP-28. Fix pulled in + committed `200c3317`
(`fix(pty,python): build_env passes only overrides`):
- **Root cause:** `Ezagent.Domain.Pty.Server.build_env/1` (and the Python
  sidecar's) splatted the **entire** inherited `:os.getenv()` into erlexec's
  `{:env,...}`. erlexec frames each run command to `exec-port` over a `{packet,2}`
  channel (65535-byte max). A large shell env pushed the `term_to_binary`'d
  command past 64 KB → BEAM port write `:einval` → node-wide `:exec` manager
  crash → erlexec shutdown → every later spawn `:no_pty`. "Works on the work
  machine" = its env is just smaller. Bare `:pty` on OTP 28 / erlexec 2.3.0 is
  fine. Fix: pass only overrides; child still inherits ambient env via exec-port.
- **Verified:** `server_env_test.exs` 4/4 (override-only + <8 KB even with a
  100 KB inherited var). **Live:** with the fix, cc-agent claude processes now
  **launch** (`os_pid` assigned) carrying the correct `--append-system-prompt`
  (a small edited cinnox soul → "…reply SENTINEL-ALPHA-42"); pre-fix nothing
  spawned. This also confirms scope #1's soul-flow live (editor edit → new conv's
  cc spawn uses the edited soul).

**Two further findings (separate from the env fix, NOT scope #1):**
1. **Large soul as CLI arg also overflows the same 64 KB `{packet,2}` limit.** The
   89 KB cinnox *fixture* soul, passed via `--append-system-prompt`, blows the
   command-size budget → identical `:einval`. So the *default* cinnox soul can't
   spawn; small/edited souls do. Worse, a *persisted* large-soul agent (e.g.
   `cc_cs_main` from `setup.exs` with the fixture soul) eager-spawns at boot and
   crashes the node-wide `:exec` → boot fails. **Follow-up:** pass large souls via
   a file, not an inline arg. (Filed as a task.)
2. **cc bridge handshake** times out on this fresh machine (`agent_setup_failed /
   :timeout`): claude launches but never announces back to the esr-bridge — a
   cc-onboarding/MCP layer (first-run), separate again from the above. The full
   live customer→claude→reply round-trip needs this resolved too.

Net: env fix verified (the original blocker); live AI reply now blocked only by
(1)/(2), both distinct from the env fix and scope #1.
