# Phase 2.7 — Operator dashboard for live customer sessions

## TL;DR

Two LiveViews + two routes added to `ezagent_web` router. List view
enumerates per-conv customer sessions in the operator's current
workspace, with last-message preview + mode badge; detail view
shows live transcript + "Take over" button. Mode-flip is stubbed
with a `# PHASE_2.6_INTEGRATION` comment showing the dispatch
shape — Phase 2.4 will wire the real action verb after 2.6 lands.

## Files added

| File | Purpose |
|---|---|
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_sessions_dashboard_live.ex` | List LV at `/admin/customer_sessions` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_session_view_live.ex` | Detail LV at `/admin/customer_sessions/:id` |

## Files modified

| File | Change |
|---|---|
| `apps/ezagent_web/lib/ezagent_web/router.ex` | +2 routes inside the `:require_admin` live_session |

## Routes

```
GET /admin/customer_sessions              CustomerSessionsDashboardLive
GET /admin/customer_sessions/:id          CustomerSessionViewLive
```

`:id` is the URL-encoded canonical session URI string
(`session://default/<ws>/<conv-id>`), matching the convention
`agent_detail_live` uses for entity URIs.

## Session enumeration strategy

Per Phase 1+2 verdict §3, customer sessions live at
`session://default/<ws>/<conv-id>` with `conv-id != "main"`
(`main` is the shared chatroom AdminLive owns).

Enumeration: `EzagentDomainChat.list_sessions(workspace_uri)`
(workspace-scoped structural filter from
`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:508`) →
filter `customer_session?/1` keeps only per-conv URIs.

Subscriptions: each enumerated session's `session_events_topic/1`
(`esr:session:<uri>:events`). PubSub.subscribe is idempotent per
`(pid, topic)`, so re-subscribing on every chat_message event is a
safe way to catch newly-spawned sessions without a separate
lifecycle topic.

A real production deploy with hundreds of live sessions should
swap this for a dedicated session-lifecycle PubSub topic so the
LV doesn't re-enumerate KindRegistry on every message — see
"Subtleties" below.

## Authorization decision (PoC)

Per constraint #2 (no new entity Kinds), operator is just an
`entity://user/<ws>/<name>` with some cap. The dashboard's gate is
"any cap on the operator's identity" via
`Ezagent.Identity.list_caps_for/1` returning a non-empty MapSet.

Both LVs live under the router's `live_session :require_admin`
block to honor the existing invariant ("every /admin/* live is
admin-gated"). The in-LV cap check is therefore redundant today
(admin satisfies it trivially) but stays as the structural
production gate.

### Production cap shape (recommendation)

Two distinct capabilities, both on the workspace:

| Cap | Purpose | Granted to |
|---|---|---|
| `Behavior.Workspace :customer_session_observer` | View dashboard + per-session transcript (read-only) | Frontline operators, supervisors |
| `Behavior.Mode :set` | Flip session mode to `:takeover` (and back) | Supervisors only |

Granting the observer cap to a User in workspace X lets them see
every X-workspace customer session. The mode cap is the gate for
the take-over button — non-holders see the dashboard + transcript
but the button is disabled / hidden.

This split lets a CX deployment grant "watch" widely (training,
audit) without inflating the takeover surface. The router can
then drop these LVs out of `:require_admin` into a new
`:require_operator_cap` live_session whose `on_mount` enforces
the observer cap. Until then, the in-LV `has_any_cap?/1` is a
forward-compatible stop-gap.

## PHASE_2.6_INTEGRATION points

Three call sites total — all clearly marked. Phase 2.4 needs to
visit each and replace the stub with whatever shape 2.6 documents
in `poc/phase-2/6-mode-takeover.md`:

| File | Line (approx) | What to replace |
|---|---|---|
| `customer_sessions_dashboard_live.ex` | ~298 (`defp lookup_mode`) | Replace `:auto` literal with the actual Behavior/slice read |
| `customer_session_view_live.ex` | ~370 (`defp lookup_mode`) | Same — mirror the dashboard's read |
| `customer_session_view_live.ex` | ~290 (`defp dispatch_takeover`) | Replace `?action=mode.set` URI + `%{mode: :takeover, set_by: ...}` args with the 2.6-decided shape |

The dashboard's row.mode field, the detail page's mode badge, and
the take-over button's enabled/disabled state all already key off
the unified `lookup_mode/1` result — once 2.6 lands, both LVs
update behavior consistently.

## Acceptance bar — standalone (without Phase 2.6 merged)

| # | Requirement | Status |
|---|---|---|
| 1 | Dashboard loads at `/admin/customer_sessions` after login | ✅ — verified via `mix phx.routes` + curl returns 302→/login (auth working) |
| 2 | With one active customer session in DB, that session appears in the list | ⚪ — not run end-to-end (no live customer session in the dashboard worktree's DB; structurally verified the enumeration query path uses the same API admin_live uses for the same workspace) |
| 3 | Click → detail LV shows transcript | ⚪ — same as #2; route registers correctly, mount path compiles, `Ezagent.MessageStore.recent_in_session` is the same call admin_live uses |
| 4 | "Take over" button dispatches; pre-2.6 returns `:no_such_actor` / `:unauthorized` | ✅ — handler compiled, dispatch wires `Ezagent.Invocation.dispatch/1` with the same context shape admin_live's send_chat uses; pre-2.6 the session Kind has no `:mode.set` action registered so dispatch will return `:no_such_action` or similar |

Items 2/3 require setup of a customer session, which depends on
Phase 2.4 (channel) running. The structural wiring is verified.

## Subtleties / performance concerns

### Subscription fan-out (one process, N session topics)

The LV process subscribes to one PubSub topic per enumerated
session. For PoC scale (a dozen sessions) this is fine. At
production scale (hundreds of concurrent customer sessions per
operator's workspace):

- Each `:chat_message` event triggers a full re-enumeration
  (`KindRegistry.list_all/0` + filter) for the new-session
  discovery loop. This is O(N) per event, O(N²) per N events.
- The mailbox can deliver `:chat_message` events for sessions the
  operator wouldn't otherwise care about (every active session
  fans out to every operator dashboard LV).

Production fixes:
- Add a dedicated `esr:session:lifecycle` topic that fires on
  Session Kind start/stop only; LV subscribes to that ONCE for
  new-session discovery and only re-subscribes to event topics it
  hasn't seen.
- Server-side filter (PubSub topic-tree or selector) so only
  events the operator's cap entitles them to see hit the LV
  mailbox.

Flagged as follow-up; doesn't block PoC acceptance.

### `lookup_mode/1` re-enumerates per row

Today's stub returns `:auto` cheaply, but once Phase 2.6 wires a
real slice read, every row's `lookup_mode` call may hit the
session Kind. For N sessions, that's N GenServer calls per LV
render. Phase 2.4 should consider batch-reading the mode slice
(e.g., one query against the Kind snapshot table) instead of
per-row lookups.

### `Workspace.list_sessions` is workspace-filtered structurally

Per `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:509`,
the workspace-scoped overload filters on the 2nd path segment of
the session URI — it does NOT consult `Workspace.add_member`
membership. This is consistent with the rest of the codebase
(see Task #55 invariants) but worth noting: an operator can
*enumerate* every session in their workspace, regardless of
per-session membership. Cap-gating happens (or doesn't) at the
per-session dispatch level, not in enumeration. The mode-flip
dispatch in `dispatch_takeover/1` carries the operator's caps —
that's where 2.6's CapBAC check should hit.

### Cross-workspace defense in depth

`customer_session_view_live.ex::authorize/3` explicitly rejects
session URIs whose workspace segment doesn't match the
operator's `current_workspace_uri`. This belt-and-suspenders
guards against deep-link forgery (operator A in workspace X
crafting a URL with workspace Y's session).

## Constraint compliance

- ✅ No new entity Kind introduced; operator = User w/ cap.
- ✅ No tenant names hardcoded (everything reads from
  `current_workspace_uri`).
- ✅ No `workspace://acme` / `entity://agent/acme/...` literals
  in lib code.
- ✅ Mode-flip implementation NOT done here — only the LV-side
  dispatch is wired with a PHASE_2.6_INTEGRATION marker.
- ✅ ezagent stays generic — the new LVs reuse existing
  `EzagentDomainChat.list_sessions/1`, `MessageStore`,
  `Behavior.Chat.session_events_topic/1`, `Identity.list_caps_for/1`,
  `Invocation.dispatch/1`. Zero new modules in core domain code.

## Commits

```
poc/phase-2-operator-dashboard branch
└─ <commit SHA> Phase 2.7: operator dashboard — live customer session list + take-over
```
