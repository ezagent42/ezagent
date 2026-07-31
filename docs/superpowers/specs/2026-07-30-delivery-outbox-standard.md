# Unify cross-actor durable delivery on the actor substrate — spec

*Follow-up ② of the decentralization-hypothesis research
(`docs/notes/2026-07-30-decentralization-hypothesis.md`, #1636 — recommendation 2).
Planning doc only — no product code. Baseline: origin/main @ 2026-07-30.*

> ## Grill outcome (2026-07-30)
>
> Allen grilled the original framing ("make `DeliveryOutbox` the new STANDARD
> for every cross-actor delivery") and the X was re-pinned. **The X is NOT
> "build a durable outbox standard from scratch."** Code inspection during the
> session showed the actor substrate already has the two hard parts —
> pull-on-wake and a port abstraction. What it does NOT have is ONE
> cap-independent foundational primitive: durable delivery is domain-forked
> into two implementations, and cold-load reconcile is identity-hardcoded.
> **Direction changed from INVENT → UNIFY**: back the existing init-flush with
> one actor-layer durable outbox behind the existing port, converge the forks
> onto it, generalize the cold-load pull. Everything below is rewritten to
> that conclusion; the bug corpus (§1) and the fire-and-forget worklist (§2.3)
> stand unchanged from the original research.

---

## 1. Problem, grounded in the bug corpus

**#207 (fixed by PR #1409, 2026-07-15):** the sole grant path
(`Ezagent.Identity.Grant` → `Cap.issue/3` → `Identity.absorb_cap/2`) delivered the
signed cap artifact to the holder's own `:identity` slice via a VM-internal
fire-and-forget cast. A cold/unstarted receiver fell into `Ezagent.PendingDelivery`
— an ETS-backed, bounded, **volatile** buffer: lost on BEAM restart, drops on
overflow. The cap never landed; `CapAbsorbAwait.await_exact/3` timed out with
`{:error, {:absorb_not_committed, _}}` (the `turn_survives_restart` /
`page_view_external_render` red class). The fix — `Ezagent.Cap.DeliveryOutbox` —
is durable, at-least-once, idempotent-apply, applied-only-after-commit… and
cap-specific.

**#1501 (PR open, in adversarial-review rework):** the residual of #207's fix.
The effective cap view (`Ezagent.EntityCaps.load/1`) reads only **held** caps and
never merges **pending** outbox rows; grant is not idempotent under producer
retry; the absorb path is not uniformly fail-closed. Board task:
`docs/together/tasks/caps-consolidation-1501.md`.

**The class (research doc ③, bug #5):** "fire-and-forget cast to a maybe-dead
actor" is not an absorb-specific bug. Any cross-actor **state transfer** — a write
that must land in the *receiver's own durable store* — delivered as a bare cast
assumes receiver liveness and has no owner while in flight. Cross-actor state
transfer must be **EC by construction** (durable enqueue + liveness-gated
redelivery + idempotent apply), never fire-and-forget. Today only one producer op
has that; everything else still rides the volatile buffer.

## 2. Current state — what the substrate ALREADY has vs where it forked

All claims re-verified against the tree this session (2026-07-30).

### 2.1 Already solved at the actor layer (do not rebuild)

| Capability | Where | Verified behavior |
|---|---|---|
| **Pull-on-wake** | `apps/ezagent_actor/lib/ezagent/kind/server.ex` — `handle_continue(:announce_ready, …)` and the last post-init continuation both end in `Ezagent.Kind.ReadyTransition.drain_then_mark_ready/2` | Every actor, on EVERY cold load, unconditionally drains `PendingDelivery` at the end of init/post-init, *before* flipping `:ready` (the drain-then-mark order is the PR-EM-CORE round-3 HIGH-1 fix). **"How does the receiver know to pull?" is already answered: it always pulls on wake. No notification protocol is needed for correctness.** |
| **Outbox port abstraction** | `apps/ezagent_actor/lib/ezagent/kind/ports/outbox_port.ex` (7 callbacks: `replay?/1`, `eligible?/1`, `enqueue_and_attempt/1`, `mark_applied/2`, `record_handler_failure/2`, `pending_target?/1`, `drain_target/1`) + adapter `apps/ezagent_core/lib/ezagent/kind/adapters/outbox_adapter.ex`, resolved via `Application.fetch_env!(:ezagent_actor, :outbox)` | The dispatch chokepoint (`apps/ezagent_actor/lib/ezagent/invocation.ex`) and the ready transition (`kind/ready_transition.ex`) already talk to "the outbox" ONLY through this port. The seam for a substrate-level durable outbox **exists and is already load-bearing**. |
| **Ready-drain + sweep + apply-commit gate** | `ready_transition.ex` (`drain_target` on target's ready flip), `cap/delivery_outbox/sweeper.ex` (periodic), `kind/server.ex` (`mark_applied` after handler+commit, `record_handler_failure` re-arms retry) | The full liveness-gated redelivery loop is wired end-to-end — for the one producer family that is outbox-eligible. |

### 2.2 Where it forked / stayed narrow (the actual X)

1. **`PendingDelivery` is ephemeral.**
   `apps/ezagent_actor/lib/ezagent/pending_delivery.ex` — ETS-backed
   (`:ets.insert`, `:ets.lookup`), bounded `@max_per_uri 100` (line 31), overflow
   → DLQ, **lost entirely on BEAM restart**. So the substrate's universal
   pull-on-wake drains a buffer that may have silently vanished.
2. **The durable outbox is FORKED into two domain-owned implementations:**
   - `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex` — cap plane
     (`cap_delivery_outbox` table, PG migrations `20260714010000` +
     `20260714020000`); Envelope allowlist closed to two identity ops.
   - `apps/ezagent_domain_session/lib/ezagent/socialware/delivery_outbox.ex` —
     socialware turn delivery (per-turn rows, `committed_seq` cursor).
   Two schemas, two sweep/replay loops, one contract — [B]-class duplication.
3. **Cold-load reconcile is identity-SPECIFIC.**
   `kind/server.ex:309` `maybe_reconcile_cold_load_identity/4` (called from the
   cold-load path at :186) hardcodes a call into
   `Ezagent.EntityCaps.Store.reconcile_cold_load_identity/3`
   (`apps/ezagent_domain_identity/lib/ezagent/entity_caps/store.ex:707`). The
   actor framework knows about ONE domain's durable-state catch-up by name,
   instead of offering a generic "pull your durable pending rows on wake" that
   any domain rides.

**The X, pinned:** *the actor substrate has pull-on-wake and a port, but durable
delivery is domain-forked and cold-load catch-up is identity-hardcoded — there
is no ONE cap-independent foundational primitive.* Not "we lack a mechanism";
we have one and a half too many, one layer too high.

### 2.3 Fire-and-forget paths still on the volatile buffer (worklist, unchanged)

Classified per the receiver-owned-durable-state test (§3.2):

**(a) Cap-plane state transfer — same datum class as #207, still volatile:**

1. **`grant_cap_via_router/4 :async`** —
   `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex:143–166`.
   Dispatches action `store_cap` with producer marker `:identity_grant` — not in
   the Envelope allowlist → rides `PendingDelivery`. Callers include
   `Session.membership.grant_first_join_owner_cap` and every
   `grant_cap_effect/3` effect site.
2. **`revoke_cap_via_router/4 :async`** — `grant.ex:182–205`. Dispatches action
   `remove_cap` / caller `:vm_internal`; the Envelope's revoke clause requires
   action `identity.revoke_cap` + an entity-URI caller — neither matches → not
   outbox-eligible, **despite this function's own moduledoc claiming "the cast
   is persisted in the capability delivery outbox"** (grant.ex:169–181). No prod
   call site dispatches `identity.revoke_cap` at all (rg: only the Envelope and
   tests) — **the outbox's revoke leg appears to be dead code in prod; every
   real revoke rides the volatile path.** `:async` is *required* at the session
   member-cap call sites (sync self-deadlocks inside the Session Kind callback,
   todo #161-A2) — which is precisely why the durable leg matters.
3. **`EntityCaps.persist/2 / grant/2 / revoke/2`** —
   `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:160–197` — same
   non-eligible actions.

Already durable (for contrast): `Identity.absorb_cap/2` (producer
`:identity_absorb`) and everything reaching absorb.

**(b) Non-cap bare `GenServer.cast` outside the dispatch chokepoint** (prod):
`live_join_registry.ex:37`, `domain/pty.ex:170`, `domain/python.ex:241`,
`session/delivery_queue.ex:79`, plus infra singletons (same-supervision-tree
plumbing — those stay). Input worklist for the P3 gate baseline.

**(c) Chat sends / signals / projections:** **EXCLUDED.** Their durable
convergence is owned elsewhere (append-only MessageStore + cursor replay,
Decision #91; monotonic-version EC projections) and they get their own
convergence track. Wrapping them here would duplicate an existing owner — the
exact [B]-class mistake this spec is closing.

## 3. Direction — UNIFY what exists (nothing new invented)

### 3.1 The model (three roles, cleanly split)

| Role | Piece | Guarantee class |
|---|---|---|
| **Truth** | ONE actor-layer **durable pending table**, keyed by target URI — the durable backing of `PendingDelivery`'s buffer, behind the existing `outbox_port` | Durable, at-least-once, idempotent-apply, applied-only-after-commit |
| **Guarantee** | **Pull-on-wake** — already implemented: the init/post-init drain in `kind/server.ex` (§2.1). Generalized cold-load pull replaces the identity-specific hook | Every wake converges the receiver, no matter what was missed |
| **Latency** | **Best-effort push-notify** (the existing cast/drain-hint paths) | LOSSY-OK by design — a lost notify only delays convergence until the next wake/sweep; it can never lose state, because pull-on-wake is the guarantee |

This is the whole design. No new notification protocol, no new port, no new
consistency regime — the substrate's existing shape, with the volatile piece
made durable and the hardcoded piece made generic.

### 3.2 Scope rule (per-datum test, unchanged from research)

- **In scope:** any cross-actor write whose effect must land in the receiver's
  own durable store — cap grant/revoke/absorb/persist today; future
  receiver-store mutations (config pushes, membership convergence writes,
  offboarding fences) ride the same primitive for free.
- **Out of scope:** chat/message fan-out, signals, UI/projection notifies,
  infra singleton casts (§2.3(c)/(b)-infra).

### 3.3 Phased migration (converged at the grill)

- **P0 — land #1501** (in flight, adversarial-review rework): held ∪ pending
  effective view, idempotent grant, fail-closed absorb. Prerequisite: the
  read-side contract must be right before more producers converge onto the
  outbox. Gate: its own acceptance list.
- **P1 — durable-back `PendingDelivery` + generalize cold-load.**
  Give the substrate's buffer a durable backing behind the EXISTING
  `outbox_port` (the port's seven callbacks already cover
  enqueue/replay/drain/apply — this is an adapter/store change, not a port
  change). Replace `maybe_reconcile_cold_load_identity` with a generic
  cold-load pull ("drain my durable pending rows on wake") that the identity
  reconcile becomes ONE client of, via the same port — `kind/server.ex` stops
  naming `EntityCaps.Store`.
- **P2 — migrate cap grant/revoke off fire-and-forget** onto the unified
  primitive (the §2.3(a) worklist): `store_cap`, `remove_cap`, `persist_caps`
  become durable. Includes **resolving the revoke doc-vs-behavior dead-code
  gap** (§2.3(a)2): either wire the real revoke path into eligibility or delete
  the dead Envelope leg — but first reproduce the loss as a failing test (cold
  holder + `revoke_cap_via_router :async` + BEAM restart → revoke lost), per
  trace-to-chokepoint discipline. Producer call sites unchanged (eligibility
  decided at the dispatch chokepoint by ctx marker + action, zero caller churn
  — the pattern absorb already proved).
- **P3 — retire the socialware fork + CI gate.**
  Converge `Ezagent.Socialware.DeliveryOutbox` onto the unified actor-layer
  primitive (its `committed_seq` consumer cursor stays a socialware concern;
  the durable-row/replay/sweep machinery stops being a second implementation).
  Land the CI grep-gate forbidding new bare cross-actor `GenServer.cast` in
  prod code outside an enumerated allowlist (baseline = §2.3(b), produced by an
  empty-allowlist run; shrink-only), same invariant-test shape as
  `cap_absorb_reachability_test.exs`. ARCHITECTURE.md Decision-Log entry.

Each phase is a one-shot cutover — no long-lived dual-plane window (the #189
lesson, research doc ⑥.5).

### 3.4 What this explicitly does NOT change

- **Revocation immediacy is not the outbox's job**: security remains the
  act-time generation gate (`verify_against_current`, gen-gated holder reads —
  research "do not touch" #7). The outbox only makes holder-store *convergence*
  durable; a pending revoke row + stale held cap is already deniable at the
  chokepoint.
- No relaxation of `KindRegistry` `put_new` single-live-actor semantics (⑥.8).
- No plugin-extensible producer registry in v1 (closed, code-reviewed set).
- Chat/signals/projections excluded (own convergence track).

### 3.5 Acceptance (invariant-test style, per phase)

- P0: #1501's checkboxes green + codex pass.
- P1: restart-survival test at the SUBSTRATE level — buffered delivery to a
  not-ready actor survives BEAM restart and lands on next wake (red today:
  ETS buffer dies with the VM); cold-load pull works for a non-identity datum
  (proves the generalization); identity reconcile behavior unchanged.
- P2: the revoke-loss reproduction flips red→green; grant-to-never-started-
  entity survives restart; `turn_survives_restart` class stays green; rg proves
  zero cap-plane mutations reach the volatile-only path.
- P3: socialware delivery behavior-identical on the unified primitive (its
  existing replay/self-heal tests stay green verbatim); cast-gate red on a
  synthetic violation, green on baseline; `ci.fast` budget unchanged.

## 4. Open questions (genuinely open post-grill)

1. **Migration sequencing inside P1/P2:** durable-back the buffer first and
   then move producers (two deploys, safer), or cut grant+revoke over in the
   same release as the durable backing (one deploy, bigger blast radius)?
   Recommendation: two steps — P1 is substrate-only and invisible to domains.
2. **The revoke dead-code decision (P2):** fix the Envelope clause so the REAL
   revoke path (`remove_cap` / `:vm_internal`) becomes eligible, or re-route
   callers to the documented `identity.revoke_cap` action? The moduledoc
   already promises durability — behavior should be made to match the promise,
   but which side moves needs the failing test first.
3. **Unified table shape:** extend `cap_delivery_outbox` into the generic
   actor-layer table (rename + widen op column) vs new table + cap rows
   migrate? Affects P1/P3 rollout order and the drain-before-deploy note.
4. **Socialware cursor semantics in P3:** `committed_seq` is a consumer-side
   ordering cursor the cap plane doesn't have — confirm it layers ON TOP of the
   unified rows (socialware-owned read model) rather than forcing per-target
   ordered claims into the shared primitive.
5. **`:dead`-row operator surface:** alert threshold + whether a `:dead` grant
   surfaces in the grantee's UI (visible degradation vs ops-only) — unchanged
   question from the original plan, still Allen's call.
