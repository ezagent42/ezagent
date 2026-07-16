# Cap-signing strict re-architecture — Implementation Plan (PR-split)

> **For agentic workers:** implement task-by-task via superpowers:subagent-driven-development or executing-plans. Steps use `- [ ]`.

**Goal:** Close capability forgery/tamper/retarget (X) by making every cap signed and strictly verified at two authenticating chokepoints, with the signing secret held only in an isolated signer domain.

**Architecture:** `authorize/3` = the single consumption chokepoint (verify signature + grantee==explicit-holder + match); `Cap.issue` = the single issuance chokepoint (authenticate the issuer, sign via an isolated signer); verification uses a pinned public keyring. Principal-agnostic caps. Delete dual-read + verify_for + the self-healer. Existing data handled by wipe+reseed (deploy scope), not migration code.

**Tech Stack:** Elixir umbrella; ed25519 via `:crypto`; HKDF key derivation; Postgres; the Kind/entity process registry.

**Spec:** `docs/superpowers/specs/2026-07-15-cap-signing-strict-capstore-design.md` (v11, SOUND after 11 review rounds). Branch: `feat/cap-strict-capstore`.

## Global Constraints
- Scope is ONLY X (forgery/tamper/retarget). Storage consistency (multi-home/CapStore) and opaque-cap representation are OUT.
- `verify` is a single receiver-aware strict predicate — no `verify_for/2`, no dual-read, no `require_signature`. No per-principal-type branches anywhere.
- No cap is minted outside `Cap.issue`; no authorization decision is made outside `authorize/3`. These are the two invariants every PR upholds.
- Implemented by coordinator (Claude) directly. Each PR: `gate (deterministic)` + `gitleaks` green; the security-behavior tests below are the real gate. codex adversarial review per PR before merge.
- Cutover is `wipe+reseed` in ezagent-deploy — NO app-side migration/backfill code.

---

## PR ordering & dependency
PR-1 (authorize/3) → PR-2 (Cap.issue issuer-auth) → PR-3 (isolated signer + keyring) → PR-4 (delete dual-read/self-healer + genesis pin) → PR-5 (ezagent-deploy cutover). PR-1..4 land on `feat/cap-strict-capstore`; security is realized at PR-5 cutover (all-or-nothing on the branch). Each PR keeps the suite green.

---

### PR-1: `authorize/3` consumption chokepoint + migrate all consumers

**Goal:** One verifying authorization API; every cap-consuming authorization decision routes through it with the correct explicit holder; strict receiver-aware verify.

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/capability/authorization.ex` — add `authorize(holder_uri, presented_caps, needed) :: :ok | :error` that (a) filters `presented_caps` through the strict `verify(cap, holder_uri)` and (b) matches `needed`; make `authorizing_cap`/`authorizes?` delegate to it (holder passed in).
- Modify: `apps/ezagent_core/lib/ezagent/cap.ex` — fold `verify_for/2`'s receiver comparison into the single `verify/2`; delete the receiver-blind path from authorization use.
- Modify each consumer to pass its correct holder and call `authorize/3` (holder table): dispatch (`kind.ex`, `kind/runtime.ex` incl `cross_workspace?`) → `ctx.caller`; `member_receive.ex` → `ctx.self_uri`; `ezagent_domain_pty/access.ex` `may_read?` (+ widen `TerminalSeam.subscribe/2` to carry holder); `notification_subscriptions.ex` (subscribe + admin); `world/conversation_data.ex` `read_unfiltered_cap?`; `kanban/shared.ex` (`kind: :any`); `workspace/listing.ex`; `behavior/identity.ex` admin predicates; orchestrator tools/participants/member_template/admission preflights; `credential/resolver.ex`; `external_mirror/gates.ex`; `session_view.ex`; `config_governance`.
- Remove dynamic boolean `holds_cap?/2` overrides so the central path receives the actual matched cap.
- Create: `apps/ezagent_core/test/invariants/cap_authz_chokepoint_test.exs` — AST regression gate: no module outside the enumerated exemptions (serialization/issuance/identity-key-for-revocation/idempotency-dedup/`has_cap?`-introspection/diagnostics) matches cap authority-fields for an authorization decision; ships adversarial fixtures (`cap.kind`, `%Capability{kind:}`, `Map.from_struct`, aliased call).

**Produces:** `Ezagent.Capability.authorize/3`; strict `Ezagent.Cap.verify/2` (receiver-aware).

**Acceptance criteria:**
1. A forged/unsigned cap of the right *shape* is REJECTED at each migrated consumer — explicit regression tests for PTY read, notification subscribe, `cross_workspace?`, world unfiltered-read, kanban admin, identity admin.
2. A cap whose grantee ≠ the presenting holder is rejected (retarget closed).
3. `grep -rn "verify_for" apps/` returns 0 in non-deleted code; `require_signature` reads removed from the authorization path.
4. The AST regression gate is RED on a deliberately-added `cap.kind`-based authz bypass (proven by a fixture), GREEN otherwise.
5. `mix ci.local` deterministic gate green; the identity + core suites green.

**Representative test:**
```elixir
test "forged unsigned Manage/:read cap cannot authorize a PTY read" do
  forged = %Ezagent.Capability{kind: :agent, behavior: Ezagent.ActionSet.Manage,
                               action: :read, instance: victim_uri, workspace_uri: :any} # unsigned
  assert :error = Ezagent.Capability.authorize(attacker_uri, MapSet.new([forged]),
                    needed(:agent, Ezagent.ActionSet.Manage, :read, victim_uri))
  assert {:error, :unauthorized} = Ezagent.Pty.Access.may_read?(victim_uri, attacker_uri, [forged])
end
```

---

### PR-2: `Cap.issue` authenticates the issuer + migrate issuance sites + pin genesis

**Goal:** Every cap minted only if the issuer is authenticated (never a passed URI); genesis is a single admin-only root.

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap.ex` — `Cap.issue` derives the issuer from a non-forgeable source: (1) the calling process's *registered* identity (via a new reverse `KindRegistry.principal_of(pid)`); (2) a boot credential (a non-constructible token available only on the boot path) for genesis/seed/Mix; (3) a verified signed **issue-authority cap** `P → Q` for delegated issuance. Delete `{:held_by,uri}`/`{:admin,uri}`/`{:rule,name,uri}`/`{:genesis,arbitrary_uri}` trust-the-arg tags. Genesis path signs exactly `admin→admin`, boot-only.
- Modify: `apps/ezagent_core/lib/ezagent/kind_registry.ex` — add reverse pid→principal lookup.
- Create: the issue-authority cap shape (a cap with action `:issue` bound to `granted_by=P`, shape `S`) + its verification in `Cap.issue`.
- Migrate the issuance worklist (spec §7): re-home to self-control or issue-authority — `workspace_user_admin` user-create, `Identity.Grant.grant_cap`, `recipe_cap_binding`, orchestrator `caps.ex`, `anon_user`, session `member_cap`, template materialization, email `binding_actor`, workspace-membership, external-mirror worker, + generic sites (user creation, composition caps, world layout bootstrap, Mix tasks → boot credential).
- Modify: `apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs` — assert no signing outside `Cap.issue`; assert issue rejects an unauthenticated issuer.

**Produces:** authenticated `Cap.issue`; `KindRegistry.principal_of/1`; the issue-authority cap type.

**Acceptance criteria:**
1. Minting `granted_by P` from a context that is neither `P` (registered), nor boot, nor holding `P`'s issue-authority cap → `Cap.issue` FAILS — regression test for the `{:held_by, victim}` impersonation, uniformly for entity/session/workspace granters.
2. Each migrated site issues under self-control or a verified issue-authority cap — a test per class (session member, orchestrator, anon-view, email-binding).
3. Genesis issues exactly `admin→admin`, only on the boot path; `grep -rn "{:genesis," apps/` shows no arbitrary-URI genesis.
4. Suite green.

---

### PR-3: isolated signer domain + pinned public keyring (C1/C2/C3)

**Goal:** The signing secret is unreachable by ordinary code; verification uses pinned public keys.

**Files:**
- Create: an isolated signer (external service / sidecar boundary; interim: a supervised, secret-owning process that loads the seed from a mounted secret at boot and never exposes it — with an explicit note that hardening to a true separate OS/security domain is the target). Exposes only `sign(authenticated_request)` and re-validates the issuer/issue-authority proof (C2).
- Modify: `apps/ezagent_core/lib/ezagent/cap/signing.ex` — make `derive_keypair`/`sign` reachable only inside the signer; the app calls the signer, never `:crypto.sign` directly.
- Create: the **public keyring** — the signer derives + publishes `principal → pubkey`, signed by / pinned to a root pubkey (C3). Modify `Ezagent.Cap.verify` to read pubkeys from the pinned keyring; DELETE the current verifier deriving the full keypair from the seed.
- Modify: config — seed delivered only to the signer domain, not as an app-BEAM env var (C1).

**Produces:** the signer boundary; the pinned public keyring; seed-free verification.

**Acceptance criteria:**
1. No app-BEAM code path can obtain the seed or a private key (test: the seed env var is absent in the app domain; `verify` succeeds using only the keyring).
2. A cap signed by a substituted (attacker) keyring entry for principal `P` is REJECTED (keyring pin test) — proves C3.
3. `sign` refuses a request lacking a valid authenticated issuer proof (C2 oracle test).
4. Suite green.

---

### PR-4: delete dual-read / self-healer remnants; fail-loud + telemetry

**Goal:** Remove the retired machinery and soft-fail behavior.

**Files:**
- Delete: `require_signature` flag + all dual-read plumbing; the self-healer subsystem if any remnant is on the branch (reconciler/sweeper/quarantine/heal/reissue-policy — already unmerged from #1424, ensure absent).
- Modify: collection verify + store loads to emit telemetry/error on a rejected cap (no silent filter).

**Acceptance criteria:**
1. `grep` shows no `require_signature`, no dual-read, no self-healer modules.
2. A rejected cap at a load boundary emits an observable error/telemetry event (test).
3. Suite green; `full-suite (mac)` green on merge to the branch.

---

### PR-5: cutover (ezagent-deploy repo — separate task)

**Goal:** Reseed all channels with signed data; flip to the strict build.

**Files (ezagent-deploy):** a runbook/script alongside `reflow.sh`: quiesce writers → wipe cap-bearing data → deploy the strict build → run the signed seed (boot constructors issue signed under PR-2) → resume. Seed delivered to the signer domain (PR-3).

**Acceptance criteria:**
1. On a fresh reseed, the four-source authority is 100% signed (a boot-time assertion or one-shot audit = 0 unsigned).
2. A live smoke on canary: a normal user action (create session, send) works end-to-end under strict verify; a hand-crafted forged cap is rejected at authorization.
3. No app-side migration code shipped.

---

## Self-review
- Spec coverage: §4 invariants → PR-1 (inv 2), PR-2 (inv 1+3), PR-3 (inv 4); §5 consumers → PR-1; §6 gate → PR-1 AST test; §7 issuance → PR-2; §8 method → PR-1..5; §9 cutover → PR-5. Covered.
- Sequencing note for the Allen sync: PR-1 and PR-2 are the largest; PR-1 may split into PR-1a (build `authorize/3` + `authorization.ex`) and PR-1b (migrate the ~20 consumers) if review load warrants.
