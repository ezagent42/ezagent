# DeliveryOutbox as the STANDARD for all cross-actor delivery — implementation plan

*Follow-up ② of the decentralization-hypothesis research
(`docs/notes/2026-07-30-decentralization-hypothesis.md`, #1636 — recommendation 2:
"Make the DeliveryOutbox pattern the standard for every cross-actor state delivery").
Planning doc only — no product code. Baseline: origin/main @ 2026-07-30.*

---

## 1. Problem, grounded in the bug corpus

**#207 (fixed by PR #1409, 2026-07-15):** the sole grant path
(`Ezagent.Identity.Grant` → `Cap.issue/3` → `Identity.absorb_cap/2`) delivered the
signed cap artifact to the holder's own `:identity` slice via a VM-internal
fire-and-forget cast. A cold/unstarted receiver fell into `Ezagent.PendingDelivery`
— an ETS-backed, bounded (100/URI, `pending_delivery.ex:31`), **volatile** buffer:
lost on BEAM restart, drops on overflow. The cap never landed;
`CapAbsorbAwait.await_exact/3` timed out with `{:error, {:absorb_not_committed, _}}`
(the `turn_survives_restart` / `page_view_external_render` red class). The fix —
`Ezagent.Cap.DeliveryOutbox` — is the durable, at-least-once, idempotent-apply,
applied-only-after-commit mechanism this plan generalizes.

**#1501 (PR open, in adversarial-review rework):** the residual of #207's fix.
The effective cap view (`Ezagent.EntityCaps.load/1`) reads only **held** caps and
never merges **pending** outbox rows; grant is not idempotent under producer retry;
the absorb path is not uniformly fail-closed. Board task:
`docs/together/tasks/caps-consolidation-1501.md`.

**The class (research doc ③, bug #5):** "fire-and-forget cast to a maybe-dead
actor" is not an absorb-specific bug. Any cross-actor **state transfer** — a write
that must land in the *receiver's own durable store* — delivered as a bare cast
assumes receiver liveness and has no owner while in flight. The research verdict:
cross-actor state transfer must be **EC by construction** (durable enqueue +
liveness-gated redelivery + idempotent apply), never fire-and-forget. Today only
one producer op has that; everything else still rides the volatile buffer.

## 2. Current state — enumeration of cross-actor delivery paths

### 2.1 The durable mechanism that exists (narrow)

| Piece | Where | What it does |
|---|---|---|
| `Ezagent.Cap.DeliveryOutbox` | `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex` | `enqueue_and_attempt/1` persists a versioned envelope row **before** the first cast (`:pending`, `insert_or_reuse` at :278); claim-lease serialization (:193); exponential backoff 1s→60s (:381); `mark_applied/2` only after the target's handler + slice commit (:140); `:dead` terminal status |
| Row schema | `apps/ezagent_core/lib/ezagent/cap/delivery.ex` (`cap_delivery_outbox`; PG migrations `20260714010000` + `20260714020000`) | `workspace_uri, target_uri, op, payload, payload_identity (sha256 of the cap), idempotency_key (partial unique index), status, attempts, next_retry_at, claim_token, lease_until` |
| Envelope (v4) | `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/envelope.ex` | Closed producer allowlist (`producer_parts/1`, :125–:151): **only** `:identity_absorb` (action `identity.absorb_cap`, caller `:vm_internal`) and `:identity_revoke` (action `identity.revoke_cap`, entity caller) |
| Dispatch interception | `apps/ezagent_actor/lib/ezagent/invocation.ex:156–170` | `outbox().eligible?/replay?` checked at the **dispatch chokepoint**, via the config-resolved `OutboxPort` (`kind/ports/outbox_port.ex`, adapter `kind/adapters/outbox_adapter.ex`) |
| Liveness-gated redelivery | `apps/ezagent_actor/lib/ezagent/kind/ready_transition.ex:56–58` (`drain_target` on the target's ready transition, ETS target-hint) + `cap/delivery_outbox/sweeper.ex` (periodic `sweep_due`, supervised at `ezagent_core/application.ex:60`) + `rehydrate_hints/0` at boot | A not-ready target leaves a durable row (`{:error, :durable_pending}` → `:not_ready`, `invocation.ex:237–238, 323–331`) instead of the volatile buffer |
| Apply-side commit gate | `apps/ezagent_actor/lib/ezagent/kind/server.ex:1047, 1079` | `mark_applied` after handler+commit; `record_handler_failure` re-arms retry |

This is the right contract, already production-proven. It is just **only wired to
one-and-a-half producer ops**.

### 2.2 Fire-and-forget paths NOT on the outbox (the gap worklist)

Classified per the receiver-owned-durable-state test (§3.1):

**(a) Cap-plane state transfer — same datum class as #207, still volatile:**

1. **`grant_cap_via_router/4 :async`** — `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex:143–166`.
   Dispatches action `store_cap` with producer marker `:identity_grant`
   (`storage_ctx/1` at :320–325). `:identity_grant` is **not** in the Envelope
   allowlist → the cast rides `PendingDelivery` (volatile, 100/URI, DLQ on
   overflow). Callers include `Session.membership.grant_first_join_owner_cap`
   (deliberate fire-and-forget, grant.ex:312–319 NB) and every
   `grant_cap_effect/3` effect site.
2. **`revoke_cap_via_router/4 :async`** — `grant.ex:182–205`. Dispatches action
   `remove_cap` with producer `:identity_revoke` and caller `:vm_internal`. The
   Envelope's revoke clause (`envelope.ex:136–149`) requires action
   `identity.revoke_cap` **and** an entity-URI caller — neither matches → **not
   outbox-eligible**, despite this function's own moduledoc claiming "the cast is
   persisted in the capability delivery outbox" (grant.ex:169–181). No prod call
   site dispatches action `identity.revoke_cap` at all (rg: only the Envelope and
   tests) — i.e. **the outbox's revoke leg appears to be dead code in prod; every
   real revoke rides the volatile path**. Callers: session member-cap revoke on
   leave/remove and the at-join compensation
   (`apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:100–118, 220–260`)
   — `:async` is *required* there (sync self-deadlocks inside the Session Kind
   callback, empirically verified, todo #161-A2), which is precisely why the
   durable leg matters. **Verify this doc/behavior mismatch first (Phase 1, A1).**
3. **`EntityCaps.persist/2 / grant/2 / revoke/2`** —
   `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:160–197` — dispatch
   `persist_caps` / `store_cap` / `remove_cap` mutations; same non-eligible
   actions.

Already durable (for contrast): `Identity.absorb_cap/2`
(`identity.ex:158–181`, producer `:identity_absorb`) and everything reaching
absorb — `TargetAuthority.ensure/2` (`identity/target_authority.ex:38–45`),
`MemberCap.grant_at_join` (`member_cap.ex:66–77`),
`Grant.issue_and_absorb_cap/4` (awaits via `CapAbsorbAwait`).

**(b) Non-cap cross-actor casts assuming receiver liveness** (bare
`GenServer.cast` outside the dispatch chokepoint, prod code):

- `apps/ezagent_domain_agent/lib/ezagent/agent/live_join_registry.ex:37`
  (`{:live_joined, agent_uri}` to a registry-looked-up session pid)
- `apps/ezagent_domain_pty/lib/ezagent/domain/pty.ex:170` (`:respawn`)
- `apps/ezagent_domain_python/lib/ezagent/domain/python.ex:241` (`{:rpc_notify, …}`)
- `apps/ezagent_domain_session/lib/ezagent/session/delivery_queue.ex:79`
- infra singletons (audit writer, snapshot writer, presence mirror,
  registration hooks, transport-readiness listener) — same-process-tree
  plumbing, **not** cross-actor state transfer; these stay.

**(c) General `:cast`-mode dispatches** (chat sends, signals): transient message
delivery whose durable convergence is owned elsewhere (append-only MessageStore +
cursor replay, Decision #91). Explicitly **out of scope** — see §3.1.

**(d) A second, independent durable outbox already exists:**
`Ezagent.Socialware.DeliveryOutbox`
(`apps/ezagent_domain_session/lib/ezagent/socialware/delivery_outbox.ex`) — per-turn
delivery rows with `committed_seq` commit-order cursor for external surfaces. It
already satisfies the standard's contract (durable row, committed-visible flag,
replay self-heal). The standardization question is whether it must share the
mechanism or only the contract (§5 Q2 — recommendation: contract only).

### 2.3 What #1501 shipped vs left pending

Nothing has shipped: **PR #1501 is open, in rework** after an adversarial-review
reject. Its scope (board task file) is exactly the apply/read half of the outbox
contract: (i) effective view = held ∪ pending (today `EntityCaps.load/1`,
`entity_caps.ex:61–99`, reads live-slice-or-persisted only — a granted-but-not-yet
-absorbed cap is invisible); (ii) grant idempotency under producer retry;
(iii) fail-closed absorb. This plan **absorbs #1501 as its Phase 0** — land it
first (it is a prerequisite of the wider migration, not parallel work).

## 3. Design — one standard, stated as a contract + one mechanism

### 3.1 The standard (contract)

> **Any cross-actor write whose effect must land in the receiver's own durable
> store MUST be delivered through a durable outbox**: (1) durable enqueue
> **before** the first delivery attempt; (2) redelivery gated on receiver
> liveness (drain-on-ready + periodic sweep + dispatch-time lazy-spawn), never
> on sender retry loops; (3) idempotent apply keyed on a payload identity;
> (4) marked applied only **after** the receiver's handler and state commit;
> (5) bounded failure → `:dead` + DLQ visibility, never silent drop.

Scope rule (what "every cross-actor delivery" means — the per-datum test):

- **In scope:** cap grant/revoke/absorb/persist; any future receiver-store
  mutation (config pushes, membership convergence writes, offboarding fences).
- **Out of scope:** chat/message fan-out and signals (durable convergence =
  MessageStore + cursor replay); UI/projection notifies (monotonic-version EC
  projections); infra singleton casts (same supervision tree). Wrapping these in
  an outbox would duplicate an owner that already exists — the exact [B]-class
  mistake the research doc warns against.

### 3.2 Mechanism: generalize `Cap.DeliveryOutbox` → producer-registered ops

Keep the existing table, state machine, sweeper, ready-drain, and dispatch
interception **unchanged**. Generalize only the closed eligibility set:

1. **Op registry instead of a hard-coded two-op allowlist.** The Envelope's
   `producer_parts/1` becomes a small registry of *delivery op specs* (still a
   closed, code-reviewed set — not plugin-extensible in v1):
   `{producer, action, payload_extractor, payload_identity, apply_contract}`.
   V1 registers: `:identity_absorb` (absorb_cap — unchanged),
   `:identity_grant` (store_cap), `:identity_revoke` (remove_cap — fixing the
   §2.2(a)2 mismatch), `:identity_persist` (persist_caps).
2. **Envelope version bump** (v4 → v5) with the op field widened; replay of v4
   rows keeps decoding (rows are short-lived; a drain-before-deploy note in the
   release checklist is acceptable — same as the #1409 rollout).
3. **Ordering guarantee per target:** `drain_target` already replays
   `order_by id` per target; the sweeper must preserve per-target ordering when
   both a grant and its revoke are pending (add per-target ordered claim, or
   skip a row whose target has an earlier pending row). This matters once
   grant AND revoke are both durable: applying revoke-then-grant inverts intent.
4. **Immediacy is not weakened:** revocation *security* remains the act-time
   generation gate (`verify_against_current`, gen-gated holder reads) — research
   doc "do not touch" #7. The outbox only makes the holder-store *convergence*
   durable; a pending revoke row + stale held cap is already deniable at the
   chokepoint. State this in the moduledoc to prevent the "outbox = revocation
   lag" misreading.
5. **`Socialware.DeliveryOutbox` stays separate** (recommendation): different row
   shape (per-turn PK, `committed_seq` cursor as source of truth), different
   consumer. It is declared a *conforming implementation* of the §3.1 contract;
   the CI gate (§3.4) checks the contract, not the mechanism.

### 3.3 Phased migration

- **Phase 0 — land #1501** (owner: gaga, in flight): held ∪ pending effective
  view, idempotent grant, fail-closed absorb, codex re-review. Gate: its own
  acceptance list.
- **Phase 1 — absorb/revoke correctness (proven painful first).**
  A1: reproduce the §2.2(a)2 revoke gap as a failing test (cold holder +
  `revoke_cap_via_router :async` + BEAM restart → revoke lost) — per
  `feedback_trace_to_chokepoint_gate`, no fix before a failing reproduction.
  A2: wire `:identity_revoke`/`remove_cap` through the outbox (op registry
  entry), fix the `Grant.revoke_cap_via_router` moduledoc-vs-behavior mismatch.
  A3: per-target ordering under mixed pending ops (§3.2.3).
- **Phase 2 — grant/persist migration.** `store_cap` (`:identity_grant`) and
  `persist_caps` producers become outbox-eligible; `PendingDelivery` no longer
  carries any cap-plane mutation. Back-compat: producer call sites are
  unchanged (eligibility is decided at the dispatch chokepoint by ctx marker +
  action — the same pattern absorb used, zero caller churn).
- **Phase 3 — the CI gate (§3.4) + PendingDelivery demotion.** PendingDelivery's
  contract narrows to transient message buffering; its moduledoc + Decision-Log
  entry updated; DLQ/dead-row operator surface (a `mix ezagent.outbox.list`
  read-only task) added so `:dead` rows are visible (no silent graveyard).
- **Phase 4 (deferred, needs Allen):** audit non-cap candidates (§2.2(b)) —
  `live_join_registry` and session `delivery_queue` are liveness-sensitive but
  their state is reconstructible (roster reconcile / queue rebuild); decide
  per-site whether they get outbox rows or a documented "reconstructible on
  restart" exemption.

Each phase is a one-shot cutover (no long-lived dual-plane window — the #189
lesson, research doc ⑥.5).

### 3.4 CI gate — forbid new bare cross-actor casts

Same shape as the existing dispatch-chokepoint gates
(`apps/ezagent_core/test/invariants/cap_absorb_reachability_test.exs` — wildcard
scan over `apps/**/*.ex` + explicit allowlist; runs in `mix ci.fast`):

- **G1 (mechanical):** no `GenServer.cast` in prod code outside an enumerated
  allowlist (infra singletons + the two framework delivery points
  `invocation.ex:310` / `ready_transition.ex:95`). Baseline allowlist =
  the §2.2(b) list, produced by running the gate **empty-allowlist first**
  (enumerator-gate discipline); it may only shrink.
- **G2 (semantic):** any `%Cmd{}`/`%Invocation{}` construction whose action is a
  registered *delivery op action* (`store_cap`, `remove_cap`, `absorb_cap`,
  `persist_caps`, + future registry entries) must carry a `cap_delivery_producer`
  marker — grep-gate over constructors, keyed off the op registry so the gate
  can't drift from the code.
- **G3 (contract doc):** ARCHITECTURE.md Decision-Log entry declaring §3.1 the
  standing rule, cross-linked from the gate failure message.

### 3.5 Acceptance (per phase, invariant-test style)

- P0: #1501's three checkboxes green + codex pass.
- P1: the A1 reproduction flips red→green; restart-survival test for revoke
  (cold holder, revoke, kill BEAM, boot → holder store converged, gen-gate
  unaffected); mixed grant+revoke ordering test.
- P2: `turn_survives_restart` class stays green; a new
  "grant to never-started entity survives restart" test; grep proves zero
  cap-plane mutations reach `PendingDelivery.buffer_if_not_ready_locked`.
- P3: G1/G2 red on a synthetic violation, green on baseline; `ci.fast` runtime
  budget unchanged (<2 min).

## 4. Open questions for Allen

1. **Scope confirmation (§3.1):** agree that chat/signals/projections are
   explicitly OUT (durable owner exists elsewhere), so "standard for every
   cross-actor delivery" = every *receiver-owned durable-store write*?
2. **Socialware outbox:** contract-level standardization only (recommended), or
   physically migrate it onto the generic mechanism (higher churn, no corpus bug
   demanding it)?
3. **Phase 4 non-cap candidates:** outbox rows vs documented reconstructible-
   on-restart exemptions for `live_join_registry` / session `delivery_queue`?
4. **`require_sync_ack` seam** (`delivery_outbox.ex:164–168`, currently unused):
   should any producer class (e.g. offboarding fence writes) demand synchronous
   applied-ACK, or does `CapAbsorbAwait`-style explicit await remain the only
   sync surface?
5. **`:dead`-row policy:** operator alert threshold + whether a `:dead` grant
   should surface in the grantee's UI (visible degradation vs ops-only).

## 5. Non-goals

- No relaxation of the generation gate / revocation immediacy (research ⑥.7).
- No change to `KindRegistry` `put_new` single-live-actor semantics (⑥.8).
- No plugin-extensible op registry in v1 (closed, reviewed set).
- No merging of `PendingDelivery` and the outbox into one mechanism — they serve
  different contracts (transient buffering vs durable state transfer).
