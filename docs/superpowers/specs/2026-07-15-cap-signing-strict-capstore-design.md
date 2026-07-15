# Cap-signing: strict verify, sign every cap — DESIGN (v4, rescoped)

**Status**: v4 — RESCOPED per lead. v1–v3 conflated **strict signing** (the goal) with **cap-storage consistency** (CapStore multi-home / rehydration / locks / snapshot separation). This spec is ONLY the signing goal; the consistency machinery is dropped (§2). Pending codex adversarial review.
**Supersedes**: the self-healer spec (`…no-tail-self-heal.md`, retired) and the CapStore-consistency design of v1–v3 (out of scope — §2). PR #1424 shelved.
**Implementer**: coordinator (Claude) directly (app change + ezagent-deploy cutover under one owner). codex = architecture-level adversarial review only.
**Context**: self-use phase, no formal production → hard cutover (wipe + reseed), no dual-read migration. Existing caps are ~all unsigned.

## 1. The X problem
Capabilities are **forgeable / tamperable / retargetable** because verification is soft (dual-read accepts unsigned artifacts). **Goal: every capability cryptographically signed and strictly verified, so any unproven authority is rejected — closing capability forgery as a privilege-escalation / credential-theft vector.**

X needs exactly two things: (i) every cap **born signed**, (ii) **strict verification at the authorization point** (reject anything not cryptographically proven). Everything else in prior drafts was not X.

## 2. Non-goals (explicitly OUT)
- **Cap-storage consistency** — a cap living in multiple homes (caps_json / snapshot / binding / live), revoke clearing every home, the `CapStore` multi-home consolidation, rehydration contract, per-entity locks, snapshot/cap separation. Separate concern; tackle it on its own only if a real revoke/consistency bug surfaces. Note strict verify already rejects any *unsigned* resurrection; only a *signed*-cap consistency bug would remain, and that is out of scope here.
- **Distribution / cross-node** — deferred (shared-seed, single logical node).
- The self-healer — deleted, not redesigned (§4.5).

## 3. Invariant
1. Every authority capability is minted only through `Cap.issue/3`, which signs it.
2. `verify` is the single, **receiver-aware, strict** predicate: crypto-valid AND signed AND grantee bound to the receiving entity. Unsigned / invalid-signature / wrong-receiver → **fail-loud reject**. `verify_for/2`, dual-read, and `require_signature` are removed; the receiver comparison currently in `verify_for` is folded into the one `verify`.
3. **Every granter principal is signable.** `session://`, `workspace://`, worker, etc. are the *same cap data structure* as `entity://` caps — they are signed and verified the same way. The current "granted_by must be `entity://`" provenance constraint is relaxed: signing-key derivation (HKDF per principal URI) and provenance validation cover all principal URIs. (Per site, the alternative is to re-attribute the granter to an accountable entity — an impl choice, not an exclusion.)

## 4. Implementation method — flip strict, fix each fail-loud break
Not a compatibility scheme; a fail-loud-driven sweep.
1. **Delete dual-read**; make `verify` strict + receiver-aware (§3.2).
2. **Extend signing** (`Cap.issue` / `Cap.Signing` / `verify` / provenance) to all granter principals (§3.3).
3. **Run the suite.** Every code path that produces or presents an unsigned cap now **errors**. Fix each site to issue a properly-signed cap: genesis admin cap, self/inline authority, `session.send`, workspace/session config caps, cross-session forwarding, dynamic per-message caps, and every direct `Cap.issue` site. A green suite under strict verify means every *exercised* site signs.
4. **Coverage beyond tests**: strict `verify` at the authorization chokepoint means any unsigned cap fails **at use**, in tests AND at runtime — so untested sites surface as fail-loud errors in canary (self-use), not silent acceptance. Green suite + a clean canary strict run = the worklist is exhausted. (This is why a hard strict flip is safe here where a partial/dual-read one was not.)
5. **Self-dispatch deadlock** (today `ctx.caps` carries unsigned inline authority to avoid a self-read re-entry): fix at that site — pre-issue the signed self-cap at spawn (via a non-loading issuance context, NOT `{:held_by, self}` which loads not-yet-existing authority) and carry it in state; self-dispatch presents the in-hand signed cap (no issue/load at dispatch → no re-entry).
6. **Delete the entire self-healer** (reconciler / sweeper / quarantine + table / heal_executor / self_heal / snapshot_store CAS adapter / reissue_policy ×N + registry) — unnecessary, and the source of the prior consistency bugs.

## 5. Cutover (ezagent-deploy scope, out of app spec)
Wipe cap data + reseed signed (data disposable in self-use). No app-side migration/backfill code. Order: quiesce writers → wipe cap data → deploy strict build → run signed seed (boot constructors issue signed caps) → resume.

## 6. Testing / gates
- `verify` strict + receiver-aware: unsigned / bad-signature / wrong-receiver authority rejected fail-loud.
- **Every issuance site signs** — the full suite passing under strict verify IS the proof (each unsigned site fail-louds); supplement with a canary strict run to surface untested sites.
- All granter principals (entity / session / workspace / worker) sign + verify.
- Build gate: no cap is minted outside `Cap.issue` (the signing chokepoint) — the real invariant is the runtime strict verify; the gate is a secondary regression aid.
- Genesis + self/inline/dynamic caps signed; self-dispatch works and does not deadlock; strict verify holds end-to-end on a freshly seeded stack.

## 7. Open (impl-level)
- HKDF key-derivation extension for non-entity principal URIs (mechanically identical to entity derivation).
- The non-loading issuance context for self-caps (`{:genesis,…}` reuse vs a bounded structural tag) — resolve per site.
- Per-site choice where a cap is granted by `session://`/`workspace://`: sign as that principal vs re-attribute to an accountable entity.
