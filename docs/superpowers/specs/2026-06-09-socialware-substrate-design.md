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

A single session Kind whose **behavior set is supplied by the app/template**, not hardcoded per Kind module.

**`reads_siblings` is required-vs-optional — NOT a naive fail-loud closure** (codex spec-review HIGH). Today every `reads_siblings` is effectively *optional*: the runtime injects `%{}` for a missing sibling slice (`kind/runtime/context.ex`), which is why `Chat` declares `reads_siblings([:sandbox])` yet both current session Kinds run **without** `Behavior.Sandbox`. A naive "fail if not closed" resolver would break existing chat/socialware. So:

- **P1 reclassifies each sibling read as `:required` or `:optional`.** A *required* read (e.g. `Turn → :surface` — Turn cannot compute versions without it) must have an **owning behavior in the set**; the resolver **fails loud** only on a missing *required* slice. An *optional* read (e.g. today's `Chat → :sandbox`) keeps the **soft `%{}` default** — preserving current behavior. This is a slice-owner mapping + a required-closure check, not "no defaults."
- chat-app = `{Chat, Publisher, ExternalAdapter(...)}` + internal view (+ optionally an external SPA view) — `:sandbox` optional, so no `Sandbox` required.
- page-app = `{Chat, Turn, Surface, Publisher, ConfigUpdate}` + internal view + external SPA view — `Surface` present satisfies Turn's *required* `:surface` read.
- A behavior is an orthogonal capability with declared slice deps; an app picks a **required-closed** subset.

**Per-instance behavior-set runtime contract (load-bearing — codex spec-review HIGH).** Today the runtime is **module-static**: dispatch resolves actions by `{kind_module, action}`, lifecycle init/prune/reconcile/on_ready iterate `Ezagent.Kind.behaviors_of(kind_module)`, slice reads do `Map.get(state, slice_key, %{})`, and cap registration is per Kind-module/action. "One Kind, behaviors per instance" therefore requires the runtime to become **instance-behavior-set-aware**, or the unification breaks the security + state boundary:

- The **instance persists its behavior set** (in the spawn args / template / a base slice), so it survives restart/reconcile.
- **HARD INVARIANT: every behavior enumeration and every behavior callback entry point uses the persisted INSTANCE set, never the module's static list** (codex spec-review — stated as a blanket invariant precisely so no entry point is missed). This covers, at minimum: dispatch (`{kind_module, action}` resolution) + cap registration/check; slice init / prune / reconcile / raw slice access; `create`/`post_init`/`activate`/`activated`/`on_ready`; the mailbox path `Kind.Server.handle_info → behaviors_of → handle_signal/2`; `terminate`/`deactivate`/`destroy` hooks; and any universal-behavior fallback policy. **An out-of-set behavior must never run a callback, process a signal, run a cleanup hook, or create/mutate its slice (from `%{}` or otherwise) — even if the one `SessionKind` module registers a superset.**
- **Required/optional closure is resolved from the instance's set.**

This is the precise contract that makes "chat is just a special socialware" safe: a chat instance (no `Surface`) must be *unable* to dispatch a `Surface` action, init a `:surface` slice, receive a `Surface` signal, or run a `Surface` terminate/destroy hook — even though the single `SessionKind` module knows about `Surface`.

### 3.2 The trunk = `Behavior.Publisher`, elevated to a base behavior

Promote `Publisher` to a **base behavior every session composes** (today it is only on chat `Session`). It becomes the canonical session event **spine**.

**Honest framing of what Publisher is today (codex spec-review): a bounded slice-change SIGNAL, not yet a full-fidelity semantic log.** Its event payload is only `%{new_slice}` (the affected slice), `:action`/`:caller` are no longer in the envelope, and consumers must **dedupe** (ExternalMirror already does — unrelated chat-slice mutations can carry the same `last_message`). History is **retention-bounded**. Therefore:

- The trunk is a **live change-signal**; **consumers JOIN it with the durable stores** (`kind_snapshots[uri]` slice state + `MessageStore`) for content + deep replay. It is NOT the system of record.
- A true full-fidelity **semantic event log** (explicit event types + required metadata, versioned envelope) is the **wire-schema regularization (#44)** — which is therefore **sequenced BEFORE any consumer migration that needs a trustworthy event** (notably the customer-feed move, §6).
- **Internal view** = consumes the trunk as a live signal + reads the durable stores (≈ today's pattern, re-pointed at the trunk for the live wake-up rather than ad-hoc PubSub).
- **External views** = **ExternalAdapters** (§3.3).

### 3.3 ExternalAdapter — the unified outbound projection (the internal/external fork)

The **fork between internal and external views is the ExternalAdapter, not routing.** An `ExternalAdapter` = `subscribe(trunk) → visibility-filter → render-to-surface`. It **generalizes `ExternalMirror` and folds in `CustomerFeed`** (the "externalmirror + feed unification" Allen described):

- **browser/json-render adapter** = today's `CustomerFeed` + `CustomerChannel` + `customer_app.js`, recast as an adapter (render = `customer_tree` json-render over a Phoenix Channel, **from the COMMITTED surface version**, not the live approved `:surface` slice — see P2.5). **CRITICAL — the trigger is the settlement-COMMIT boundary, not just visibility** (codex spec-review HIGH): today `Settlement.commit_after_pointer` confirms the approved pointer, emits the outbox idempotently, marks `status: :committed`, THEN broadcasts `{:customer_delivery, …}`, and the gated query requires BOTH `visibility == :customer_visible` AND `status == "committed"`. A naive move onto the Publisher trunk breaks this: `Surface.handle_commit_settlement` returns **no slice effects**, so there is **no Publisher event after the row is committed** — the adapter would either fire early (leak after `flip_visibility` but before commit) or miss the update until an unrelated later slice change. So the browser adapter **must not drop the committed-status gate + outbox idempotency**, and its durable signal must be **an outbox/committed-rows source written transactionally at the commit boundary, replayed by cursor/id** — the trunk/PubSub event is only an **advisory wake-up** (losing it must not lose the delivery; the adapter catches up on reconnect/next wake-up). See §6 P2.5/P3 for the durable-source + cursor-replay contract.
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
- **P1 — Per-instance behavior set + required-closure resolver + instance-set runtime enforcement.** The load-bearing core (codex). Two coupled pieces:
  1. **Required/optional sibling reads + closure resolver.** Reclassify each `reads_siblings` entry as `:required` or `:optional` (preserving today's soft `%{}` default for optional, e.g. `Chat → :sandbox`); add a slice-owner mapping + a resolver that **fails loud only on a missing *required* sibling**.
  2. **Make the runtime instance-behavior-set-aware** — implement the §3.1 **HARD INVARIANT**: persist the instance's behavior set, and route EVERY behavior enumeration + callback entry point through it (dispatch + caps; slice init/prune/reconcile/raw-access; create/post_init/activate/activated/on_ready; the `handle_info → behaviors_of → handle_signal` mailbox path; terminate/deactivate/destroy; universal-behavior fallback). An out-of-set behavior never runs any callback nor touches its slice, even if the `SessionKind` module registers a superset. This is what lets one Kind carry many apps safely.
  - Keep the two Kind modules for now (they become thin: each = a fixed instance behavior set); route everything through the per-instance path. Gate: the two current sets + the proposed chat/page sets all pass; a deliberately required-broken set fails loud in a test; **denial tests across entry points** — an instance WITHOUT `Surface` (a) cannot dispatch a `Surface` action, (b) does not init/reconcile a `:surface` slice, (c) does not run `Surface`'s `handle_signal` when a matching mailbox message arrives, and (d) does not run `Surface`'s terminate/destroy hook — though the module knows `Surface`; valid sets unchanged at runtime (chat/socialware/Feishu scenarios green).
- **P2 — Unified View contract.** Extend the View contract to declare internal-LV and/or external render targets; register existing views through it. Gate: operator AdminLive renders all current views identically.
- **P2.5 — Wire-schema regularization + a committed customer-delivery trunk event (subsumes #44; MUST precede P3).** Two coupled pieces codex flagged as prerequisites for P3:
  1. **Standardize the event wire form** — versioned `Publisher.Event` (+ `Message`, + slice snapshot) with enough metadata that a consumer can act on it without the current ad-hoc dedupe hacks. (This is the #44 work, pulled earlier because P3 depends on a trustworthy trunk event.)
  2. **Durable commit-signal via an outbox + cursor replay — NOT a best-effort slice-change event** (codex spec-review HIGH, rev3). A Publisher event produced via `SliceChange.emit` is **best-effort**: `SliceChange.emit` returns `:ok` and rescues/logs PubSub failures; Publisher appends its ring *asynchronously* on the PubSub `handle_signal`; the ring-persist in `kind/server.ex` is itself best-effort (catches DB failure, keeps in-memory). So a slice-change event **cannot** be the durable post-commit signal. Instead:
     - **The durable source of truth = an outbox written TRANSACTIONALLY at the settlement commit boundary**, addressable by **cursor/id**, and it must cover **BOTH the committed message ids AND the committed surface version** (codex rev3 HIGH — the leak below). Extend the existing outbox/`status:committed` write.
     - **The customer PAGE must be commit-gated too, not just messages.** Today `CustomerFeed.customer_page/1` renders from the **live `:surface` slice's approved version** (`Surface.customer_tree/1`), but Turn settle dispatches `:approve` **before** `:commit_settlement` — so a reconnect/refetch between those two dispatches exposes the **approved-but-not-committed page**. Fix: render the customer page from the **committed surface version recorded in the outbox/commit** (or advance the customer-visible surface pointer atomically *in* the commit), so `:approve` alone never exposes a page.
     - **Delivery must be post-PARENT-turn-commit, not just post-settlement-commit** (codex rev4 HIGH — a latent ordering bug this refactor must fix, not inherit). Today `Turn.handle_settle` prepares settlement + flips visibility in-handler, then returns `:approve`/`:commit_settlement` as `reply: :ignore` → `:cast` effects, which the Router sends **before** `Kind.Server.commit_and_notify` commits the parent Turn slice. If that parent commit fails (`{:persistence_failed, _}`, old Turn state kept), the already-enqueued Surface casts can still approve + commit the settlement → a **committed customer delivery for a Turn that never durably settled**. Fix: settlement approve/commit (and the outbox write) must run **only after the originating Turn slice durably commits** — a post-snapshot hook that dispatches approve/commit only on parent-commit success, OR make `turn.settle` + settlement-commit one transactional durable unit. (Hardens existing behavior; not purely new substrate work.)
     - **The trunk/PubSub event is only a best-effort WAKE-UP.** Losing it must NOT lose the delivery.
     - **The adapter is replay-from-durable-by-cursor + idempotent**: on wake-up OR on (re)connect it replays committed deliveries (messages + surface version) since its last cursor from the durable source. This generalizes today's `CustomerChannel` "refetch the gated snapshot on signal" — the migration **preserves** that durable-source + advisory-wake-up shape (and *adds* page commit-gating); it does not replace the durable source with the best-effort trunk.
  - Gate: post-commit-only + idempotent + committed-status gated for **both messages and page**; a **wake-up-loss test** (drop the wake-up between commit and delivery → adapter still delivers via durable replay); a **page-leak test** (approve a surface version but block/skip `commit_settlement` → `CustomerFeed.snapshot/2` and the browser adapter expose **neither** the page **nor** the messages); and a **parent-commit-rollback test** (force the originating Turn slice snapshot commit to FAIL after settlement preparation/cast-enqueue → assert **no** committed outbox / page / messages / customer delivery appear).
- **P3 — ExternalAdapter (generalize ExternalMirror + fold CustomerFeed).** Define `Behavior.ExternalAdapter`; reimplement the Feishu mirror + the customer feed as adapters. The customer adapter's **source of truth is the durable committed-delivery outbox from P2.5, replayed by cursor/id** (committed-status gate + outbox idempotency preserved); the trunk event is the advisory wake-up that triggers a replay, never the sole signal. Gate: Feishu mirror E2E + customer SPA render/deny E2E both green on the new path, a **leak test** (no customer_visible data before commit), AND the wake-up-loss test from P2.5.
- **P4 — chat external SPA view.** Give chat an external SPA view = a `customer_tree`/json-render projection of the chat slice, served by the browser adapter. Gate: a chat session is viewable via the external SPA with the same auth/visibility model; chat operator view unchanged.
- **P5 — collapse to one session Kind.** Merge `Session` + `SocialwareSession` into the single parameterized Kind; chat + page + advisor become Templates over it. **Depends on P1's instance-set runtime enforcement** — the collapse is only safe because dispatch/lifecycle/caps are already instance-set-driven (a superset registered on one Kind is harmless because out-of-set actions are denied per-instance). Gate: all scenarios green; the P1 denial test holds on the collapsed Kind; only Templates differ. (Highest risk — do last, may stay deferred if E2E risk is high; the substrate value is delivered by P1–P4 even without P5.)

## 7. Acceptance & testing — **E2E is the final gate** (Allen, 2026-06-09)

This change touches the **core session/chat mechanism**, so unit/integration green is necessary but **not sufficient**. The merge gate for **every phase** is: **all existing scenarios still pass E2E on the new implementation.** Regression set:

- **Chat core** — send / receive / join / leave / owner-first-join / cap grants; the cold-restart respawn round-trip; routing `{:from}`→orchestrator relay.
- **Socialware** — the three-phase SW-DEV / SW-USE / SW-UPD scenarios; surface put_version→approve; settlement commit; customer-visibility gating (operator_only never leaks).
- **External adapters** — Feishu mirror (slice change → adapter publish); customer SPA **agent-browser visual E2E** (authenticated render of the json-render page + chat; unauthorized/cross-scope → denied) — the §36 standard, on an **isolated disposable seeded stack** (own ports, Tailscale `100.64.0.27`, never shared dev `:10042`/prod). PLUS two non-visual acceptance tests for the new path: a **leak test** (approve a surface version + write a `customer_visible` message but skip/block `commit_settlement` → the customer feed + browser adapter expose **neither the page nor the messages** before `status:committed`) and a **wake-up-loss test** (drop the PubSub/trunk wake-up between commit and delivery → the adapter still delivers, page + messages, by replaying the durable outbox on reconnect/next wake-up); and a **parent-commit-rollback test** (force the originating Turn slice commit to fail after settlement prep/cast-enqueue → no committed outbox/page/messages/delivery).
- **Orchestrator** — member-template regenerate / managed-member spawn (scenario-34 class).

Per-phase: run the affected suites + the arch fitness gates (`arch.scan`, `check_invariants`, `.lifecycle`, `--warnings-as-errors`) AND the relevant E2E from the set above before merge. The **whole-substrate final acceptance** = the full scenario set green via E2E on the unified implementation. Every distinct E2E bug earns a fast regression test before the fix lands.

## 8. Risks & mitigations

- **Touching core chat** → phase incrementally; each phase behavior-preserving + E2E-gated (§7); P5 (Kind collapse) last and optional.
- **Behavior dependency closure** → required-vs-optional sibling classification + a required-closure resolver (fail-loud only on a missing *required* slice) + a closure invariant test. Optional reads keep the existing soft `%{}` default (so today's `Chat → :sandbox`-without-`Sandbox` keeps working) — this is NOT "no defaults," it's "no missing *required* slice."
- **Trunk is a lossy signal, not a log** → P2.5 regularizes the event wire form + the durable committed customer-delivery outbox BEFORE P3 consumes it; consumers join durable stores for content. Do not migrate a consumer onto the trunk before its needed event exists.
- **Runtime is module-static today** (dispatch `{kind_module, action}`, `handle_info`/`handle_signal`/terminate/destroy all iterate `behaviors_of(kind_module)`, caps per-module) → P1 must make it **instance-behavior-set-aware as a HARD INVARIANT over EVERY behavior entry point** (not just dispatch + init): dispatch/caps, slice init/prune/reconcile/raw-access, create/post_init/activate/on_ready, the mailbox `handle_signal` path, terminate/deactivate/destroy, universal fallback. Without this blanket scoping, a one-Kind superset would let any instance route actions OR run signal/cleanup hooks OR create another app's slice — a security/state-shape breach. This contract gates P5 and is verified by denial tests across all entry points.
- **Customer feed re-platforming (Settlement → Publisher)** → P3 keeps the same visibility filter + the same Channel contract; E2E (render + deny) is the gate; can ship behind a flag if needed.
- **Publisher history is retention-bounded** → deep replay reads the durable stores (`kind_snapshots` + `MessageStore`); the trunk is live + bounded-history, not the system of record.
- **Codex-review every phase** (spec + each PR) per project policy.

## 9. YAGNI / deferred

- **Maximal view collapse** (internal LV rendering the *same* json-render tree as the SPA — "one tree, two renderers") — deferred; P2 keeps internal LV + external render as two targets under one contract.
- **Federation / event signing / causal DAG / state resolution** — out of scope (per #44); `workspace://` is the future server-authority seam.
- **shadcn-ui** component layer — optional follow-up over the daisyUI styling already shipped.
- **P5 (Kind collapse)** may remain deferred if its E2E risk outweighs the conceptual-purity benefit; the substrate is fully usable at P4.

## 10. Relationship to other tasks

- **#44 (protocol thin-formalization)** is **subsumed + sequenced as P2.5** (pulled before P3 per codex review): the trunk (`Publisher.Event`) + `Message` + slice snapshot become the one versioned wire form. It is now a *prerequisite* of the customer-feed migration, not a trailing nicety.
- **#36 / #45 (customer SPA)** are the first external-adapter + view consumers; this design generalizes them.
