# Cap-signing: one verifying authorization chokepoint, principal-agnostic caps — DESIGN (v7)

**Status**: v7 — nails the two mechanisms the v6 review left open. v6 review confirmed the big design SOUND: the one-API + explicit-holder consolidation closes every named forgery path; holders are all derivable; principal-agnostic signing is viable (the signing primitive is already URI-generic). This version specifies (a) an honest, enforceable authorization boundary and (b) a non-spoofable issue-authority. Pending re-review.
**Supersedes**: self-healer spec (retired) + CapStore-consistency design of v1–v3 (out of scope). PR #1424 shelved.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover).

## 1. The X problem
Capabilities are **forgeable / tamperable / retargetable** under soft verification. **Goal: every cap signed and strictly verified at the authorization decision, so unproven authority is rejected — closing capability forgery as a privilege-escalation / credential-theft vector.**

## 2. Guiding principle (lead)
**A capability is principal-agnostic.** A cap issued by a session, workspace, or entity is the same thing — same struct, signing, verification, authorization. **No per-principal-type branches** anywhere. Only the cap's own fields (granter, grantee, target, shape, signature) matter, never "where it was called from." (v6 review confirmed: the signing primitive already derives from `Ezagent.URI.stable_key/1` without scheme inspection; the entity-only provenance constraint is implementation debt, removed here.)

## 3. Non-goals (OUT)
- Cap-storage consistency (multi-home caps, revoke-clears-all, CapStore). Separate concern (a resurrected *signed* cap is a consistency bug, not forgery).
- Distribution / cross-node (deferred). Self-healer — deleted.
- **Airtight structural opacity of caps** — see §6; noted as optional *future* hardening, not required to close X.

## 4. Invariant
1. **Born signed, uniformly** — minted only via `Cap.issue`, signed identically for every granter principal (HKDF key per principal URI, no type paths).
2. **One verifying authorization chokepoint** — a single `authorize/3` decides every authorization: it verifies the presented cap (signature + crypto + grantee == the explicit holder) AND matches the needed shape. Every authorization consumer routes through it.
3. **Issue-authority is a signed capability** — a cap `granted_by P` may be minted only if the issuer *is* `P` (proven by runtime principal identity) OR holds a signed **issue-authority cap** from `P`. No claimed-URI context is trusted as proof.

## 5. The authorization chokepoint (invariant 2) — SOUND per v6 review
- **One API** `authorize(holder_uri, presented_caps, needed) :: :ok | :error`: verify (signed, crypto-valid, grantee == `holder_uri`) then match `needed`. Verify is intrinsic; receiver-blind matching is impossible.
- **Explicit per-consumer holder** (v6 review confirmed all derivable): dispatch → `ctx.caller`; recipient-held receive (`MemberReceive`) → `ctx.self_uri`; world conversation → `caller_uri`; preflights → explicit `caller`/`owner_uri`. Seams that today omit the holder (`TerminalSeam.subscribe/2`, `Pty.Access.may_read?/2`) are widened to carry it.
- **Migrate every consumer** (full v5-mapped surface): `capability/authorization.ex`; dispatch slice/inline/dynamic-`holds_cap?`/workspace `cross_workspace?`; preflights (PTY, orchestrator tools, participants, member_template, admission); non-dispatch gates (agent config, external_mirror, credential resolver, notifications, session_template, session_view, config_governance); grant/delegation (`CapabilityRegistry`); in-handler (`MemberReceive`); manual matchers (world `read_unfiltered_cap?`, kanban `kind: :any`, workspace listing, identity admin). All → `authorize/3`.
- **Non-authorizing exemptions** enumerated at **site granularity** (not module-wide): serialization, issuance, identity-key use *for revocation selection only*, participation-cap idempotency dedup, `has_cap?` introspection, diagnostics.

## 6. Enforcing the boundary — runtime chokepoint + honest regression gate (v6 Hole 2)
Perfect structural prevention of direct cap-field authorization is **not achievable**: `%Capability{}` is a public Elixir struct (`cap.kind`, `%Capability{kind: …}`, `Map.from_struct/1`, dynamic accessors all bypass any "private matcher"), and AST scanners cannot prove runtime routing through dynamic dispatch. So the design is honest about where the guarantee lives:
- **The runtime guarantee that closes X is `authorize/3` itself** — once every current consumer is migrated (§5), every authorization verifies. X is closed at that point.
- **The gate is a best-effort regression aid, stated honestly**: an AST scan flagging capability authority-field access (`kind/behavior/action/instance/workspace_uri` reads, `Map.from_struct` on a cap) in modules NOT on a **site-granular** exemption list; shipped with **adversarial fixtures** (alias, `cap.kind`, `Map.get`, `from_struct`, dynamic-accessor) proving it catches those spellings; and an explicit note of what it cannot prove (runtime-selected callbacks). It prevents casual regressions, not a determined bypass — that is the honest limit.
- **Remove boolean-returning dynamic `holds_cap?` overrides** so no callback hides an unverified decision from the central path (this IS structurally enforceable — delete the override surface).
- **Optional future hardening (NOT in X scope):** an **opaque capability representation** (authority stored as a verified signed blob, readable only via `authorize/3`) would make direct field-authz impossible. Large representation change; deferred.

## 7. Issue-authority (invariant 3) — non-spoofable, sites enumerated (v6 Hole 3)
- **Proof of control**: mint `granted_by P` requires the issuer to *be* `P` — i.e., the executing runtime principal's identity is `P` (not a URI value passed in a call) — OR the issuer presents a signed **issue-authority cap** `P → issuer: may issue granted_by=P for shape S` (itself verified via §5). Genesis is the sole root: admin's own signed authority (no `{:genesis, any_uri}` wildcard; no `{:rule, name, P}` path that names P without proving control).
- **Enumerated rule-driven sites** (each classified; "on behalf of P" ⇒ needs an issue-authority cap):
  - **Cross-session forward**: granter = source session (self-control: runs in source session), grantee = `msg.sender`, target = dest session, shape = `session.send(target)`, `same_workspace`. Self-control ✓.
  - **Workspace self / agent reply**: `caller == granted_by == principal`. Self-control ✓.
  - **Session join / participation** (stamps session-owner or admin as granter): the Session process is not the owner → requires the Session to hold a signed **issue-authority cap from the session-owner** (owner delegates member-cap issuance to its session), verified at issue. If absent, granter is the session itself (self-control) with membership modeled accordingly.
  - **Template materialization** (owner as granter): same — issuer holds owner's issue-authority cap, or granter is the materializer principal.
  - **Anonymous public-view** (mints as session-owner/admin): issuer holds the owner's issue-authority cap; else the anon principal grants to itself.
  - **Verified-email binding** (`binding_actor`): issuer holds `binding_actor`'s issue-authority cap.
- The relational binding (granter/grantee/target/shape/workspace) is signed cap data, verified uniformly; no principal-type special rule.

## 8. Method (full consolidation)
1. Build `authorize/3` (verify + match, explicit holder); widen holder-less seams.
2. Migrate **every** consumer (§5); delete direct cap-field authz matching; remove dynamic `holds_cap?` boolean overrides.
3. Ship the honest regression gate (§6) + site-granular exemptions + adversarial fixtures.
4. Issue-authority (§7): implement runtime-principal proof + signed issue-authority caps; migrate the enumerated sites; delete `{:genesis, any_uri}` and control-less `{:rule, name, P}`.
5. Extend HKDF signing to all principals; delete dual-read / `verify_for` / `require_signature`.
6. Delete the self-healer. Fail-loud + telemetry on reject.
7. Wipe+reseed cutover (deploy scope).

## 9. Cutover (ezagent-deploy)
Quiesce → wipe cap data → deploy strict build → signed seed (boot constructors issue signed under §7) → resume. No app-side migration code.

## 10. Testing / gates
- **Every consumer**: forged/unsigned/tampered/wrong-holder cap rejected at its decision — explicit regressions for PTY-read, workspace `cross_workspace?`, world unfiltered-read, notification, identity-admin, kanban-admin.
- **Regression gate** (§6): adversarial-fixture suite proves it flags aliased/`cap.kind`/`from_struct`/dynamic field-authz; site-granular exemptions only.
- **Issue-authority**: minting `granted_by P` without being P or holding P's issue-authority cap is rejected — for entity/session/workspace uniformly; each enumerated site (§7) has a test proving it issues under self-control or a verified issue-authority cap.
- Principal-agnostic: session/workspace-granted caps sign + verify identically to entity caps.
- Genesis restricted to admin's own root; self-dispatch no deadlock; strict verify end-to-end on a fresh seeded stack; rejects emit telemetry.

## 11. Open (impl-level)
- HKDF derivation call-shape for non-entity principal URIs (mechanism exists; wire it).
- The issue-authority cap's shape (a cap whose action is "issue" bound to granter=P, shape S) + where genesis roots it.
- The site-granular exemption list (produced while migrating §5).
