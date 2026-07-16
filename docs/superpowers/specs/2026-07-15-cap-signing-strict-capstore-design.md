# Cap-signing: two symmetric chokepoints (verify + issue), principal-agnostic caps — DESIGN (v9)

**Status**: v9 — v8 review confirmed the genesis root SOUND and pinned the LAST X hole precisely (issuance side): (a) the signing primitives are public → a valid cap can be minted bypassing `Cap.issue`; (b) `Cap.issue` trusts a URI passed as the issuer → `{:held_by, victim}` impersonation. v9 closes both: the signer is private to `Cap.issue`, and `Cap.issue` **authenticates** the issuer (never trusts a passed URI). This is the symmetric mirror of the consumption side — both chokepoints authenticate rather than trust. Pending re-review.
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
3. **Issue-authority, enforced at an unbypassable issuance chokepoint** — a cap `granted_by P` may be minted only if the issuer is an **authenticated** `P` OR presents a signed **issue-authority cap** from `P`. **The signing primitives (`derive_keypair`, `sign`) are private to `Cap.issue`** — no code can produce a signed cap outside the chokepoint (this makes "every cap passes `Cap.issue`" a real architectural boundary, not an assumption). **`Cap.issue` never trusts a URI passed as the issuer** — it authenticates the issuer from a non-forgeable source (§7). Two chokepoints, both authenticating: `Cap.issue` gates who may mint; `authorize/3` gates who may use.

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

## 7. Issue-authority — enforced at an unbypassable `Cap.issue` chokepoint (v7 Hole 3 / v8 signer-bypass + issuer-auth)
- **The signer is private (closes the bypass).** `Cap.Signing.derive_keypair/3` and `sign/2` (and the key-id/version/trust-domain inputs) are made **private to `Cap.issue`** — e.g. moved behind a private function or a module that only `Cap` calls, enforced by an arch gate. No in-process code can derive an arbitrary principal's key and sign a cap outside the chokepoint. This turns "every cap passes `Cap.issue`" into an enforced boundary rather than an observed fact.
- **The issuer is authenticated, never a passed URI (closes impersonation).** `Cap.issue` derives the issuer identity from a **non-forgeable source**, one of:
  1. **Runtime principal** — the calling process's *registered* identity (`self()` → the Kind/entity registry), for issuance running inside the granter's own process. A caller cannot pass `{:held_by, victim}`; it can only issue as the principal it actually runs as.
  2. **Boot credential** — a boot/bootstrap-only capability for genesis + seed-time issuance (Mix tasks, seeds, admin provisioning), gated to the boot path.
  3. **Issue-authority cap** — a signed cap `P → issuer: may issue granted_by=P for shape S`, presented + verified (§5), for delegated "on behalf of P" issuance.
  Any site that cannot supply one of these fail-louds at `Cap.issue` (symmetric with a consumer that doesn't call `authorize/3`). The current `{:held_by, uri}` / `{:admin, uri}` / `{:rule, name, uri}` / `{:genesis, uri}` tags — which trust a passed URI — are replaced by these authenticated sources. No `{:genesis, any_uri}` wildcard.
- Because every cap is born through this chokepoint (invariant 1) and the signer is private, this covers **every** issuance site uniformly; the site list below is a **migration worklist, not a completeness proof**.
- **Genesis root (pinned).** Genesis is a **single fixed root**: the bootstrap admin identity only. `Cap.issue`'s genesis path signs **exactly one** grantee — `admin` — invoked only by the boot bootstrap, and is the sole cap whose authority is self-asserted (the root of trust). It is signed, not the current unsigned arbitrary-P constructor. Every other principal's authority descends from admin via normal signed issuance / issue-authority caps. There is no "genesis for an arbitrary `P`."
- **Known migration worklist** (from v6/v7 reviews — classify each as self-control / issue-authority-cap / re-home; not exhaustive, `Cap.issue` catches the rest):
  - *Self-control ✓*: cross-session forward (granter = source session, grantee = `msg.sender`, target = dest session, `same_workspace`), workspace-self, agent-reply (`caller == granted_by`).
  - *Was `{:genesis, arbitrary_P}` — must re-express*: creator-manage `{:genesis, creator_uri}`, responsibility-assignment `{:genesis, ctx.caller}` → these are an entity minting for another; re-home granter to the acting entity (self-control) or require an issue-authority cap. NOT genesis.
  - *"On behalf of P" — needs P's issue-authority cap (or re-home granter)*: session-join/participation (owner→session), template materialization (owner), anonymous public-view (owner/admin), verified-email binding (`binding_actor`), workspace-membership issuance, external-mirror worker inline admin cap, plus generic/background sites (Identity facade, user creation, workspace initial caps, composition caps, recipe binding, Mix tasks, world layout bootstrap).
- Relational binding (granter/grantee/target/shape/workspace) is signed cap data, verified uniformly; no principal-type special rule.

## 8. Method (full consolidation)
1. Build `authorize/3` (verify + match, explicit holder); widen holder-less seams.
2. Migrate **every** consumer (§5); delete direct cap-field authz matching; remove dynamic `holds_cap?` boolean overrides.
3. Ship the honest regression gate (§6) + site-granular exemptions + adversarial fixtures.
4. Issue-authority (§7): enforce the check INSIDE `Cap.issue` (fail-loud reveals the issuance-site worklist, symmetric with §5); pin genesis to the single signed admin root; migrate/re-home each site (self-control vs issue-authority cap); delete `{:genesis, any_uri}` and control-less `{:rule, name, P}`.
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
