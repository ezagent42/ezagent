# Socialware as the unified session-app substrate — design

**Date:** 2026-06-09 · **Status:** design (brainstormed to convergence with Allen) · **Tracking:** task #46

## 1. Goal & thesis

Make **socialware the single substrate for every session-app in ezagent** — chat, the AI-page/customer app, advisor, and future apps. The thesis (Allen): *chat is just a special socialware*. Concretely:

> An **app** = a **dependency-closed behavior set** + **view(s)** (an internal LiveView render and/or an external standalone SPA render) + **routing**. A running **instance of an app = a session**. **Verticals = Templates.** There is **one session Kind**; what makes an app distinct is *which behaviors it composes + which view(s) it declares*.

Success = chat, the page/customer app, advisor, and Feishu mirroring all run on this one substrate, and a customer-SPA interaction is the *same shape* as a chat interaction (both are views over a session's event trunk). **The final acceptance gate is E2E**: every existing scenario must still pass on the new implementation (§7).

## 2. Background — what already exists (grounded in code)

The substrate is ~90% present; this design *promotes and generalizes existing elements*, it does not invent a parallel stack.

- **Kind contract** — `Ezagent.Kind` behaviour: `type_name/0`, `behaviors/0`, `persistence/0`, `supervisor/0`. A Kind composes a list of Behaviors; each Behavior owns a state slice (`use Ezagent.Lifecycle, state_slice: :x`).
- **Behaviors compose slices, with declared cross-slice reads** — `reads_siblings/0`. E.g. `Behavior.Turn.reads_siblings == [:surface]` (Turn depends on Surface); `Behavior.Chat` reads `[:sandbox]`. So composition is **not free à-la-carte**: a valid behavior set is **closed under `reads_siblings`**.
- **Two session Kinds today** (the only ones): `Ezagent.Entity.Session` (chat) = `[Chat, Publisher.SessionImpl, ExternalMirror]`; `Ezagent.Entity.SocialwareSession` = `[Chat, Turn, Surface, ConfigUpdate]`. Both are `@behaviour Ezagent.Kind`, `type_name :session`. They differ only in behavior list + supervisor.
- **Verticals are already Templates** — `EzagentPluginAdvisor.Template.AdvisorSession` is a `Kind.Template` that `Kind.spawn(SocialwareSession, …)` + annotates advisor config. There is **no** AdvisorSession Kind. Advisor is the first demo socialware vertical.
- **The trunk already exists: `Ezagent.Behavior.Publisher`** — a per-session ordered event stream with **cursor + history + replay** (`subscribe_from(pid, cursor)`; `:earliest`/`:latest`/integer; cursor lives in the `:publisher` slice → survives snapshot restore). `Publisher.Event = {cursor, publisher_uri, slice_key, event_at, payload}`. **Today only `ExternalMirror` consumes it, and it is only on the chat `Session`, not `SocialwareSession`.**
- **Two divergent outbound pipelines today** (the thing to unify):
  - customer SPA: `Settlement → PubSub :customer_delivery → CustomerFeed` (visibility-gated snapshot of approved surface + committed `customer_visible` messages) + `CustomerChannel` + `customer_app.js` (React/json-render).
  - Feishu: `Publisher event stream → ExternalMirror worker → adapter.publish`.
- **Internal view** = `SessionViewRegistry` of `Ezagent.UI.SessionView` components (conversation/page/pty/routing/external_mirror), rendered in the operator `AdminLive`; reads slices directly + ad-hoc PubSub topics.
- **Durable state** — `kind_snapshots[session_uri]` = one row: serialized slice state + version + workspace + kind_type. `MessageStore` = durable messages (per `(message_id, session_uri)` routing rows).
- **Routing** — `RoutingRegistry` + rules (`{:from, uri}` matchers → receivers): **in-session message delivery + agent orchestration**. Orthogonal to the internal/external view fork.

## 3. Core model (converged)

### 3.1 One session Kind; behaviors composed per app/template

A single session Kind whose **behavior set is supplied by the app/template**, not hardcoded per Kind module. The engine **resolves the dependency closure** over `reads_siblings` and **fails loudly** (let-it-crash) if the declared set is not closed (missing a required sibling slice) — no silent defaulting.

- chat-app = `{Chat, Publisher, ExternalAdapter(...)}` + internal view (+ optionally an external SPA view).
- page-app = `{Chat, Turn, Surface, Publisher, ConfigUpdate}` + internal view + external SPA view.
- A behavior is an orthogonal capability with declared slice deps; an app picks a closed subset.

### 3.2 The trunk = `Behavior.Publisher`, elevated to a base behavior

Promote `Publisher` to a **base behavior every session composes** (today it is only on chat `Session`). It becomes **the canonical session event spine** — the "full event log" (live stream + bounded history; deep replay backed by the durable stores `kind_snapshots` + `MessageStore`).

- **Internal view** = a **direct consumer of the trunk** (subscribe from `:earliest` for the full log / `:latest` for live), full fidelity.
- **External views** = **ExternalAdapters** (§3.3).

### 3.3 ExternalAdapter — the unified outbound projection (the internal/external fork)

The **fork between internal and external views is the ExternalAdapter, not routing.** An `ExternalAdapter` = `subscribe(trunk) → visibility-filter → render-to-surface`. It **generalizes `ExternalMirror` and folds in `CustomerFeed`** (the "externalmirror + feed unification" Allen described):

- **browser/json-render adapter** = today's `CustomerFeed` + `CustomerChannel` + `customer_app.js`, recast as an adapter (filter = `customer_visible` + approved-surface; render = `customer_tree` json-render over a Phoenix Channel). **Migrated off the Settlement broadcast onto the Publisher trunk.**
- **Feishu adapter** = today's `ExternalMirror` + Feishu adapter (filter + Feishu format).
- Future surfaces (Slack, email, …) = additional adapters. No new pipeline each time.

Routing stays an **orthogonal axis** (in-session message delivery + orchestration), unchanged by this design.

### 3.4 View contract (one declaration point, two render targets — option A)

One **View** declaration per app, declaring an **internal render** (LiveView `Phoenix.Component`, as today's `SessionView`) and/or an **external render** (a `customer_tree`/json-render projection consumed by the SPA via an ExternalAdapter). An app may be internal-only (chat today), external-only, or both (socialware). The two render *targets* live behind one registration contract. (Maximal future collapse — making the internal LV render the *same json-render tree* the SPA renders — is explicitly deferred; see §9.)

## 4. Components

| Unit | Responsibility | Interface | Depends on |
|---|---|---|---|
| Unified session Kind | The one `type_name :session` Kind; behavior set supplied per app/template | `Kind.spawn(SessionKind, %{uri, behaviors|template})` | behavior-closure resolver |
| Behavior-closure resolver | Validate a behavior set is closed under `reads_siblings`; fail loud otherwise | pure fn over behavior modules | `reads_siblings/0` |
| `Behavior.Publisher` (base, trunk) | Per-session cursor event stream; the canonical spine | `subscribe_from/3`, `Event` | slices, snapshot |
| `Behavior.ExternalAdapter` (generalized) | `subscribe(trunk) → visibility-filter → render-to-surface`; one per external surface | adapter behaviour callbacks | trunk, visibility model |
| browser/json-render adapter | customer SPA feed (filter + json-render over Channel) | Channel + snapshot | ExternalAdapter, Surface |
| Feishu adapter | Feishu mirror | adapter callbacks | ExternalAdapter |
| View contract | per-app internal-LV and/or external-SPA render declaration | `SessionView`-superset | SessionViewRegistry |
| Templates (verticals) | advisor / chat-app / page-app = behavior set + view + routing config | `Kind.Template` | Kind, View |
| `RoutingRegistry` (unchanged) | in-session delivery + orchestration (orthogonal) | rules | — |

## 5. Data flow

```
event (message / slice change / member event)
        │
        ▼
   trunk = Behavior.Publisher (cursor, history, replay)   ◄── durable: kind_snapshots[uri] + MessageStore
        │
   ┌────┴───────────────────────────────┐
   ▼                                     ▼
internal view (direct consumer,      ExternalAdapter(s) (subscribe trunk)
 full log; operator LiveView)             │ visibility-filter
                                          ▼ render-to-surface
                                   browser SPA (json-render/Channel) · Feishu · …
```

Routing operates *before/around* this — deciding which in-session members/agents receive a message — and is orthogonal to the trunk→view fan-out.

## 6. Migration phases (each independently shippable + E2E-gated)

Ordered by dependency + risk. **No phase merges unless §7 E2E acceptance is green.** Each is a behavior-preserving step for existing scenarios.

- **P0 — Publisher as base behavior.** Add `Publisher` to `SocialwareSession` (and ensure every session composes it). No consumer change yet. Gate: chat + socialware + Feishu scenarios unchanged.
- **P1 — Behavior-closure resolver.** Introduce per-app behavior composition + the `reads_siblings` closure validation (fail-loud). Keep the two Kind modules but route their `behaviors/0` through the resolver. Gate: invalid composition fails loudly in a test; valid sets unchanged at runtime.
- **P2 — Unified View contract.** Extend the View contract to declare internal-LV and/or external render targets; register existing views through it. Gate: operator AdminLive renders all current views identically.
- **P3 — ExternalAdapter (generalize ExternalMirror + fold CustomerFeed).** Define `Behavior.ExternalAdapter`; reimplement the Feishu mirror + the customer feed as adapters subscribing the **Publisher trunk** (customer feed moves off the Settlement broadcast; visibility-gate becomes the adapter filter). Gate: Feishu mirror E2E + customer SPA render/deny E2E both green on the new path.
- **P4 — chat external SPA view.** Give chat an external SPA view = a `customer_tree`/json-render projection of the chat slice, served by the browser adapter. Gate: a chat session is viewable via the external SPA with the same auth/visibility model; chat operator view unchanged.
- **P5 — collapse to one session Kind.** Merge `Session` + `SocialwareSession` into the single parameterized Kind; chat + page + advisor become Templates over it. Gate: all scenarios green; only Templates differ. (Highest risk — do last, may stay deferred if E2E risk is high.)
- **#44 overlap — wire-schema regularization.** Standardize `Publisher.Event` + `Message` + slice snapshot wire form (versioned). Folds the protocol-thin-formalization task into this substrate (one trunk to regularize).

## 7. Acceptance & testing — **E2E is the final gate** (Allen, 2026-06-09)

This change touches the **core session/chat mechanism**, so unit/integration green is necessary but **not sufficient**. The merge gate for **every phase** is: **all existing scenarios still pass E2E on the new implementation.** Regression set:

- **Chat core** — send / receive / join / leave / owner-first-join / cap grants; the cold-restart respawn round-trip; routing `{:from}`→orchestrator relay.
- **Socialware** — the three-phase SW-DEV / SW-USE / SW-UPD scenarios; surface put_version→approve; settlement commit; customer-visibility gating (operator_only never leaks).
- **External adapters** — Feishu mirror (slice change → adapter publish); customer SPA **agent-browser visual E2E** (authenticated render of the json-render page + chat; unauthorized/cross-scope → denied) — the §36 standard, on an **isolated disposable seeded stack** (own ports, Tailscale `100.64.0.27`, never shared dev `:10042`/prod).
- **Orchestrator** — member-template regenerate / managed-member spawn (scenario-34 class).

Per-phase: run the affected suites + the arch fitness gates (`arch.scan`, `check_invariants`, `.lifecycle`, `--warnings-as-errors`) AND the relevant E2E from the set above before merge. The **whole-substrate final acceptance** = the full scenario set green via E2E on the unified implementation. Every distinct E2E bug earns a fast regression test before the fix lands.

## 8. Risks & mitigations

- **Touching core chat** → phase incrementally; each phase behavior-preserving + E2E-gated (§7); P5 (Kind collapse) last and optional.
- **Behavior dependency closure** → fail-loud resolver + a closure invariant test; no silent slice defaulting (let-it-crash).
- **Customer feed re-platforming (Settlement → Publisher)** → P3 keeps the same visibility filter + the same Channel contract; E2E (render + deny) is the gate; can ship behind a flag if needed.
- **Publisher history is retention-bounded** → deep replay reads the durable stores (`kind_snapshots` + `MessageStore`); the trunk is live + bounded-history, not the system of record.
- **Codex-review every phase** (spec + each PR) per project policy.

## 9. YAGNI / deferred

- **Maximal view collapse** (internal LV rendering the *same* json-render tree as the SPA — "one tree, two renderers") — deferred; P2 keeps internal LV + external render as two targets under one contract.
- **Federation / event signing / causal DAG / state resolution** — out of scope (per #44); `workspace://` is the future server-authority seam.
- **shadcn-ui** component layer — optional follow-up over the daisyUI styling already shipped.
- **P5 (Kind collapse)** may remain deferred if its E2E risk outweighs the conceptual-purity benefit; the substrate is fully usable at P4.

## 10. Relationship to other tasks

- **#44 (protocol thin-formalization)** is **subsumed** here: the trunk (Publisher.Event) + Message + slice snapshot become the one wire form to version. #44 stays the "regularize the contract" slice of this substrate work.
- **#36 / #45 (customer SPA)** are the first external-adapter + view consumers; this design generalizes them.
