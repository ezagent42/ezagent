# Cap-signing: one verifying authorization chokepoint, principal-agnostic caps — DESIGN (v6)

**Status**: v6 — full consolidation per lead. Addresses codex v5 review (which mapped the real authorization surface: ~20+ scattered hand-written cap matchers, each an unverified decision). Pending re-review.
**Supersedes**: the self-healer spec (retired) + CapStore-consistency design of v1–v3 (out of scope). PR #1424 shelved.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover).
**Context**: self-use phase → hard cutover (wipe+reseed). Existing caps ~all unsigned.

## 1. The X problem
Capabilities are **forgeable / tamperable / retargetable** under soft verification. **Goal: every cap signed and strictly verified at the authorization decision, so unproven authority is rejected — closing capability forgery as a privilege-escalation / credential-theft vector.**

## 2. Guiding principle (lead)
**A capability is principal-agnostic.** A cap issued by a session, a workspace, or an entity is the *same thing* — same data structure, same signing, same verification, same authorization treatment. **There are NO per-principal-type branches** anywhere in issuance or authorization. "Where it was called from" is irrelevant; only the cap's own fields (granter, grantee, target, shape, signature) matter.

## 3. Non-goals (OUT)
- **Cap-storage consistency** (multi-home caps, revoke-clears-all, CapStore consolidation). Separate concern (v4 review confirmed a resurrected *signed* cap is a consistency bug, not forgery — out of X).
- Distribution / cross-node (deferred). The self-healer — deleted.

## 4. Invariant
1. **Born signed, uniformly.** Every cap is minted only through `Cap.issue`, which signs it — identically for every granter principal (entity/session/workspace/worker); HKDF key per principal URI, no type-specific paths.
2. **One verifying authorization chokepoint.** A single API decides every authorization; it verifies the presented cap (signature + crypto + grantee bound to the explicit holder) AND matches the needed shape. **Every authorization consumer routes through it.** No code decides authorization by inspecting cap fields directly.
3. **Issue-authority binds issuer to granter.** A cap `granted_by P` may be minted only if the issuing context has authority over `P` (the caller *is* `P`, or holds `P`'s issue-authority). Uniform for all principals. **No `{:genesis, any_uri}` wildcard** — genesis is admin's own authority only, not "admin for any URI."

## 5. The authorization chokepoint (invariant 2)
- **One API**: `authorize(holder_uri, presented_caps, needed) :: :ok | :error`. It (a) `verify`s each presented cap (signed, crypto-valid, grantee == `holder_uri`) and (b) matches `needed`. Receiver-blind matching is impossible — verify is intrinsic.
- **Explicit holder, per-consumer.** The holder is NOT universally `ctx.caller`. A per-consumer holder table: dispatch caller → `ctx.caller`; recipient-held receive (MemberReceive) → `ctx.self_uri`; preflights → explicit `caller`/`owner_uri`. Each consumer passes its correct holder.
- **Migrate every consumer.** The full surface (from v5 review): `capability/authorization.ex` (fold in), dispatch slice/inline/dynamic-`holds_cap?`/workspace-isolation `cross_workspace?`; preflights (PTY, orchestrator tools, participants, member_template, session-config admission); non-dispatch gates (agent config, external_mirror, credential resolver, notifications, session_template, session_view, config_governance); grant/delegation (`CapabilityRegistry`); in-handler (MemberReceive); manual matchers (world `read_unfiltered_cap?`, kanban `kind: :any`, workspace listing, identity admin, external_mirror admin, session-config orchestrator). All → the one API.
- **Non-authorizing exemptions** are explicitly enumerated (serialization, issuance, identity-keys, idempotency bookkeeping like participation-cap dedup, `has_cap?` introspection, diagnostics) — these may touch cap fields without authorizing.

## 6. Structural enforcement (why grep can't do it)
A grep/inventory gate can't prove completeness — real matchers use varied spellings, direct field access, and dynamic `holds_cap?` callbacks. So enforcement is **structural**:
- **No authorization code inspects capability authority-axes outside the one API.** Achieved by making the authority-relevant match/field-access private to the authorization module (callers physically cannot match a cap for authz except via `authorize/3`), enforced by an AST/compile gate over authz contexts, with the enumerated exemptions (§5) as the only allowlist.
- **Remove boolean-returning dynamic `holds_cap?` overrides** so the central API receives and verifies the actual matched cap (no callback hides an unverified decision).
- Source-scan gates remain only as secondary regression aids.

## 7. Issuance (invariant 3, uniform)
- `Cap.issue(issue_context, grantee, cap)` signs a cap `granted_by P` (P from the context) only after checking the context has authority over `P`. Uniform: caller-is-P, or caller holds P's issue-authority. The relational binding is data: cross-session forward = `granter=source_session, grantee=msg.sender, target=dest_session, shape=session.send(target), same_workspace(granter,target)` — verified as cap fields + the issuer (source session) controlling the granter. No principal-type special rule; no broad structural tag that lets an issuer mint as a granter it doesn't control.
- Self/inline caps (workspace self, session self, agent reply, genesis-admin) are all issued this way and pre-issued at spawn / issued JIT under this rule; carried in state for self-dispatch (no issue/load at dispatch → no self-read deadlock).

## 8. Method (full consolidation)
1. Build `authorize/3` (verify + match, explicit holder).
2. Migrate **every** consumer (§5) to it; delete direct cap-field authz matching; remove dynamic `holds_cap?` boolean overrides.
3. Add the structural AST/compile gate (§6) + the enumerated exemptions.
4. Make issuance uniform + issuer-controls-granter (§7); delete `{:genesis, any_uri}` wildcard; admin pre-issues signed genesis.
5. Delete dual-read / `verify_for` / `require_signature`; extend HKDF signing to all principals.
6. Delete the self-healer.
7. Fail-loud + telemetry on reject (no silent filter).
8. Wipe+reseed cutover (deploy scope).

## 9. Cutover (ezagent-deploy)
Wipe cap data + reseed signed; quiesce → wipe → deploy strict build → signed seed → resume. No app-side migration code.

## 10. Testing / gates
- **Structural gate**: no module authorizes by direct cap-field inspection outside `authorize/3` (AST gate); RED on any new bypass. This is the invariant's real guard (not grep).
- Every consumer: forged/unsigned/wrong-holder cap rejected at its decision — explicit regression for PTY-read, notification-subscribe, workspace-isolation `cross_workspace?`, world unfiltered-read.
- Issuance: minting a cap `granted_by P` from a context without authority over `P` is rejected (impersonation attempt), for entity/session/workspace uniformly.
- Genesis/self/dynamic signed; self-dispatch no deadlock; strict verify end-to-end on a fresh seeded stack; rejects emit telemetry.

## 11. Open (impl-level)
- The exact AST/compile-gate mechanism for "no cap-field authz-match outside `authorize/3`" + the enumerated exemption list.
- HKDF derivation extension for non-entity principal URIs.
- The per-consumer holder table (built by enumerating the §5 surface).
- The issue-authority check's exact form (caller-is-P vs holds-P-issue-cap) per issuance site.
