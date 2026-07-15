# Cap-signing: single strict invariant + CapStore ownership — DESIGN (v2)

**Status**: design v2 — addresses the codex architecture review of v1 (5 under-specified areas). Pending re-review.
**Supersedes**: `2026-07-15-cap-signing-no-tail-self-heal.md` (v3, self-healer) — retired. PR #1424 shelved.
**Implementer**: coordinator (Claude) directly, NOT codex — app + ezagent-deploy cutover kept under one owner. codex's role is architecture-level adversarial review only.
**Context**: self-use phase, no formal production → delete dual-read, hard cutover. Nearly all existing caps are unsigned (signing only began on canary 2026-07-15) → whole-population re-sign, not a trickle-drain.

## 1. Why

Two adversarial rounds of the self-healer failed on one bug class, rooted in two facts: **two verify predicates** (`verify_for` dual-read kept creeping in as a classifier) and **many home-writers** (a cap lived in several stores that drifted). This design removes both root causes instead of reconciling their symptoms at runtime.

## 2. Invariants (north star)

1. **Born signed.** Every *authority* capability is minted only through `Cap.issue/3`, which signs it. No other path mints authority.
2. **One predicate.** `verify = signed_and_valid?` (signature + key_id + grantee-URI binding + crypto, receiver-aware) is the *only* authority predicate. Unsigned/invalid authority → rejected, fail-loud. `verify_for/2` and dual-read are deleted.
3. **One owner.** A single `CapStore` is the only code that reads or writes any cap *authority* home. All mutation is atomic across the applicable homes; durable is the source of truth, live is a derived cache.

## 3. Authority vs non-authority (the type distinction — gap 4)

Not every cap-shaped record is authority. The design splits two kinds:

- **Signed authority artifact** — a real capability that grants power. MUST be signed; MUST pass `verify`; owned exclusively by CapStore. Lives only in authority homes (§3.1).
- **Non-authority cap-shaped records** — never consulted as authority, never verified, not CapStore-owned, may be unsigned by design:
  - `OutboundGrant` — audit/revoke ledger of what was issued (explicitly not an inbound authority source).
  - `CompositionBinding` — a derivation ledger; its serialized copy deliberately omits signature/key_id/grantee.
  - EventLog / audit copies, recipe manifests, and *requested-cap descriptors* (config, not grants).

"All persisted **authority** is signed" — scoped to authority artifacts. Non-authority records are out of CapStore's ownership and out of `verify`. A build gate asserts non-authority records are never loaded into an authorization path.

## 3.1 Authority homes — complete per-kind matrix (gap 4)

CapStore owns exactly these durable homes and the derived live cache:

| Entity kind      | Durable authority homes                    | Live cache |
|------------------|--------------------------------------------|------------|
| User             | `users.caps_json` + snapshot cap-slice     | live slice |
| Ordinary Agent   | snapshot cap-slice                         | live slice |
| Recipe Agent     | recipe binding + snapshot cap-slice        | live slice |

- The **live slice** (in-memory in the Kind process) is a *cache*, rebuilt from durable on activation. It is never an independent authority source.
- **There is no cap-delivery outbox** — see §3.2. There is no quarantine ledger (deleted with the self-healer).
- Recipe binding is written before the agent process exists (it is designed to persist without dispatching to a grantee); CapStore owns that write directly.

## 3.2 Cap delivery = durable write, not a replay queue (gap 1)

The v1 model omitted `cap_delivery_outbox`, a durable **replayable** store whose rows re-apply grant/revoke on boot/retry — a revoke-resurrection vector (a pending `:absorb_cap` row replays after a later revoke).

**Resolution — delete the replay outbox.** A grant/revoke is applied by CapStore writing the *target's* durable authority home in one transaction. A cold target picks it up from durable on activation (live rebuilt from durable); a live target is updated via the seam in §3.3. No separate durable replay queue exists, so there is nothing to replay out of order. (Cross-node async delivery is a distribution concern, explicitly deferred; single logical node / shared-seed for now.)

## 3.3 The atomicity seam (gap 3)

- **Mutations to a live entity run inside that entity's Kind mailbox** (serialized with all its other state changes). The handler performs one DB transaction writing all applicable durable homes, then updates the live slice in the same handler. Serialization + single-txn = no partial multi-home write.
- **Mutations to a cold entity** write durable directly (no live to update). On activation the live slice is built from durable.
- **Crash semantics**: the durable transaction is all-or-nothing; the live slice is *always* rebuilt from durable on (re)activation. So a crash can never strand live-only authority that diverges from durable.
- **The generic snapshot writer must not independently write the cap slice.** The full-Kind snapshot persist either excludes the cap slice (CapStore owns it) or writes it only via CapStore, so a stale full-state snapshot cannot overwrite a CapStore cap update. The post-init best-effort snapshot path must not mutate cap authority.
- **CAS**: a mutation compares against the entity's current cap-set revision (optimistic version) inside the mailbox-serialized transaction; a mismatch aborts. Because delivery is a direct durable write (no async replay), the CAS expectation is read and checked in the same serialized transaction — there is no cross-boundary stale replay to terminate.

## 3.4 Boot / genesis / self-dispatch under strict verify (gap 2)

Strict `verify` breaks two currently-unsigned paths; both are fixed at their source:

- **Genesis admin cap.** First-boot provisioning currently writes a *raw* `admin_genesis_cap` into `caps_json`. Replace with a signed issuance: `Cap.issue({:genesis, admin}, admin_uri, wildcard)` (the genesis context authorizes structurally without loading prior authority — non-circular) → CapStore writes the signed artifact. Requires the signing seed present at boot (configured: `EZAGENT_SIGNING_SEED_V1`). Signed genesis is issued **before** the admin row / Kind is created.
- **Inline self-authority (`ctx.caps`).** Self-dispatch currently injects raw unsigned caps to avoid a self-read deadlock. Replace with **pre-issued signed self-authority**: at spawn, CapStore issues the entity's bounded self-cap (signed) and stores it in the entity's own durable home; it is loaded into live state at activation. Self-dispatch then *presents the already-in-hand signed self-cap from state* — no issuance and no authority re-load at dispatch time, so the self-read deadlock is not reintroduced, and strict `verify` passes. (The failure mode to avoid: issuing/loading self-authority *at dispatch time*, which re-enters the loader. Pre-issue-at-spawn + carry-in-state avoids it.)

## 4. Deleted

`require_signature` / dual-read plumbing · `Cap.verify_for/2` · the self-heal subsystem (reconciler, sweeper, quarantine + table, heal_executor, self_heal, snapshot_store CAS adapter, all reissue_policy modules + registry) · the **cap-delivery replay outbox** (§3.2). `cap_signing_audit` survives only as a one-shot pre-cutover check run by deploy, not app runtime.

## 5. Kept / changed

- `Cap.issue` chokepoint + `Cap.Signing` — unchanged (seed configured).
- `signed_and_valid?` → promoted to be the only `verify` (strict).
- **Enforcement is structural, not source-scan (gap 5).** CapStore exposes the *only* API that constructs a persistable authority artifact and writes an authority home; the schema-level cap-write functions are private to CapStore (a module physically cannot write an authority home otherwise). Runtime `verify` on every authority read + CAS on every mutation are the real guarantees. Two build-time tests remain as *secondary* regression aids (not the invariant): issuance goes through `Cap.issue`; no module outside CapStore references the authority-home write functions.

## 6. Layering call graph (gap 6)

`Identity.Grant` (the single grant/revoke authorization chokepoint) → `EntityCaps` (domain semantics, receiver-aware) → `CapStore` (storage authority; sole home writer). Recipe handling is split: **issuance/authorization** (`Cap.issue`, in the domain layer) is separated from **binding persistence** (CapStore-owned). CapStore never authorizes or issues — it only persists already-signed artifacts and enforces CAS/atomicity.

## 7. Cutover (ezagent-deploy scope — gap 7)

Deploy runbook order, **out of app spec**: **quiesce writers / stop accepting traffic → wipe every authority + previously-replayable store (caps_json cap data, snapshots, recipe bindings; the outbox is gone) → deploy strict build → run signed seed → start / accept traffic.** No app-side migration code. The app's boot constructors (§3.4) issue signed authority, so a fresh reseed produces only signed authority. Non-authority records (composition bindings, audit) are exempt from "all signed."

## 8. Testing

- Structural: no module outside CapStore calls an authority-home write fn; issuance only via `Cap.issue`.
- Strict `verify`: unsigned/invalid authority rejected at authorization; a non-authority record is never accepted as authority.
- CapStore atomicity: a mutation writes all applicable durable homes or none; simulated mid-mutation crash → durable consistent, live rebuilt from it (regression for revoke-resurrection + partial write). Generic snapshot write cannot overwrite a CapStore cap update.
- CapStore CAS: concurrent mutations don't lose updates; revoke→different-issuer regrant (ABA) rejected.
- Revoke clears every applicable home (binding included).
- Boot: signed genesis before admin row; self-dispatch works with pre-issued signed self-authority and does not deadlock; strict verify holds end-to-end on a freshly seeded stack.

## 9. Resolved / open

- **OQ-1 RESOLVED**: recipe binding is a CapStore-owned durable home (forced by invariant 3).
- **OQ-2 (impl-level)**: CAS token granularity — whole-set optimistic version for mutations; per-artifact only for targeted single-cap edits. Resolve against real code at implementation.
