# Cap-signing: strict verify at the authorization chokepoint — DESIGN (v5)

**Status**: v5 — addresses codex v4 review. v4 confirmed SOUND on scope (dropping storage consistency is safe for X) and feasibility (pre-signing reachable); v5 fixes the load-bearing correction: verification must gate the **authorization predicate**, not just `Cap.verify`. Pending re-review.
**Supersedes**: the self-healer spec (retired) + the CapStore-consistency design of v1–v3 (out of scope). PR #1424 shelved.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover).
**Context**: self-use phase → hard cutover (wipe+reseed). Existing caps ~all unsigned.

## 1. The X problem
Capabilities are **forgeable / tamperable / retargetable** under soft verification (dual-read accepts unsigned). **Goal: every capability signed and strictly verified at the authorization decision, so unproven authority is rejected — closing capability forgery as a privilege-escalation / credential-theft vector.**

## 2. Non-goals (explicitly OUT)
- **Cap-storage consistency** (multi-home caps, revoke-clears-all, CapStore consolidation/rehydration/locks). Separate concern. (v4 review confirmed: a revoked-but-resurrected *signed* cap is a consistency bug, NOT forgery/tamper/retarget — out of X. Retargeting a mis-homed signed cap is impossible: the signature binds grantee, so verify rejects it.)
- Distribution / cross-node (deferred).
- The self-healer — deleted, not redesigned.

## 3. Invariant
1. **Born signed** — every cap minted only through `Cap.issue/3` (signs).
2. **The authorization chokepoint verifies signatures.** The single strict, receiver-aware predicate gates the *actual authorization decision*, not merely the artifact API. It must be enforced in `capability/authorization.ex` (`authorizing_cap`/`matches?`) and **every consumer that matches a cap to authorize an action** (PTY `may_read?`, notification `check_subscribe_cap`, every `Capability.matches?` caller). A cap authorizes an action ONLY if: signed + crypto-valid + its **grantee == the presenter/holder** (`ctx.caller`, NOT the dispatch target). **Shape-matching a cap without verifying its signature is forbidden.** `verify_for/2`, dual-read, `require_signature` deleted; the receiver comparison folds into this one predicate.
   - *Why v4 was wrong*: `authorization.ex` today does `granted_by_entity?` + `Capability.matches?` and never calls `Cap.verify`, so flipping `Cap.verify` leaves a forged unsigned `Manage/:read` cap authorizing a PTY read by shape. The fix is to route verification **through the authorization predicate and all consumers**, not just the artifact function.
3. **Bounded issuance for every principal.** Non-entity principals (`session://`, `workspace://`, worker) are signable — the same data structure, HKDF key per principal URI. Self/structural caps are issued under a **bounded structural issuance rule**: an explicit allowlist binding `(granter, grantee, target, permitted cap shape)`. **`{:genesis, _}` is NOT reused for non-admin self-issuance** — it grants the admin wildcard to any URI, so a session self-cap site using `{:genesis, session_uri}` would let an attacker-influenced proposal be signed as that session (impersonation). Genesis stays admin-only.

## 4. Implementation method — verify at the chokepoint, gate by consumer inventory
1. **Delete dual-read**; make the strict receiver-aware predicate THE authorization check, routed through `authorization.ex` + every consumer (§3.2).
2. **Static completion gate (the real completion criterion).** A build-time inventory test enumerates **every authorization consumer** — every caller of the authorize/match predicate and every direct `Capability.matches?` / cap-shape check — and asserts each authorizes only through the verifying predicate. This replaces "green tests + clean canary" (which can't prove it — an untested shape-match path would silently accept a forged cap). Constructors are covered by the `Cap.issue` chokepoint; *consumers* are covered by this inventory.
3. **Extend signing** to all granter principals (HKDF per principal URI; relax the entity://-only provenance constraint).
4. **Bounded structural issuance rule** — implement the allowlist (§3.3); migrate every self/inline/dynamic/genesis issuance site onto signed issuance under it. Fresh admin spawn **pre-issues its signed genesis** (today it inserts a raw unsigned genesis cap — replace).
5. **Fail-loud + telemetry**: rejected caps at load/authorization boundaries emit observable errors/telemetry, never silent filtering (today collection verify silently drops rejected members).
6. **Self / dynamic authority**: pre-issue signed self-caps at spawn under the bounded rule, carry in state (self-dispatch presents the in-hand signed cap — no issue/load at dispatch → no self-read deadlock). Dynamic target-specific caps (e.g. agent-reply `session.send`) are issued JIT under the bounded rule *at the point the target is known* — NOT replaced by a broad pre-issued wildcard (that would be escalation).
7. **Delete the self-healer** (reconciler/sweeper/quarantine/heal/reissue-policy).

## 5. Cutover (ezagent-deploy scope)
Wipe cap data + reseed signed (self-use, disposable). No app-side migration code. Order: quiesce → wipe → deploy strict build → signed seed (boot constructors issue signed) → resume.

## 6. Testing / gates
- **Consumer-inventory gate (§4.2)** — every authorization consumer verifies; RED if a new shape-match-without-verify path appears. (This is the invariant's real guard.)
- Strict predicate: forged/unsigned/wrong-holder cap rejected at the authorization decision — explicit regression for the PTY-read and notification-subscribe forgery scenarios.
- All principals (entity/session/workspace/worker) sign + verify; the bounded issuance rule REJECTS an out-of-allowlist proposal (impersonation attempt).
- Genesis/self/dynamic caps signed; self-dispatch works, no deadlock; strict verify holds end-to-end on a freshly seeded stack; rejected caps emit telemetry.

## 7. Open (impl-level)
- Exact allowlist schema for the bounded structural issuance rule (granter/grantee/target/shape tuple + where it lives).
- HKDF derivation extension for non-entity principal URIs.
- The precise set of authorization consumers to enumerate in the §4.2 gate (discovered by grepping `Capability.matches?` / `authorizing_cap` callers).
