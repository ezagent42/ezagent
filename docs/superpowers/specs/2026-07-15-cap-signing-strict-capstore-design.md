# Cap-signing: single strict invariant + CapStore ownership — DESIGN

**Status**: design, pending codex adversarial review
**Supersedes**: `2026-07-15-cap-signing-no-tail-self-heal.md` (v3) — the always-on self-healer is **retired** in favor of this. PR #1424 (self-healer build) is shelved.
**Implementation basis**: branch fresh from current `main` — do NOT build on #1424. What each piece comes from:
- Already on `main`, reuse as-is: `Cap.issue` chokepoint, `Cap.Signing`, `entity_caps` facade.
- On `main`, **delete**: `verify_for/2`, `require_signature` / dual-read plumbing (in `cap.ex` + config).
- Lift the single sound function `signed_and_valid?/2` from #1424 (~15 lines) → promote to be the strict `verify`. Take nothing else from #1424.
- The self-healer machinery (reconciler/sweeper/quarantine/self_heal/reissue_policy) exists **only** on #1424 and was never merged — abandon it, nothing to delete from `main`.
**Implementer**: coordinator (Claude) directly, NOT codex — the work couples app-side code with the ezagent-deploy cutover, kept under one owner. codex's role here is the architecture-level adversarial review of this design only.
**Context**: self-use phase, no formal production. This lets us **delete dual-read** and do a **hard cutover** instead of a careful migration. Nearly all existing caps are unsigned (signing only began working on canary today), so this is a whole-population re-sign, not a trickle-tail drain — which favors a one-shot cutover over a convergence machine.

## 1. Why (the problem the self-healer had)

Two adversarial-review rounds of the self-healer surfaced a recurring bug class, all rooted in two structural facts:

1. **Two verify predicates.** `verify_for/2` (dual-read, accepts unsigned) coexisted with `signed_and_valid?/2` (strict). Every round, `verify_for` crept back in as a signed-ness classifier → false-zero audits, unsigned caps closing their own quarantine rows.
2. **One cap, many home-writers.** A cap lives in up to four homes (`caps_json`, snapshot slice, live slice, recipe binding). Revoke/heal/activation/snapshot-persist each wrote *some* homes directly, so they drifted → revoke-resurrection, partial two-home writes, snapshot-version corruption.

The self-healer tried to *reconcile* this drift at runtime (reconciler + sweeper + quarantine + CAS), which is a hard distributed-convergence problem with crash windows and races — hence the repeated regressions.

This design **removes both root causes** rather than reconciling their symptoms.

## 2. Invariants (north star)

1. **Born signed.** Every capability is created through `Cap.issue/3`, which signs it. There is no other way to mint a cap.
2. **One predicate.** `verify` = `signed_and_valid?` (signature + key_id + grantee-URI binding + crypto-valid, receiver-aware). It is the *only* cap predicate. Unsigned/invalid → **rejected, fail-loud**. `verify_for/2` and dual-read do not exist.
3. **One owner.** All cap storage is owned by a single `CapStore`. Every read and every mutation of an entity's cap set goes through it. No other code writes any cap home.

If these three hold, the entire bug class from §1 is structurally impossible: no unsigned cap can be accepted anywhere (inv. 2), and no home can drift because there is one writer (inv. 3).

## 3. Architecture

```
callers ─▶ EntityCaps (domain API: grant/revoke/read, authz + receiver semantics)
                      │  (delegates ALL persistence)
                      ▼
              CapStore (storage authority — SOLE writer of the homes)
                      │
        ┌─────────────┼───────────────┬──────────────────┐
     caps_json   snapshot slice   live slice      recipe binding
     (durable)     (durable)      (cache)          (durable)
```

- **`EntityCaps`** stays as the domain-facing API (who may grant/revoke, receiver-aware verified sets). It contains **no persistence** — it delegates every mutation and read to `CapStore`.
- **`CapStore`** (new, layered module) is the storage authority. It is the *only* code that reads or writes the cap homes. It guarantees the storage invariants below.
- **`Cap.issue/3` + `Cap.Signing`** unchanged — the signing chokepoint. Seed is configured (`EZAGENT_SIGNING_SEED_V1`, set 2026-07-15).
- **`signed_and_valid?`** is renamed/promoted to be *the* `verify`. `verify_for/2` is deleted.

### CapStore storage invariants (design-level; mechanics are impl constraints)

- **Durable is truth; live is a derived cache.** The durable homes (`caps_json` / snapshot slice / recipe binding — whichever apply to the entity kind) are the source of truth. The live slice is rebuilt from durable on activation and never read as an independent authority.
- **Atomic multi-home write.** A single mutation writes all *applicable* durable homes in one DB transaction. The live slice is updated only after the transaction commits. A crash mid-mutation leaves durable either fully-old or fully-new; on restart the live slice is rebuilt from durable → no lasting divergence. (This is what kills partial two-home writes and revoke-resurrection.)
- **Signed-only writes.** `CapStore` refuses to persist an unsigned/invalid cap (fail-loud). Combined with `Cap.issue` being the only minter, every cap in every home is signed by construction.
- **CAS on mutation.** Mutations compare-and-swap against the exact expected prior cap-set (or exact prior artifact for targeted edits) to prevent lost updates and ABA. It does **not** use the snapshot schema-version field as a revision counter (that field stays the Kind's declared schema version).
- **Which homes apply is by entity kind**, encapsulated inside CapStore (a user has `caps_json`; a running kind has snapshot+live; a recipe binding is pre-agent). Callers never know or choose homes.

## 4. Deleted (the payoff)

- `require_signature` config flag / all dual-read plumbing.
- `Cap.verify_for/2`.
- The whole self-heal subsystem: `cap_reconciler`, `cap_signing_sweeper`, `cap_quarantine` (+ its table/ledger), `cap/heal_executor`, `cap_self_heal`, `entity_caps/snapshot_store` (CAS adapter), all `cap_reissue_policy` modules (session/workspace/world) + their registry.
- `cap_signing_audit` as a **permanent subsystem** — see §6 (it survives only as a one-shot pre-cutover check, run by deploy, not app runtime).

## 5. Kept / changed

- **`Cap.issue` chokepoint gate — simplified.** The build-time invariant test drops the per-class *reissue-policy coverage* logic (only the self-healer needed it). It keeps and strengthens one thing: **all cap issuance goes through `Cap.issue`** (no code path mints a cap another way). It must inspect the actual issuance call sites, not hand-authored fixtures.
- **New invariant gate — sole home-writer.** A build-time test asserting that **no module other than `CapStore` writes any cap home** (`caps_json` cap field / snapshot cap slice / recipe binding artifacts). This is what keeps invariant 3 from eroding over time.
- **Strict-verify test.** Authorization rejects an unsigned/invalid cap (fail-loud), proving `verify` is strict.

## 6. Cutover (OUT OF SCOPE — ezagent-deploy)

The whole-population re-sign is a **deploy operation, not app code**: deploy the new build (signing on, dual-read gone) → **wipe the cap-bearing data → run seed (signed)**. Data is disposable (self-use), so this is a clean restart, done per channel (dev/canary/beta/stable) via an ezagent-deploy runbook/script alongside `reflow.sh`. **There is no app-side migration/backfill code.** Tracked as a separate ezagent-deploy task.

## 7. Testing

- Sole-home-writer invariant gate (§5) — RED if any non-CapStore module writes a home.
- Issuance-chokepoint gate (§5) — RED if any cap is minted outside `Cap.issue`.
- Strict `verify` — unsigned cap rejected at authorization.
- CapStore atomicity — a mutation writes all applicable durable homes or none; a simulated mid-mutation crash leaves durable consistent and live rebuilds from it (regression test for revoke-resurrection + partial two-home write).
- CapStore CAS — concurrent mutations don't lose updates; ABA (revoke→different-issuer regrant) is rejected.
- Revoke clears every applicable home (regression for the binding-path resurrection).

## 8. Resolved / open

- **OQ-1 — RESOLVED**: `recipe_cap_binding` **is** a durable home CapStore owns, refreshed through the same atomic write path. Forced by invariant 3 (sole owner): if binding were materialized outside CapStore, some other code would write a cap home. So binding is a CapStore-owned home; no code but CapStore writes bindings.
- **OQ-2 — open, impl-level (codex/implementer's call at build)**: exact CAS token granularity — whole cap-set optimistic version vs per-artifact. Leaning: whole-set version for mutations; per-artifact only where a targeted single-cap edit is needed. Not an architecture decision; resolve against the real code.
