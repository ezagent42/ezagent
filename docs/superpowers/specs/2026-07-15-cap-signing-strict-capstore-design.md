# Cap-signing: single strict invariant + CapStore ownership — DESIGN (v3)

**Status**: design v3 — addresses codex arch reviews of v1 (7 holes) and v2 (gap-4 closed; remainder now concrete). Pending re-review.
**Supersedes**: `2026-07-15-cap-signing-no-tail-self-heal.md` (self-healer) — retired. PR #1424 shelved.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover under one owner). codex = architecture review only.
**Context**: self-use phase → delete dual-read, hard cutover. Existing caps are ~all unsigned → whole-population re-sign.

## 1. Why
The self-healer failed twice on one bug class from two roots: **two verify predicates** and **many home-writers** that drift. v3 removes both roots and, per the v2 review, **separates cap authority storage from the snapshot blob** so a single owner can hold the invariant.

## 2. Invariants
1. **Born signed** — every authority cap is minted only via `Cap.issue/3` (signs).
2. **One predicate** — `verify` is the single, **receiver-aware**, strict predicate (crypto-valid AND signed AND grantee bound to the receiving entity). Unsigned/invalid → fail-loud reject. Exactly one predicate; today's receiver comparison (`verify_for`) is folded into it, not deleted.
3. **One owner** — `CapStore` is the only reader/writer of authority. Mutations are atomic + serialized per entity; durable authority stores are truth; the live slice is a derived cache.

## 3. Authority vs non-authority (type split)
- **Signed authority artifact** — grants power; MUST be signed + pass `verify`; CapStore-owned; lives only in authority stores (§4).
- **Non-authority cap-shaped records** — never consulted as authority, never verified, not CapStore-owned, may be unsigned: `OutboundGrant` (audit/revoke ledger), `CompositionBinding` (derivation ledger, serialized without sig/key/grantee), EventLog/audit, recipe manifests, requested-cap descriptors. A build test asserts none is ever loaded into an authorization path.

## 4. Storage — cap authority SEPARATED from the snapshot blob (the key v3 decision)
Today caps live in `caps_json` **and** the full-Kind snapshot blob (written by generic code, separately) → the generic snapshot writer can overwrite a CapStore cap update (resurrection), and "wipe snapshots" would destroy all state. v3 **removes caps from the snapshot blob entirely.**

Dedicated authority stores (CapStore-owned):

| Entity kind    | Durable authority store                       | Live cache |
|----------------|-----------------------------------------------|------------|
| User           | `users.caps_json`                             | live slice |
| Ordinary Agent | new `entity_caps` table, keyed by entity URI  | live slice |
| Recipe Agent   | recipe binding + `entity_caps`                | live slice |

- **The snapshot blob no longer contains the cap slice.** Full-state snapshot persistence excludes caps; it can never write or resurrect authority. Activation loads non-cap state from the snapshot and **authority from CapStore's stores** (each artifact re-`verify`d at load).
- CapStore is the *sole* writer of `caps_json` cap data, `entity_caps`, and recipe bindings.
- Live slice = derived cache rebuilt from the stores on activation; never an independent authority source. `Kind.default_holds_cap?` / `EntityCaps.load` read the live cache, now guaranteed to mirror the stores.

## 5. Mutation seam — per-entity serialization (gaps 1 & 3)
A grant/revoke to entity X:
- Takes a **per-entity lock** (row lock on X's authority store). Activation ALSO takes this lock when loading X's authority → a cold-target write and a concurrent activation **serialize on the lock** (no live/cold TOCTOU; no need to force-activate a cold target).
- Writes all applicable authority stores in **one DB transaction** under the lock, with a **CAS** on X's cap-set revision (`rev` column; whole-set optimistic version; per-artifact only for targeted edits).
- If X is **live**, the same serialized path updates X's live cache via X's mailbox (serializes with X's other state changes); if X is **cold**, only durable is written and X rebuilds live from the stores (under the lock) at next activation.
- Caps being separated from the snapshot blob (§4) means no competing full-state writer can overwrite the update.

## 6. Boot / genesis / self-authority under strict verify (gap 2)
**CapStore never issues — the domain layer issues (signs), CapStore persists.**
- **Genesis admin cap**: provisioning issues `Cap.issue({:genesis, admin}, admin_uri, wildcard)` (genesis context authorizes structurally without loading prior authority — non-circular) and inserts the admin row **and** its signed genesis cap in **one transaction** (no capless-admin crash window).
- **Inline/self authority**: enumerate every current unsigned inline/self/owner shape (self-cap, owner-cap, inline publish + subscribe authority in `kind/runtime.ex`). At spawn the domain layer issues each via `Cap.issue` with a **non-loading context** (a structural/genesis-like tag — NOT `{:held_by, new_entity}`, which loads the not-yet-existent entity's authority → circular). CapStore persists the signed self-caps; activation loads them into live. Self-dispatch presents the **already-in-hand signed self-cap from state** — no issuance/load at dispatch → the self-read deadlock `ctx.caps` exists for is not reintroduced, and `verify` passes.

## 7. Verify & read contracts
- **One receiver-aware predicate** `verify(artifact, receiver_uri)` = crypto-valid AND signed AND grantee-URI bound to `receiver_uri`. `verify_for` the *name* is removed; its receiver comparison IS this predicate. No receiver-blind predicate is used for authority.
- **Fail-loud read**: CapStore.read returns only verified authority; an invalid/unsigned artifact in an authority store **raises** (post-cutover unsigned authority = corruption → crash, not silent drop — replacing today's silent-filter).

## 8. Deleted
`require_signature`/dual-read · `verify_for/2` as a separate predicate (folded into §7) · self-heal subsystem (reconciler, sweeper, quarantine+table, heal_executor, self_heal, snapshot_store CAS adapter, reissue_policy ×N + registry) · **the cap-delivery replay outbox** · caps in the snapshot blob (§4). `cap_signing_audit` survives only as a one-shot pre-cutover deploy check.

## 9. Layering (gap 6)
`Identity.Grant` (sole grant/revoke authorization chokepoint) → `EntityCaps` (domain semantics, receiver-aware) → `CapStore` (persistence; sole authority-store writer; never authorizes/issues). Recipe handling splits: issuance/authorization (`Cap.issue`, domain) vs binding persistence (CapStore).

## 10. Enforcement (gap 5)
Resolved structurally by §4's separation: the `entity_caps`/`caps_json`-cap/binding write functions are **private to CapStore**; the generic snapshot writer no longer touches caps. Runtime `verify` on every authority read + CAS on every mutation are the real guarantees. Two build tests are secondary regression aids: issuance only via `Cap.issue`; no module outside CapStore references the authority-store write functions.

## 11. Cutover (ezagent-deploy scope)
Because caps are separated (§4), cutover wipes only the **authority stores** (`caps_json` cap data, `entity_caps`, recipe bindings) — NOT the full snapshots (non-cap state survives). Order: quiesce writers → wipe authority stores → deploy strict build → run signed seed (boot constructors §6 issue signed) → resume. No app-side migration code. Non-authority records exempt.

## 12. Testing
- No module outside CapStore writes an authority store; issuance only via `Cap.issue`; generic snapshot never writes caps.
- One receiver-aware `verify`: unsigned/invalid or wrong-receiver authority rejected; non-authority record never accepted as authority; invalid authority in a store raises on read.
- Seam: mutation writes all applicable stores or none; cold-write vs concurrent-activation serialize on the per-entity lock (no TOCTOU); crash → durable consistent, live rebuilt; CAS rejects ABA (revoke→different-issuer regrant); revoke clears every store incl. binding.
- Boot: signed genesis + admin row in one txn; every enumerated self/inline authority is signed and present; self-dispatch works and does not deadlock; strict verify holds end-to-end on a freshly seeded stack.

## 13. Open (impl-level)
- CAS `rev` column placement + whole-set vs per-artifact granularity — resolve against code.
- Exact non-loading issuance tag for self-authority (`{:genesis,…}` reuse vs a new `{:structural, entity}` tag).
