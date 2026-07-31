# DeliveryOutbox — FINAL PLAN (converged)

*Follow-up ② of the decentralization-hypothesis research — the convergence doc
for the merged spec `docs/superpowers/specs/2026-07-30-delivery-outbox-standard.md`.
The spec ended with 5 open questions (§4); the owner (Allen) resolved all 5 on
2026-07-31. This doc records those decisions, corrects one dead-code claim, and
pins the phase plan. Plan/doc only — no product code. Baseline: origin/main @
`1f2a804cc` (all file:line refs re-verified against that tree this session).*

---

## 0. The reframe — what ② is (and is not)

**② solves exactly ONE problem: reliable cross-actor delivery into a
receiver-owned durable store.** Its primary payload is capability grants — the
#207 class (grant cast to a cold holder dies with the volatile ETS buffer).
Everything in this plan is in service of that one guarantee: a cross-actor
state transfer, once accepted, has a durable owner until the receiver's own
store has committed it.

**② is NOT an authz redesign.** The security model is untouched:

- Authority stays with the act-time **generation gate** — dispatch verification
  (`apps/ezagent_core/lib/ezagent/cap/verifier.ex`,
  `Ezagent.Cap.Authority.verify_current/2` at
  `apps/ezagent_core/lib/ezagent/cap/authority.ex:244`) and the read side
  (`Ezagent.EntityCaps.GranteeIndex.grantees_of/4`,
  `apps/ezagent_domain_identity/lib/ezagent/entity_caps/grantee_index.ex:114`)
  both filter to the target's CURRENT active `key_id`.
- The outbox sits UNDER that gate as a delivery/convergence mechanism. It makes
  holder-store convergence durable; it never decides what is authorized.

Corollary (drives Q2 below): a mechanism whose job is delivery must not be
argued about as if it were the revocation security boundary — it isn't one.

The decentralization hypothesis holds throughout: this is **not a central
bus**. Rows are keyed by `target_uri` and drained by each target Kind's own
lifecycle process (init/post-init drain + per-target ready-drain). **The owner
of a pending delivery is the receiver** — the table is shared storage, the
drain loop and apply are per-receiver.

## 1. Converged decisions (Q1–Q5)

### Q1 — Migration sequencing: ONE deploy

Spec §4.1 asked: durable-back the buffer first, then move producers (two
deploys), or both in one release?

**Decision: one deploy.** The durable backing (P1) and the grant-producer
cutover (P2) land in the same release. Rationale: the system is not prod-live
yet — the two-deploy blast-radius argument protects production traffic that
does not exist, while paying real cost in iteration speed and in a dual-plane
window (the #189 lesson: no long-lived dual planes). P1 and P2 remain separate
work phases with separate acceptance gates (below), but ship together.

### Q2 — Revoke: run the spec-mandated repro test first, leaning (b)

Spec §4.2 asked: make the real revoke path (`remove_cap`) outbox-eligible (a),
or resolve the doc-vs-behavior gap the other way (b)?

**Decision: reproduce first, leaning (b) — because revocation is ALREADY
act-time-secure without the outbox.** The reasoning, stated plainly:

- Revocation bumps the target's authority `key_id` (generation bump). From that
  moment, a stale-generation cap is **denied at dispatch**
  (`Cap.Verifier` / `Authority.verify_current`) and **hidden from reads**
  (`grantee_index.grantees_of` filters to the current active `key_id`) —
  regardless of whether the `remove_cap` physical row-delete in the holder's
  store ever survives a restart.
- Therefore `remove_cap` is **store-convergence cleanup, NOT
  security-load-bearing**. A lost `remove_cap` leaves a stale row that can
  neither be exercised nor read — junk, not a vulnerability.

**The repro test (spec P2 mandate, runs first regardless of the lean):**
cold holder + `revoke_cap_via_router/4 :async` + BEAM restart → assert whether
the revoked cap is still **usable** (dispatches through the verifier) or
**readable** (visible via the effective-caps / grantee reads). Per
trace-to-chokepoint discipline, the decision executes only after this test's
verdict:

- **Test confirms denied+hidden (expected) → do (b):**
  1. **Delete the never-matched Envelope revoke-eligibility clause** —
     `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/envelope.ex:148-161`.
     It requires action `{:identity, :revoke_cap}` + an entity-URI caller +
     producer `:identity_revoke`; the real revoke dispatch sends action
     `:remove_cap` with `caller: :vm_internal`
     (`apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex:194` and the
     ctx builder at `grant.ex:328`) — the clause can never match. No prod call
     site dispatches `identity.revoke_cap`.
  2. **Fix the `revoke_cap_via_router/4` moduledoc overpromise** —
     `grant.ex:168-181` claims "The cast is persisted in the capability
     delivery outbox before dispatch and retried until the grantee handler
     applies it." False today; under (b) the doc changes to match reality:
     best-effort convergence cast, security carried by the generation gate.
  3. **Optional periodic reconcile sweep** for stale (already-revoked-by-gen)
     holder rows — pure hygiene, can lag arbitrarily, never a security fix.
- **Test shows a real post-restart usable/readable revoked cap (unexpected) →
  do (a):** make `remove_cap` outbox-eligible (durable), same
  chokepoint-eligibility pattern as `store_cap` in P2.

> **IMPORTANT CORRECTION to the spec's §2.3(a)2 wording.** The spec said "the
> outbox's revoke leg appears to be dead code in prod; every real revoke rides
> the volatile path" — which reads as if the revoke *function* is dead.
> **`revoke_cap_via_router/4` itself is LIVE prod code — do NOT delete it.**
> Verified callers:
> - member-cap **join-entitlement consume** (single-use tier-0 join grant
>   consumed after join) —
>   `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:123`
>   (`:async`, required by the in-Kind self-deadlock contract);
> - **membership revoke** on LEAVE/REMOVE — `member_cap.ex:246` (`:sync`;
>   REMOVE treats `{:error, _}` as ABORT — member left intact — LEAVE is
>   best-effort).
>
> Only the **Envelope eligibility clause** (`envelope.ex:148-161`) is dead —
> that clause, and only that clause, is what (b) deletes.

**Ownership:** this is jjkysy's cap-model territory — the repro test verdict
and the (a)/(b) execution are coordinated with him (see §4).

### Q3 — Unified table: EXTEND `cap_delivery_outbox`, no new table

Spec §4.3 asked: extend `cap_delivery_outbox` into the generic actor-layer
table, or create a new table and migrate cap rows?

**Decision: extend.** The existing schema
(`apps/ezagent_core/priv/repo_pg/migrations/20260714010000_create_cap_delivery_outbox.exs`
+ `20260714020000_harden_cap_delivery_outbox.exs`) is already generic — nothing
in the column set is cap-specific:

```
workspace_uri / target_uri / op / payload / payload_identity / status /
attempts / next_retry_at / last_error / applied_at / payload_version /
idempotency_key / claim_token / lease_until / dead_at
```

What actually pins it to the cap plane is two things, both cheap to widen:

1. the check constraint `op IN ('absorb_cap', 'revoke_cap')` — widen the
   allowed `op` values as new producer families become eligible (P3);
2. the apply side decodes into a cap-specific `Invocation`
   (`Envelope.to_invocation/2`) — generalize to a generic apply-dispatch keyed
   on `op`.

A new table + cap-row migration would buy nothing except a data migration, a
drain-before-deploy window, and a rename churn. Rejected.

Reinforcing the reframe: even generic, this stays **per-receiver**. Rows keyed
by `target_uri`; each receiver Kind drains its own rows on its own wake/ready
transitions. No consumer groups, no topic fan-out, no central dispatcher — the
"owner = the receiver" shape of the decentralization hypothesis is a design
invariant of the generic table, not an accident of the cap-only version.

### Q4 — Socialware cursor (`committed_seq`): OUT of ② scope → socialware protocol (jjkysy)

Spec §4.4 asked whether the socialware consumer cursor layers on top of the
unified rows or forces ordered claims into the shared primitive.

**Decision: out of ② scope entirely.** The cursor is a consumer-side read-model
concern of the *answering socialware*, and it belongs to the socialware
protocol work — the #1667 answer-routing spec (jjkysy). The layering is
confirmed as the spec suspected: the socialware layers its `committed_seq`
consumer cursor ON TOP of generic outbox rows (a socialware-owned read model);
the generic primitive stays unordered-per-target, at-least-once,
idempotent-apply. ② will not add ordering semantics, cursor columns, or
cursor APIs to the shared table. The fold-in of the cursor convention happens
in the #1667 spec, not here.

Consequence for phasing: the spec's P3 item "retire the socialware fork"
splits. The substrate half (generic table + generic apply, so the fork CAN
converge) is ② P3 below; the socialware half (actually converging
`Ezagent.Socialware.DeliveryOutbox` and its cursor onto it) moves to the
socialware protocol track (§4).

### Q5 — `:dead` operator surface: ops-only telemetry alert; unified-warning seam recorded

Spec §4.5 asked: alert threshold, and does a `:dead` grant surface in the
grantee's UI?

**Decision: ops-only for now.** A `:dead` row raises an operator alert past a
threshold; it does NOT surface as grantee-visible degradation. (A grantee who
never received a grant has no UI expectation to degrade; the operator is the
one who can act.)

**Finding to record (verified):** today a row going `:dead` is *silent* —
`apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex:296-299`
(`handle_failure_result({:dead, target_uri})` → `maybe_forget_target/1` →
`:ok`) and the `mark_dead` transition in
`cap/delivery_outbox/state.ex:87-108` emit no telemetry, no log-level event,
nothing an operator can subscribe to.

**And the structural finding:** ezagent has **no principled unified
warning/event bus** to hang this on:

- `Ezagent.CCEvents` (`apps/ezagent_core/lib/ezagent/cc_events.ex`) is
  CC-agent-failure-reporting-specific — an unauthenticated HTTP ingest that
  deliberately bypasses Invocation (its raison d'être is surviving a broken
  agent). Not a general channel.
- `Ezagent.Audit` (`apps/ezagent_core/lib/ezagent/audit.ex`) fans
  `[:ezagent, :invoke, :stop/:error]` (+ `[:ezagent, :authz, :granted/:denied]`)
  telemetry out to PubSub (`esr:audit:stream`) + async Postgres — but it is
  Invocation-event-scoped by charter.

**Mechanism chosen:** `:dead` transitions emit a telemetry event (e.g.
`[:ezagent, :delivery_outbox, :dead]` with `target_uri`/`op`/`attempts`/reason
metadata) and `Ezagent.Audit` — the closest thing to a general fanout —
attaches to it. Threshold/aggregation lives operator-side, not in the outbox.
Plus the small unified-warning-channel sub-item in §3.

**Security constraint (#187):** the existing streams currently over-deliver to
non-operators — that is open security item #187. The `:dead` alert MUST ride
the operator-gated stream; it must not widen #187's exposure by putting
delivery-failure metadata (who was being granted what) in front of
non-operators.

## 2. Phases

P0 from the spec (land #1501 — held ∪ pending effective view, idempotent
grant, fail-closed absorb) remains a precondition and is tracked in its own
board task (`docs/together/tasks/caps-consolidation-1501.md`); it is not
re-planned here.

### P1 — Durable-back the buffer (substrate-only)

Unchanged from the spec, now unblocked by Q3:

- Give `Ezagent.PendingDelivery`'s volatile ETS buffer
  (`apps/ezagent_actor/lib/ezagent/pending_delivery.ex`, `@max_per_uri 100`,
  lost on BEAM restart) a durable backing behind the EXISTING
  `outbox_port` (`apps/ezagent_actor/lib/ezagent/kind/ports/outbox_port.ex`,
  7 callbacks) — adapter/store change
  (`apps/ezagent_core/lib/ezagent/kind/adapters/outbox_adapter.ex`), not a
  port change. Per Q3 the durable store is `cap_delivery_outbox` itself, not a
  new table.
- Replace `maybe_reconcile_cold_load_identity/4`
  (`apps/ezagent_actor/lib/ezagent/kind/server.ex:309`, hardcoding
  `Ezagent.EntityCaps.Store.reconcile_cold_load_identity/3`) with a generic
  cold-load pull ("drain my durable pending rows on wake") through the same
  port; the identity reconcile becomes one client of it. `kind/server.ex`
  stops naming `EntityCaps.Store`.

**Gate (invariant tests):** substrate-level restart-survival — buffered
delivery to a not-ready actor survives BEAM restart and lands on next wake
(red today: ETS dies with the VM); cold-load pull proven for a non-identity
datum; identity reconcile behavior unchanged.

### P2 — Migrate grant delivery + resolve revoke via the repro test

Same release as P1 (Q1: one deploy).

- **Grant cutover** (the spec §2.3(a) worklist): `store_cap` (producer
  `:identity_grant`, `grant.ex:143-166`) and `persist_caps`
  (`entity_caps.ex:160-197`) become outbox-eligible at the dispatch
  chokepoint — ctx marker + action, zero caller churn (the pattern
  `:identity_absorb` already proved).
- **Revoke resolution per Q2**: run the repro test FIRST; execute (b) on the
  expected verdict (delete `envelope.ex:148-161`, fix the `grant.ex:168-181`
  moduledoc, optional reconcile sweep) or (a) on the unexpected one
  (`remove_cap` becomes eligible). Either way `revoke_cap_via_router/4` and
  its member-cap call sites are untouched.
- **Q5 mechanism lands here too** (it touches the same module): the
  `:dead`-transition telemetry event + `Audit` attachment + operator-gated
  alert.

**Gate:** the revoke repro test committed with its verdict encoded (red→green
if (a); green-as-spec — denied AND hidden post-restart — if (b));
grant-to-never-started-entity survives restart; `turn_survives_restart` class
stays green; `rg` proves zero cap-plane **grant** mutations reach the
volatile-only path; a synthetic `:dead` row produces the operator event on the
gated stream and nothing on non-operator streams.

### P3 — Generic table + CI grep-gate

- **Generic table** (Q3): widen the `op` check constraint's allowed values;
  generalize the apply side into a generic `op`-keyed apply-dispatch;
  Envelope's cap-specific encode/decode becomes the cap `op` family's
  implementation of it. Per-receiver drain semantics unchanged (design
  invariant, §1 Q3). This makes the substrate ready for non-cap producer
  families — including the socialware fork's eventual convergence, which is
  NOT executed here (Q4).
- **CI grep-gate**: forbid new bare cross-actor `GenServer.cast` in prod code
  outside an enumerated allowlist. Baseline = the spec §2.3(b) worklist
  (`live_join_registry.ex:37`, `domain/pty.ex:170`, `domain/python.ex:241`,
  `session/delivery_queue.ex:79`, + infra singletons), produced by an
  empty-allowlist run per the enumerator-gate discipline; shrink-only
  thereafter. Same invariant-test shape as `cap_absorb_reachability_test.exs`.
- ARCHITECTURE.md Decision-Log entry for the unified primitive.

**Gate:** cast-gate red on a synthetic violation, green on baseline; existing
cap outbox suite green verbatim on the widened schema; `ci.fast` budget
unchanged.

## 3. Sub-item: a named unified operator-warning channel (a seam, not a system)

The Q5 investigation surfaced a real gap worth one small, explicit step — and
no more than that:

- **Problem:** operator-facing warnings today are ad-hoc per source
  (`CCEvents` for CC failures, `Audit` for Invocation events, raw `Logger`
  elsewhere). Each new "the operator should know" signal — like `:dead` rows —
  has to pick a side or invent a third.
- **Proposal (sub-item, not a project):** designate and NAME one operator
  warning convention: a telemetry event namespace (e.g.
  `[:ezagent, :ops, :warning]` or an agreed equivalent) + one attach point in
  `Audit` (or a sibling one-module handler) that fans to the
  **operator-gated** stream + the audit store. Sources emit telemetry;
  the channel owns fanout and gating. That is the whole build: a naming
  decision, one handler, and a doc paragraph.
- **Explicitly deferred:** severity taxonomies, alert routing/dedup engines,
  paging integrations, any UI beyond the existing operator surfaces.
- **Gating requirement inherited from #187:** the channel is born
  operator-gated; it must not reproduce the current over-delivery to
  non-operators.

The `:dead` alert (P2) is the channel's first client; if the naming decision
lags P2, the `:dead` event ships on the concrete
`[:ezagent, :delivery_outbox, :dead]` name and the channel adopts it later —
the emit site doesn't move.

## 4. Open items / who owns what

| Item | Owner | Where it lives |
|---|---|---|
| P0 — #1501 read-side contract (held ∪ pending, idempotent grant, fail-closed absorb) | in flight (adversarial-review rework) | `docs/together/tasks/caps-consolidation-1501.md` |
| P1 + P2 — durable backing, generic cold-load pull, grant cutover, `:dead` telemetry (one deploy) | ② (this plan) | this doc §2 |
| Revoke repro test verdict + (a)/(b) execution | **jjkysy** (cap-model territory), coordinated with ② P2 | §1 Q2 |
| P3 — generic table widen + apply-dispatch + cast grep-gate | ② (this plan) | §2 P3 |
| Socialware `committed_seq` cursor convention + fork convergence onto the generic table | **jjkysy** — socialware protocol (#1667 answer-routing spec) | §1 Q4 |
| Unified operator-warning channel naming + single handler | ② proposes (§3); naming is Allen's sign-off | §3 |
| #187 — streams over-deliver to non-operators | existing security item, independent of ②; ② only constrains new emitters to the gated stream | §1 Q5, §3 |

**Out of scope, restated from the spec (unchanged):** chat/message fan-out,
signals, UI/projection notifies, infra singleton casts; `KindRegistry`
`put_new` semantics; plugin-extensible producer registry (closed set in v1);
revocation immediacy (owned by the generation gate — §0, §1 Q2).
