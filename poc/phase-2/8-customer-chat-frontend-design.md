# Phase 3 (8) — Customer Chat Frontend (LiveView + embeddable widget)

> Design spec. Builds directly on Phase 2 (customer SSE channel + operator
> dashboard + Mode behavior). Resolves the C3-vs-persistent-connection
> tension flagged in `ARCHITECTURE-zh.md`. Decided 2026-05-28.

## 1. Context & problem

Phase 2 delivered the customer→AI→reply round-trip and an operator
dashboard, but the **customer side has no web page** — only the
HTTP+SSE API (`customer_chat_controller.ex`), which is why the manual
test plan uses `curl`. Real end users (and operators) are
non-technical; they need a UI, not a terminal.

The product vision: a business adopts a pre-built **template** (today:
AI customer service) and gets a working chat surface, then customizes
details. The frontend must therefore be **part of that template** —
a reusable slice, not a one-off page hardcoded to one tenant. The
genericity self-check in `ARCHITECTURE-zh.md` already anticipated this:
"Customer channel / Operator dashboard → 应进未来的 customer-chat plugin."

## 2. Decision summary

**Chosen: Approach A — single LiveView stack + iframe widget.**

| Approach | Verdict | One-line reason |
|---|---|---|
| **A. LiveView page + iframe widget** | ✅ chosen | One implementation serves both hosted page and embeddable widget; same stack as operator console; zero new build system; real-time free. |
| B. All-JS component lib (Preact/React) + two shells | ❌ | True native widget + frontend-dev-friendly, but introduces a JS build chain into the Elixir-native umbrella, splits stacks from the LiveView operator console, and re-treads what AutoService's React client already proved. Over-engineered for "basic framework only." |
| C. LiveView hosted page + thin-JS widget (share only API) | ❌ | Two component implementations, core shared only at API level — more maintenance than A, less capability than B. Worst ratio. |

Requirement satisfied: **"both hosted page AND embeddable widget, sharing
core."** Because the widget is an iframe of the same LiveView, hosted page
and widget are *one* implementation worn two ways — maximal sharing at
minimal cost.

## 3. Architecture

The customer-chat frontend = the frontend slice of the
AI-customer-service template.

**Prototype home (this round): `ezagent_plugin_liveview`**, under a
distinct `CustomerChat` namespace. Rationale: every umbrella app must
satisfy the `Ezagent.Plugin` declarative contract + the non-bypassable
`:ezagent_plugin_check` Mix-compiler gate (even the pure-UI liveview app
does). Spinning a brand-new `ezagent_plugin_customer_chat` app means
replicating that ceremony + umbrella/dep wiring — yak-shaving that does
not advance a working chat page at prototype stage. `ezagent_plugin_liveview`
already depends on exactly what CustomerChatLive needs: `ezagent_plugin_cc`
(EagerBridge), `ezagent_domain_chat` (Chat behavior / topic / MessageStore),
`ezagent_domain_ui` (HEEx primitives). **Extraction into a dedicated
`ezagent_plugin_customer_chat` is the documented productionization step
(§11).** The namespace (`EzagentPluginLiveview.CustomerChat.*`) keeps the
slice cohesive so the later move is a rename, not a rewrite.

| Component | What | Where |
|---|---|---|
| **CustomerChat.ChatLive** | Customer chat page (LiveView, public, no login) | `live "/chat/:tenant"` |
| **CustomerChat.Components** | Shared HEEx function components (message bubble / list / input / takeover banner) | `customer_chat/components.ex` |
| **CustomerChat.Bootstrap** | Reusable "ensure session + cc + bind + join" + mention synthesis (extracted from `customer_chat_controller.ex`, DRY) | `customer_chat/bootstrap.ex` |
| **CustomerChat.Theme** | Per-tenant theme (logo / primary color / title / welcome / placeholder), config-driven | `customer_chat/theme.ex` + `theme/<tenant>.json` fixture (acme) |
| **widget.js** | ~40-line loader: injects launcher bubble + iframe | served by a plain `EzagentWeb` route at `/customer-chat/widget.js` |
| **headless API** (existing, stays in `ezagent_web` this round) | `customer_chat_controller.ex` HTTP+SSE — kept for machine/3rd-party integrators (e.g. CINNOX using its own IM); refactored to call `CustomerChat.Bootstrap` so logic is shared, not duplicated | `POST /api/customer/:tenant/chat` |

Two legs by consumer:
- **Humans** open a web page → **LiveView** (persistent connection).
- **Machines / 3rd-party IM** → **HTTP+SSE API** (request/response).

## 4. Why LiveView (and the C3 tension it resolves)

`chat.send` in `Ezagent.Behavior.Chat` already fans out on **two
independent paths** (chat.ex docstring lines 17–20):

```
chat.send
 ├─ delivery: recipients = mentions (or members); each gets chat.receive
 │            ← cc agent is fed via THIS path (→ bridge → claude)
 └─ feed:     broadcast to esr:session:<uri>:events
              ← any subscribed LiveView sees it live (operator console; customer page)
```

Phase 2's customer side used HTTP+SSE (C3, request/response): each
customer message opens a stream that closes after the AI's terminal
reply. The flagged tension was — if an operator takes over, the AI is
gated, there is no terminal reply, and the customer's SSE stream hangs
until the operator replies **within 120 s** or it times out.

**LiveView removes this tension structurally**: it is itself a
persistent WS connection. The customer page subscribes to
`session_events_topic` once at mount and receives everything — AI
replies, the takeover notice, *and* operator messages — on the same
topic, with no 120 s window. The frontend work and the Phase 3
"persistent connection" decision are therefore the same piece of work.

## 5. CustomerChatLive

Mirror of the operator's `customer_session_view_live.ex`, from the
customer's side (customer = sender + subscriber; operator = subscriber +
external actor).

```
mount(%{"tenant" => t} = params, _session, socket):
  conv_id      = params["conv"] || resume-from-client || generate
  customer_uri = entity://user/<t>/customer_<id>        (synthetic, ephemeral)
  ensure session://default/<t>/<conv_id>                 (per-conv, isolated)
  ensure cc agent + EagerBridge.ensure_bound!            (reuse Phase 2 ensure_cc_for_conv logic)
  join cc agent to session                               (cc is the only delivery member)
  PubSub.subscribe(session_events_topic(session_uri))    (feed; NOT a member)
  load history from MessageStore                          (subscribe only gets future events)
  assign theme (from config)

handle_event("send", %{"text" => text}):
  build customer Message with mentions:[cc_agent_uri]    (default routing is mention-gated)
  dispatch chat.send (cast)

handle_info({session feed event}):
  stream_insert message → live render
  (handles AI reply, operator message, takeover notice uniformly)

render:
  embed?  → just the chat panel (transparent bg, bubble-sized) when ?embed=1
  hosted  → full page chrome (themed header + panel)
  takeover banner when mode == :takeover
```

`?embed=1` is the only difference between hosted and widget rendering —
same LiveView, two layouts.

## 6. Shared HEEx components

`CustomerChatComponents` — `message_bubble/1`, `message_list/1`,
`chat_input/1`, `takeover_banner/1`. Used by CustomerChatLive now; the
operator detail view can adopt the same bubble later (genuine
component-level sharing within the LiveView stack). Styling driven by
CSS variables set from theme.

## 7. widget.js

Business embeds one line:

```html
<script src="https://<host>/customer-chat/widget.js" data-tenant="acme"></script>
```

Loader (vanilla JS, no build step): reads `data-tenant` + optional
`data-base-url`; injects a floating launcher button; on click toggles an
`<iframe src="<base>/chat/<tenant>?embed=1">` sized as a chat panel.
Style isolation comes for free from the iframe boundary.

## 8. Theme / template boundary (honors "no hardcoded tenant data")

- **Zero-code customization** (the common path): per-tenant `theme`
  (`logo_url`, `primary_color`, `title`, `welcome_message`,
  `placeholder`), read from config. `acme` ships as a fixture, peer to
  the soul fixtures. No tenant string is baked into code.
- **Deep customization** (power users): edit the HEEx templates shipped
  with the plugin.
- This whole plugin is the template's **frontend slice**; its
  customization knobs are theme config (no code) + HEEx override.

## 9. Operator model continuity (unchanged, now consistent)

Operator stays an **observer + external actor**: subscribe to the events
topic (read) + cap-gated `dispatch` of `mode.set` / `chat.send` (write).
NOT a session member. Rationale (grounded in chat.ex two-path split):
membership/delivery is for participants who must *reliably receive* every
message (the cc agent); topic subscription is for *watching*. With the
customer now also a topic subscriber, the model is clean:

> Only the cc agent uses membership/delivery (it is a process that must
> reliably receive). Both humans — customer and operator — are topic
> subscribers + cap-authorized senders.

One operator → many sessions is *why* the observer model wins: one
dashboard LiveView subscribes to many topics cheaply (fan-in to one
mailbox), zero membership state; the member alternative would force
join/leave churn across every watched session.

## 10. Data flow (hosted page or widget — identical)

```
Browser opens /chat/acme  (or iframe inside widget)
 → CustomerChatLive.mount: ensure session, ensure cc + EagerBridge,
                           subscribe topic, load history, assign theme
 → customer types → handle_event("send") → dispatch chat.send (mentions:[cc])
 → Session fan-out → cc agent → claude(soul) → reply → broadcast topic
 → handle_info(feed) → stream_insert → live update
 → operator takeover (from operator console): mode.set + notice + operator msgs
                           → arrive on the SAME topic, live, no 120 s window
```

## 11. Scope this week (YAGNI)

**MUST**
- `ezagent_plugin_customer_chat` plugin skeleton + route registration.
- CustomerChatLive at `/chat/:tenant` (themed, real-time, reuses session
  layer + EagerBridge).
- `CustomerChatComponents` shared HEEx.
- `acme` theme fixture + config-driven theme loader.
- `widget.js` + `?embed=1` rendering mode.
- conv_id client-side resume (localStorage) so reload keeps the thread.

**DEFER (documented, not built)**
- **Extracting a dedicated `ezagent_plugin_customer_chat` umbrella app**
  (full `Ezagent.Plugin` contract + `:ezagent_plugin_check` gate + dep
  wiring). Prototype hosts the slice inside `ezagent_plugin_liveview`
  under the `CustomerChat` namespace; the later move is a namespace
  rename, not a rewrite.
- Relocating `customer_chat_controller.ex` out of `ezagent_web` (it stays;
  this round it is refactored to call the shared `CustomerChat.Bootstrap`).
- Abuse protection on the public page (rate-limit / captcha).
- Rich content (attachments, markdown rendering).
- Operator console rewrite / moving it into this plugin (it works; leave it).
- Dashboard "summary feed" optimization for watching many sessions at scale.

## 12. Risks & follow-ups

- **Public, no-login customer page** (synthetic customer URI): acceptable
  for PoC; abuse protection is a follow-up.
- **Operator caps**: to dispatch into sessions the operator doesn't
  belong to, the operator needs a workspace-scoped cap over
  `session://default/<tenant>/*`. Setup requirement, correct home for the
  authority (cap, not membership).
- **History load**: topic subscription only yields post-subscribe events;
  mount must query MessageStore for prior turns.
- **Scaling many-session watch**: full-transcript subscription per session
  is fine at PoC scale; a per-session "last message" summary feed is the
  refinement when the dashboard watches dozens.

## 13. Acceptance criteria

1. Open `http://localhost:10142/chat/acme` in a browser → see a themed
   chat page; send "warranty?" → AI reply with acme soul facts streams in
   live (no curl).
2. Embed `widget.js` on a scratch HTML page → launcher bubble → iframe
   chat works identically.
3. With the page open, operator takes over from the dashboard → customer
   page shows the takeover banner + operator messages live, with no SSE
   timeout (validates the C3-tension fix).
4. Reload the customer page → same conversation thread restored.
5. No tenant string hardcoded in code (theme + paths all config-driven) —
   `grep` clean per constraint #1.
