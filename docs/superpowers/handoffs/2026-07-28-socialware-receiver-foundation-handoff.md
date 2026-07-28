# socialware-receiver (P-α) — implementation handoff

**Feature name:** `socialware-receiver` (was "P-α"). It is the **inbound / receiver half**
of the socialware render substrate — the symmetric counterpart to the existing outbound
render (session state → json-render → page). Outbound already works; this adds the missing
inbound path (page → structured submit → session).

**Implementer:** jjkysy (owns the kanban socialware; receiver is the substrate half both
kanban and hello consume). **Coordinator:** cc. **Reviewer gate:** codex (mandatory,
pre-impl — see the bottom section; it touches the Cap axis).

**Origin:** surfaced while adjudicating **PR #1267** (a stale 2026-07-09 "live-pages
connection layer" proposal doc). #1267 was closed as superseded (its live-data/board/官网
slice shipped the opposite way via the Hello–Kanban fusion line), but ONE slice — in-page
structured input on socialware pages — was tracked nowhere else. It was salvaged as "P-α",
then grilled with Allen (2026-07-28, grill-me-with-doc) and grew into this socialware
foundation.

**Framing — this is a PROTOCOL, not a feature (Allen's LSP / ACP analogy).** Design it the
way LSP (Language Server Protocol) / ACP is designed:
- The **session is the bus**; every interaction is a **typed message** (`event_type`) — like
  LSP's JSON-RPC methods (`textDocument/didOpen`).
- A **socialware is a protocol participant ("server")**: it DEFINES its typed events
  (`kanban:new_task`), IMPLEMENTS their handlers (backend), and REGISTERS their renderers
  (client) — like a language server declaring capabilities + methods, and the client
  rendering per method.
- The **core (ezagent) provides the GENERIC protocol machinery only** — the typed-message
  envelope (`event_type` on Message = **F1**), dispatch/routing (the session message
  pipeline), the registration seams (`SessionViewRegistry` for renderers = **F2**; the cap
  mechanism for authz), and the transport endpoints (**F3** receiver = inbound; **F0** EM =
  outbound). Core hardcodes NO socialware-specific type — exactly like LSP core knows no
  specific language.
- **Design consequences (borrow LSP's precedents):** (a) the `event_type` namespace is OPEN +
  versionable (like method names); (b) a socialware declares what it handles + renders
  (capability negotiation); (c) generic client dispatch by type WITH a graceful fallback (the
  `registry[type] || __unknown` fallback already exists); (d) forward-compat — an unknown
  `event_type` degrades gracefully (like an LSP client ignoring an unknown notification),
  never crashes. **This is why the foundation unifies hello/kanban/autoservice:** they become
  protocol participants speaking ONE typed-message protocol, instead of three bespoke apps —
  which is exactly the inconsistency Allen flagged.

---

## The X problem (what this solves)

> **Socialware-generated pages are today "read-only broadcast": a visitor can SEE the
> rendered page but cannot submit structured data back into the session from it.** The
> missing piece is a *receiver* — one safe channel that takes a structured submission made
> ON a committed page and routes it into the session.

Concrete scenarios (all impossible today, enabled by the receiver):
1. **AutoService landing-page intake.** Today a customer can only type free text in the
   chat composer ("我要装空调"). With the receiver: fill a structured form on the page —
   service type (dropdown: install/repair/clean), address, contact, preferred time — and
   submit once; the session receives a **routable, kanban-able, assignable 需求单**, not a
   blob of text.
2. **Kanban socialware claim / new-card.** A visitor clicks "claim" or fills a "new task"
   form on the board page → becomes a typed session event that flows through kanban
   (today the board is view-only).
3. **官网 booking form.** time + need → submit → session → agent handles.

Why it touches the **Cap axis**: these submissions come from anonymous / semi-trusted
external visitors, so the receiver must be **structurally fail-closed** — an exact
`session.page_action` cap (never `:send`), server-derived caller, `page_version` replay
guard, catalog-controlled inputs only (no raw HTML). That is D3/D4/D5 below.

---

## Why a substrate, not an SPA — foundational rationale (grilled with Allen 2026-07-28)

An SPA is *itself* a substrate — just the wrong one for this product. The question is not
"substrate vs none," it is **which substrate**. A socialware surface has four properties an
SPA-substrate does not provide, and which every surface would otherwise have to rebuild:

1. **UI is generated catalog-component data, not hand-coded.** The surface is a versioned
   json-render/shadcn tree generated from session state (`catalog_jsonrender.mjs` uses
   `shadcnComponentDefinitions`). kanban/hello/autoservice get their UI by *generating a
   surface*, not by writing a frontend. (This is also *why* D5 holds — even inputs are
   catalog components, so raw model-authored HTML stays fail-closed.)
2. **The backend is a live, multi-party, agent-inhabited session that is itself the
   coordination kernel.** State changes without the viewer acting (agents move
   autonomously); multiple socialwares *compose on and coordinate through* one session (one
   Kind, composable behaviors). An SPA = each app an island with a stateless API; there is
   no shared coordination kernel.
3. **Authorization REUSES the one backend cap mechanism — the receiver invents no auth of
   its own** (Allen's decisive point). A visitor is a member holding exact caps;
   `page_action` dispatches through the *same* CapBAC that gates every other backend action.
   An SPA = each app reinvents auth (JWT + per-endpoint checks) = each app a fresh
   #189-class hole.
4. **An interaction is a typed message dropped into the session, not a REST mutation.** The
   submission enters the same routing / turn / delivery pipeline as a chat message, so
   agents react to it and it re-renders via the existing path.

**One line:** a socialware is not "a page + an API" — it is a *view onto a live,
agent-inhabited, multi-party session* whose UI is generated data, whose authz reuses the
backend's single cap mechanism, and whose every interaction is a typed session message. The
substrate provides session-hood, generated rendering, the one cap mechanism, and event
routing **once**; every socialware (and this receiver) is a thin composition that invents
none of them. **The receiver is therefore not a new subsystem — it is the missing inbound
half, reusing all four.**

---

## cc review of the codex draft (my revisions)

I reviewed codex's draft against **current origin/main** and **agree with all five
decisions** — the layering (D1: web transport → `PageActionIngress` (socialware) →
`session.page_action` (session), explicitly NOT ExternalMirror), the substrate-primitive
call (D2), the fail-closed dedicated cap (D3), the typed page-version-checked envelope
(D4), and — the sharp one — keeping the raw-HTML sanitizer strict while enabling only
catalog-controlled json-render inputs (D5). Refinements / confirmations:

- **json-render is really landed** — `@json-render/{core,react,shadcn}` 0.19.0 are real
  deps (web/hello/world); `catalog_jsonrender.mjs` uses the real Vercel engine + shadcn
  registry (36 components). The gap is purely the unused `actions: {}` — the receiver
  wires the inbound half, not a new renderer.
- **Line-number re-anchor:** the codex draft was read at a stale checkout with uncommitted
  changes. On current main the participation tiers are:
  `@member_chat_actions [:send, :leave, :attach]` and
  `@member_publisher_actions [:subscribe_from]` at
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:532-533`, granted
  AFTER a successful join by `mount_participation_caps/2`. The new
  `@member_interaction_actions [:page_action]` tier slots in exactly there. **Re-resolve
  every other file:line the draft cites before implementing** (they exist on main —
  verified — but line numbers drift).
- **D3 OVERRIDE — anon is BROWSE-ONLY; interaction triggers login (Allen 2026-07-28, verified
  against main).** codex's draft (grant `page_action` to unconfirmed/anon) is WRONG. The
  established substrate model, confirmed in code:
  - An anonymous visitor is a persistent, cookie-bound, **unconfirmed** User entity
    (`Ezagent.Users.create_read_only/2`, `confirmed: false`; `apps/ezagent_domain_identity/lib/ezagent/users.ex`).
  - `mount_participation_caps/2` picks the tier from `Users.confirmed?/1`: **unconfirmed →
    `:subscribe_from` only (read/browse), NO `:send`**; confirmed → `[:send, :leave, :attach]`
    + `:subscribe_from` (`.../session/membership.ex:532-533, 1101-1116`).
  - Therefore **`page_action` belongs in the CONFIRMED tier alongside `:send`, NOT the
    unconfirmed tier.** An anon browses; the moment they try to interact (submit a form),
    the frontend triggers the existing **login/confirm** flow (registration confirm), and
    only the now-confirmed member holds `page_action`.
  - Prior anon content/membership carries onto the logged-in user via the EXISTING
    `apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex` — the receiver REUSES this;
    it does not build carryover.
  - Net: the receiver adds `page_action` to `@member_chat_actions` (the confirmed tier), and
    otherwise reuses anon-admission (browse) + registration-confirm (login) + anon_takeover
    (carryover) unchanged. This is stricter and fully fail-closed: there is NO anonymous
    submit surface. Update D3 in the codex doc below accordingly (its "confirmed or
    unconfirmed" grant is superseded by this override).
- **D1 constraint — the web/transport layer only DISPATCHES; it must never reach into
  Kind/pid (2026-07-28 audit, Allen's reflection).** Audited the existing anon machinery for
  the pre-actor-isolation anti-pattern (business/transport poking Kind/pid/registry
  directly). Result: the DOMAIN core is clean — `AnonAdmission`, `AnonTakeover`, and the
  channel go through the sanctioned seam (`Ezagent.Entity.spawn_principal/1` + a named
  `Invocation.dispatch`; ZERO direct pid/registry). The ONE residual leak is in the web
  shim: `EzagentWeb.Socialware.AnonIngress` calls `Ezagent.SpawnRegistry.ensure_live/1`
  directly (`anon_ingress.ex:61`) to wake the session — a benign "wake" call, but exactly
  the transport-pokes-Kind-lifecycle pattern actor-isolation eliminates. **The receiver must
  NOT copy it:** `handle_in("page_action")` calls only `PageActionIngress.submit/3`, which
  dispatches via `Invocation.dispatch` — and dispatch already force-activates a cold session
  Kind through the sanctioned path. No `SpawnRegistry`/pid/registry access anywhere in the
  web or ingress layer. (The separation into layers is correct; the leak is a web-layer
  shortcut, not a consequence of separating — the fix is discipline, not merging layers.)
  **Follow-up (not P-α):** route `AnonIngress`'s `ensure_live` through the seam as part of
  the v5 / actor-isolation (B) track.
- **D4 refinement — `event_type` on Message is SOCIALWARE-DEFINED (open namespace) + a
  socialware-registered renderer (Allen 2026-07-28).** codex's narrow "widen `body_shape` to
  carry a page_action map" is superseded. Allen's model, and what's verified on main:
  - **Add `event_type` to `Ezagent.Message`** — confirmed ABSENT today (`body_shape =
    %{text, attachments}`; fields id/session_uri/session_seq/workspace_uri/sender/mentions/
    body). It is an **OPEN, socialware-namespaced string** (e.g. `kanban:new_task`,
    `autoservice:service_request`), **NOT a fixed system enum** — ezagent core provides only
    the field + a backward-compatible default (`:chat`/`:message`); each socialware DEFINES
    its own event types. Backend treats all events uniformly (a message differentiated by
    `event_type`); the UI decides whether/how to render each.
  - **The socialware registers a UI renderer for its event_type(s)** — and two of the three
    pieces ALREADY EXIST: (i) `Ezagent.UI.SessionViewRegistry.register/1` is the existing
    socialware→UI registration seam (hello uses it: `application.ex:44`
    `SessionViewRegistry.register(EzagentPluginHello.PageView)`); (ii) the frontend already
    has a render-dispatch-**by-type** pattern — `catalog_render.mjs:30`:
    `registry[type] || registry.__unknown`. What's MISSING and new: `event_type` on Message
    (above) and wiring **per-message-event_type → the socialware-registered renderer** (today
    chat messages render uniformly; the registry keys on json-render NODE types, not on a
    message's event_type). So this is an EXTENSION connecting existing pieces, not a
    from-scratch build. Example: kanban defines `kanban:new_task` and registers a component
    that renders it as a task card inline in the session chat.
  - **The receiver's page_action maps to a socialware event_type:** the committed page's
    action binding (its `action_id`) resolves to the owning socialware's `event_type`; the
    receiver emits a Message with that `event_type` + structured payload; the socialware's
    registered renderer draws it. So `page_action` is the inbound TRANSPORT; the Message that
    lands carries a socialware-owned `event_type`, not a generic `:page_action`.
  - CORE change (Message schema + migration + delivery + the render-dispatch wiring) —
    additive/backward-compatible, but **codex-review as a core change**. Keep codex's D4
    page_version-match + idempotency + no-atomizing-user-input rules unchanged.
- **SCOPE EXPANSION → this is a socialware FOUNDATION, not just a receiver (Allen
  2026-07-28).** The grill established that hello/kanban/autoservice look inconsistent
  *because* this foundation doesn't exist. So F3 (the receiver) sits on a foundation that
  ships with it, in order:
  - **F1 — typed message:** `event_type` on `Ezagent.Message` (open socialware namespace;
    see the D4 refinement).
  - **F2 — event-renderer registration:** socialware registers a per-`event_type` UI renderer
    (extend `Ezagent.UI.SessionViewRegistry` + the `registry[type]` render dispatch; see D4).
  - **F0 — External-adapter (EM) per-event_type delivery policy:** EM today publishes on ANY
    `last_message` change — `chat_send_occurred?` returns true for any non-nil last_message
    (`external_mirror_worker.ex:201`), with NO type discrimination — so a typed event
    (`kanban:new_task` / page_action) would be **blindly delivered to Feishu**. The
    foundation MUST add a per-`event_type` external-delivery policy: default `:chat` delivers
    as today; typed events declare deliver-as-text-projection / structured / **skip**. EM's
    publish flow already has a `:skip` result — `event_type` just feeds that decision.
    **Coordinate this EM change with the v5/B track** (② EM authz lives on
    `feat/v5-use-side-mailbox`).
  - **F3 — receiver:** the inbound `page_action` path, on top of F1/F2.
  - **Recommendation:** run this as a proper foundation spec (brainstorm → spec → codex),
    implement F1/F2 (+ F0) before F3. This is bigger than a single handoff. (Allen: jjkysy
    owns the foundation spec; this handoff gives the direction.)
- **Grill-resolved tactical decisions (2026-07-28):**
  - **D4 page_version mismatch → REJECT (optimistic concurrency), not auto-merge.** Same
    pattern SPAs use (version/etag → 409-conflict). Our LIVE feed makes it near-free: the
    visitor's page auto-refreshes via the subscription, so a mismatch is a rare race — on
    mismatch, reject and the existing live-refresh pushes the fresh surface; the user
    resubmits. Auto-convert/merge is over-complex for v1 and unnecessary; defer unless a real
    merge case appears.
  - **D5 input whitelist = the CATALOG is the safe set; devs compose freely within it.** The
    input types are json-render/shadcn catalog components; the platform curates which are in
    the catalog + safe (`Input.type ∈ {text,email,tel}`; NO password/file) because the
    catalog is the sanitizer/security boundary — not a UX restriction. A new safe input is a
    reviewed catalog addition; devs have full freedom inside the curated set.
  - **Scope: file upload IS in — via the EXISTING cap-authed upload flow**
    (`uploads_controller` / `world_uploads_controller` + `UploadToken` signed-cap +
    `/uploads/download?token=`), driven by a catalog "upload" component that references the
    upload URI in the page_action payload. NOT a raw `<input type=file>` (stays stripped by
    D5). **Cross-session stays OUT** — the receiver targets the page's single session; a
    cross-session FORWARD (copy+ref: a NEW copy in the target session — message.ex:136 /
    message_store.ex:82) exists Session-side if ever needed.
  - **No separate `action_id`; the page action binding names the socialware `event_type`
    directly** (Allen's model collapses codex's action_id→event_type mapping into one). The
    receiver validates the named event_type is a real binding on the committed page, then
    emits a Message carrying that event_type.
- **Naming:** use `socialware-receiver` for the feature and `session.page_action` for the
  action; keep the wire event `"page_action"`. Don't overload "hello".

The full decision doc from codex follows verbatim (with the naming/anchors above taking
precedence where they differ).

---

# DIRECTIONAL DECISION HANDOFF — P-α

**Implementer:** jjkysy  
**Feature:** Structured interaction from generated socialware pages  
**Status:** Direction decided; implementation requires Cap review  
**Evidence baseline:** Read-only review of the current shared checkout at `548368f42af5`. Relevant files contain uncommitted changes, so re-resolve line numbers after rebasing. No files were changed during this review.

## Decision summary

| Item | Decision |
|---|---|
| D1 | Put ingress in the shared socialware substrate: Phoenix transport → `PageActionIngress` → Session action. |
| D2 | `structured-input ingress` is a substrate primitive, not a new app. |
| D3 | Authorize with one exact `session.page_action` capability granted after membership admission; never reuse `session.send`. |
| D4 | Standardize one typed envelope across json-render, channel, Session, Message, and agent delivery. |
| D5 | Keep raw model-authored HTML forms stripped. Enable only catalog-controlled json-render inputs and actions. |

## Problem and pipeline model

The existing outbound half is complete:

```text
session/handler → Turn → immutable Surface version → committed ExternalFeed
→ SessionFeedChannel snapshot → json-render/shadcn page
```

Hello’s `TurnDriver` already opens, composes, settles, and publishes a Surface version; `ExternalFeed` renders the committed version, and the external feed adapter wakes the channel on chat or external-delivery events. [TurnDriver](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/turn_driver.ex:7), [ExternalFeed](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:50), [live topics](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed_adapter.ex:89)

P-α adds the symmetric inbound half:

```text
json-render state + pageAction
→ channel "page_action"
→ authorize caller and exact capability
→ session.page_action
→ normal Session message routing
→ hello/kanban handler
→ existing Turn/Surface publication
→ refreshed page
```

Today both real catalogs declare no actions, the server spec validates only component types/children, and the channel accepts only `post`, `join`, and `history`. [hello catalog](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/assets/src/catalog.ts:16), [external catalog](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs:20), [Spec validation](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex:107), [channel ingress](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:41)

## D1 — Back-half ingress ownership

**RECOMMENDATION: choose (a), with ownership split by tier.**

- `EzagentWeb.Socialware.SessionFeedChannel` owns only the Phoenix `"page_action"` transport entry.
- New `Ezagent.Socialware.PageActionIngress` in `ezagent_domain_socialware` owns envelope validation against the externally visible page, exact-cap selection, and dispatch.
- `Ezagent.ActionSet.Session.page_action` in `ezagent_domain_session` owns acceptance into session content/routing.
- `AnonIngress` remains the HTTP/cookie identity shim; it should not gain business-action logic.

**Concrete code seam**

1. Add `handle_in("page_action", params, socket)` beside the three current channel handlers. It calls:

   ```elixir
   PageActionIngress.submit(
     socket.assigns.session_uri,
     socket.assigns.caller,
     params
   )
   ```

2. Add:

   ```text
   apps/ezagent_domain_socialware/lib/ezagent/socialware/page_action_ingress.ex
   apps/ezagent_domain_session/lib/ezagent/session/page_action.ex
   ```

3. Add `action(:page_action, ...)` and `handle_page_action/2` to `Ezagent.ActionSet.Session`.

**Rationale**

`AnonIngress` already deliberately separates web concerns from the domain admission primitive. [AnonIngress boundary](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_web/lib/ezagent_web/socialware/anon_ingress.ex:1) The Session Kind is the common host for socialware behavior, while its socialware subset explicitly excludes `ExternalMirror`. [Session socialware behaviors](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_session/lib/ezagent/entity/session.ex:80)

Do not put page actions on `ExternalMirror.Adapter`. Pull adapters render projections; their contract is external delivery, not session business ingress. [ExternalMirror pull contract](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:82)

Do not copy the channel’s current hello-specific `dispatch_post/3`, which imports `EzagentPluginHello.Members` and targets hello’s front desk. That is existing coupling, not the pattern for P-α. [hello-specific fallback](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:354)

## D2 — Primitive or new app?

**RECOMMENDATION: substrate primitive; no new named OTP app.**

The stable abstraction is:

> A Session receives an authorized, catalog-bound structured interaction originating from one committed socialware page.

Hello and kanban are consumers of that primitive. They own action IDs and business handling, not transport, caller authentication, Cap selection, or envelope parsing.

**Concrete code seam**

- Transport: `ezagent_web`
- Public-page validation and ingress orchestration: `ezagent_domain_socialware`
- Typed event and Session action: `ezagent_domain_session`
- Producer-specific handling: hello/kanban plugin roles

This follows the existing dependency direction: socialware already depends on Session, and web already depends on both. [socialware dependencies](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/mix.exs:36), [web dependencies](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_web/mix.exs:69)

A separate app would not own an independent Kind, durable lifecycle, or transport. Revisit app extraction only if structured ingress later becomes a reusable protocol outside socialware Sessions.

## D3 — Anonymous interaction capability

**RECOMMENDATION: introduce one exact `Session.:page_action` capability in the post-join participation tier. Do not grant or alias `:send`.**

Required capability shape:

```elixir
%Ezagent.Capability{
  kind: :session,
  behavior: Ezagent.ActionSet.Session,
  action: :page_action,
  instance: Ezagent.URI.instance(session_uri),
  workspace_uri: Ezagent.Capability.workspace_of(session_uri),
  grantee_uri: caller
}
```

**Concrete code seam**

1. In `Membership`, add:

   ```elixir
   @member_interaction_actions [:page_action]
   ```

   Include this tier for joined users—confirmed or unconfirmed—while retaining `send/leave/attach` only for confirmed users. The current unconfirmed tier receives only `subscribe_from`; that is the exact extension point. [participation tiers](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1217)

2. Keep the anonymous sequence unchanged:

   ```text
   mint exact join/view authority → spawn → bind → session.join
   → MemberBackfill.mount_participation_caps
   ```

   [AnonAdmission sequence](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_admission.ex:31), [MemberBackfill](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_session/lib/ezagent/socialware/member_backfill.ex:57)

3. In `PageActionIngress`, load the caller’s caps and select only the exact `page_action` cap for this Session, mirroring `AnonAdmission.dispatch_join/2`. Missing authority is a denial, not a fallback. [exact join-cap precedent](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_admission.ex:100)

4. Dispatch with:

   ```elixir
   origin: :authenticated_external,
   ctx: %{caller: caller, caps: MapSet.new([exact_cap]), ...}
   ```

   Never accept `caller`, `caps`, `origin`, target URI, behavior, or action from the browser.

**Rationale**

`ChatFeedAuth` proves which server-derived caller opened the socket; it explicitly is not authorization. [token boundary](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed_auth.ex:12) `DispatchOrigin` then verifies that every presented capability belongs to that caller before normal capability authorization runs. [DispatchOrigin](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_core/lib/ezagent/dispatch_origin.ex:22)

`:trusted_internal` is reserved for reviewed downstream framework code such as the existing Turn driver. It must never be selected by the channel or supplied by the page. [trusted internal example](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/turn_driver.ex:95)

## D4 — Typed `page_action` contract

**RECOMMENDATION: standardize this wire envelope.**

```json
{
  "event_id": "client-generated-idempotency-key",
  "page_version": 17,
  "action_id": "request.submit",
  "payload": {
    "request": "需要现场安装服务",
    "service_source": "官网"
  }
}
```

`session_uri`, caller, receipt time, and authorization context are server-derived. `action_id` is business data, never a dispatch action or URI.

### Front: json-render

**Concrete code seam**

- Declare custom catalog action `pageAction` in both catalogs.
- Do **not** add a bespoke action prop to `Button`.
- Extend `EzagentPluginHello.Spec.validate/1` to validate top-level `on` bindings:
  - `Button.on.press`
  - optional built-in `validateForm`
  - custom `pageAction`
  - bounded static `action_id`
  - payload values resolved from permitted `$state` paths
- Pass `handlers: %{pageAction: callback}` to `JSONUIProvider`.
- Thread the callback through `JsonRenderPage`, `PureThemePage`, and `HybridPage` to `channelRef.current.push("page_action", envelope)`.

The installed 0.19 renderer resolves emitted component events through the node’s top-level `on` map; the existing Button override already emits `"press"`. [Button emission](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs:246), [json-render 0.19 lock](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/assets/pnpm-lock.yaml:11)

Add `surface_version` to the external snapshot because `ExternalFeed` already obtains the committed version but currently returns only the corresponding tree. [version read](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:51)

### Transport and authorization

Add:

```elixir
Ezagent.Session.PageAction.from_wire/1
Ezagent.Socialware.PageActionIngress.submit/3
```

`from_wire/1` must enforce string keys, ID formats, maximum encoded bytes, depth, field count, and scalar/array/map value types without atomizing user input.

`submit/3` must:

1. authorize reading the current external projection;
2. require the submitted `page_version` to match the committed version;
3. traverse that page and verify a `pageAction` binding with the same static `action_id`;
4. load the exact caller-held `session.page_action` cap;
5. dispatch `session.page_action` in `:call` mode;
6. put `event_id` into `Invocation.ctx.idempotency_key`. [idempotency seam](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_core/lib/ezagent/invocation.ex:73)

### Session handler and consumer delivery

Add:

```elixir
action(:page_action,
  args: %{event: :map},
  returns: %{accepted: :boolean, event_id: :string},
  caps: [:page_action],
  modes: [:call]
)
```

`handle_page_action/2` should validate into `%Ezagent.Session.PageAction{}`, then create an ordinary `Ezagent.Message` whose body contains both:

```elixir
%{
  text: "[page_action request.submit]",
  attachments: [],
  page_action: PageAction.to_map(event)
}
```

Factor the persistence/routing core of `handle_send/2` into a private shared function and use it from both actions. That preserves the existing MessageStore, Resolver, delivery, and notification path rather than introducing a second router. [current send pipeline](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:563)

Formally widen `Ezagent.Message.body_shape` for optional structured input. Its database field is already a map, but its declared contract currently names only text and attachments. [Message body](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_core/lib/ezagent/message.ex:58)

Also preserve `page_action` through `Ezagent.AgentBridge.Payload` and `Agent.Delivery`; today delivery extracts only text and attachments and constructs string metadata. Provide a deterministic text projection for text-only flavors, but keep the structured map for kanban/hello handlers. [Agent delivery](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_agent/lib/ezagent/behavior/agent/delivery.ex:50), [Payload shape](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/payload.ex:9)

The Session action must not mutate Surface directly. The selected hello/kanban role consumes the message and uses its existing Turn/Surface workflow; the external feed’s current subscriptions then push the rerendered snapshot.

## D5 — Sanitizer and controlled forms

**RECOMMENDATION: make no relaxation to the raw HTML sanitizer.**

Keep `form`, `input`, `textarea`, and `select` in `@dangerous_tags`, and keep stripping every inline `on*` handler. The shell is injected with `innerHTML`; it is the wrong authority boundary for executable interaction. [dangerous tags](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/sanitize.ex:21), [event-handler stripping](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/sanitize.ex:102)

For P-α, permit only these catalog-controlled elements:

- `Input` with `type` limited initially to `text`, `email`, or `tel`
- `Textarea`
- `Select` with literal catalog-authored options
- `Button` emitting `press`
- `Stack`/`Card` for grouping; no raw `<form>` is required

These controls already exist in the backend catalog. [controlled inputs](/Users/h2oslabs/Workspace/esr-ng/apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex:63)

The server-side spec validator must reject unknown props, events, action names, arbitrary state paths, duplicate `action_id`s, and dynamic target/action fields. Browser validation is UX; `PageAction.from_wire/1` and `PageActionIngress.submit/3` remain authoritative.

## Scope boundary

**P-α includes**

- One catalog action: `pageAction`
- Text/textarea/select request forms
- External viewer channel transport
- Exact anonymous/member page-action capability
- Current-page action-binding validation
- Idempotent Session ingestion
- Structured delivery to hello and kanban handlers
- Existing Turn/Surface rerender path
- Negative tests for forged caller/cap, wrong session, stale version, unknown action, oversized payload, and raw-HTML forms

**P-α excludes**

- Arbitrary model-authored HTML forms or JavaScript
- File uploads, secrets/password fields, payments, and binary payloads
- Page-provided dispatch targets, behaviors, action atoms, or capabilities
- Turning `ExternalMirror` into an inbound business protocol
- Refactoring the existing hello-specific `"post"` fallback
- Offline queues, cross-session actions, webhooks, and action-specific capability taxonomies
- Internal World-preview submission transport; its catalog must remain compatible, but the visitor-facing external page is the P-α ingress

## Mandatory review gate

> **codex-review-the-spec-before-impl**
>
> P-α changes the Cap axis and creates a new Path-A external ingress. Before implementation, jjkysy must submit the finalized envelope, exact capability issuance/selection logic, page-binding validation, and negative authorization matrix for Codex review. Implementation starts only after that review approves the authority model.
454,972
