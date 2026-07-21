# Target-Epoch Cap Revocation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Also load `ezagent-developer` + `elixir-phoenix-helper` project skills before writing any `.ex`** (per `feedback_subagent_must_load_project_skills`). **Before any grant/revoke/cap code, read `.claude/skills/ezagent-developer/references/capbac.md`.**

**Goal:** Make "revoke every capability pointing AT a target B" an O(1) property of B's own durable state — read at the authorization decision — so dormant caps die, URI-reuse cannot resurrect old caps, and no reverse index / holder sweep is needed.

**Architecture:** The revocation "epoch" is the target's **per-Kind authority generation** — a monotonic integer that already lives in the merged `kind_cap_authorities` table (composite PK `(uri, generation)`, append-only, non-deletable-by-runtime) and is already bound into every signed cap via `key_id = "kind-g<N>:<fingerprint>"`. `Cap.Authority.verify/3` already rejects a cap whose `key_id` ≠ the target's **current active** authority `key_id`. This plan (1) **unifies** every authorization consumer onto a single signed-verify chokepoint so the generation check applies everywhere — not just the in-dispatch verifier; (2) wires a **cap-gated bump** primitive (`regenesis`) with **live propagation** so a revoke-all takes effect immediately; (3) closes the **ownership-roots** set with an enumerator gate.

**Tech Stack:** Elixir/OTP umbrella (`apps/*`), Ecto + Postgres (`EzagentCore.Repo`), ed25519 caps (`:crypto` eddsa), ETS hot-caches (`EzagentCore.EtsOwner`), `mix test` + `mix ezagent.check_invariants` gates.

---

## Global Constraints (verbatim, apply to every task)

- **Born-signed base is MET.** Cap-signing Path A (per-Kind ed25519 authority) is MERGED to main (#1457): `cap/verifier.ex`, `cap/authority.ex`, `ecto/kind_cap_authority.ex`, `cap/signing.ex`. Build epoch ON TOP; do NOT re-implement or wait for any cap-signing-strict / isolated-signer work (DONE via Path A, or DEFERRED via Path B).
- **Epoch requires STRICT verify** (spec §9.2). It provides ZERO protection while `require_signature = false` (dual-read). It ships only with/after the born-signed cutover. Every acceptance test runs under `require_signature = true`.
- **No back-compat shims** (memory `feedback_let_it_crash_no_workarounds`; SPEC v2 §5.11). DB is wiped+reseeded on cutover (spec §7); no app-side backfill/migration code.
- **Authz is a cap check or `Ezagent.Identity.admin?/1` — NEVER a hardcoded admin-principal comparison** (`cap_check_only_at_chokepoint_test.exs` p13 forbids `caller == admin_uri()` / `same_uri?(caller, admin_uri())` outside 3 allowlisted files). The bump primitive MUST be cap-gated (spec §9.1).
- **`uv run` not `python`; `pnpm` not `npm`; `mix format` only touched files** (ezagent-developer conventions).
- **Every PR: TDD (fail-before/pass-after), independently testable, frequent commits.** Reproduce the deny/allow on a clean base or the failure is yours (memory `feedback_zero_new_failures_baseline_proof`). Completion = an invariant test that fails when the goal is unmet (memory `feedback_completion_requires_invariant_test`).
- **Run the gate before claiming done:** `mix ezagent.check_invariants` + the epoch enumerator (Phase D) must be green.

---

## GROUND-TRUTH ANCHOR TABLE (real current-main file:line — verified 2026-07-20 @ origin/main `fe2906431`)

Read current-main via the clean worktree `/private/tmp/ci189-bc-wt` or `git show origin/main:<path>`. Do NOT trust the spec's cited line numbers where they differ from this table — the spec predated #1457's merge and some symbols it names (`Users.tombstone`, `Identity.Offboarding.cascade_derived_agents`, `Entity.Token.revoke_all_for_entity`, `SpawnFence`, `authz_check/5`, `granted_via_holds_cap?`, `Cap.verify/1`) **do not exist** on main.

| Concern | Symbol | Path:line |
|---|---|---|
| Cap struct (no `target_generation`) | `%Capability{}` defstruct / `@enforce_keys` | `apps/ezagent_core/lib/ezagent/capability.ex:36-49` |
| Cap serialization | `to_map/1` / `from_map/1` / Jason encoder | `capability.ex:442` / `:456` / `:575-607` |
| Single-holder revoke (KEEP, spec §5) | `Capability.revoke/2` (identity-key match) | `capability.ex:222` |
| Admin genesis carve-out (`:any`) | `admin_genesis_cap/0` / `admin_invariant?/1` | `capability.ex:250` / `:272` |
| Match engine (no sig) | `Capability.matches?/2` | `capability.ex:171` |
| **Mint entry** | `Cap.issue/3` | `apps/ezagent_core/lib/ezagent/cap.ex:27` |
| Mint (operator convenience) | `Cap.issue_for_action/3` | `cap.ex:78` |
| Load-boundary storage filter | `Cap.verified_set/2` / `Cap.storable_for?/2` | `cap.ex:178` / `:188` |
| **Artifact construct + sign** | `Cap.Grant.issue/2` | `apps/ezagent_core/lib/ezagent/cap/grant.ex:76-85` |
| Grant authz gate | `Cap.Grant.authorize_and_issue_current/6` (verifier call `:62`) | `cap/grant.ex:46` |
| **Authority open (once at init)** | `Cap.Authority.open/2` | `apps/ezagent_core/lib/ezagent/cap/authority.ex:34` |
| **BUMP primitive (admin-gated today)** | `Cap.Authority.regenesis/3` (`same_uri?(presenter, admin_uri())` gate `:59`) | `cap/authority.ex:57` |
| Sign (stamps `key_id`) | `Cap.Authority.sign/2` (`key_id` stamp `:83`) | `cap/authority.ex:82` |
| **Verify (compares `key_id` to CURRENT)** | `Cap.Authority.verify/3` (`cap.key_id == authority.key_id` `:104`) | `cap/authority.ex:98` |
| In-process current-authority | `with_current/2` / `verify_current/2` / `current_target?/1` | `cap/authority.ex:118` / `:131` / `:140` |
| **Generation → key_id encoding** | `key_id/2` = `"kind-g#{generation}:#{fingerprint}"` | `cap/authority.ex:172-175` |
| Genesis (refuses reuse) | `genesis/2` (`_historical -> Repo.rollback(:regenesis_required)` `:201-202`) | `cap/authority.ex:177` |
| Insert generation (+ anchor) | `insert_generation/3` (anchor construct `:224-234`) | `cap/authority.ex:211` |
| Monotonic next gen | `next_generation/1` = `max(all gens)+1` | `cap/authority.ex:266` |
| **THE dispatch verifier chokepoint** | `Cap.Verifier.authorize/5` | `apps/ezagent_core/lib/ezagent/cap/verifier.ex:47` |
| Verifier match (sig-verified caps) | `verify_cap/5` (`verified_artifact?` `:79`, `matches?` `:81`) | `cap/verifier.ex:68` |
| Verifier per-cap sig check | `verified_artifact?/2` → `Authority.verify_current` | `cap/verifier.ex:106-107` |
| Non-cap allowlist | `@non_cap_actions` / `non_cap_action?/2` | `cap/verifier.ex:21-41` / `:58` |
| Needed-shape builder (`:any`→target) | `required_cap/4` | `cap/verifier.ex:116` |
| Signing payload (JCS) | `Signing.signing_payload/1,2` (map `:82-93`) | `apps/ezagent_core/lib/ezagent/cap/signing.ex:76` / `:81` |
| Dispatch → verifier call | `Kind.Runtime.do_handle_dispatch/4` (verifier `:165`) | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:161-173` |
| **Authority cached once at init** | `Kind.Server.init/1` (open `:120`, stored `:133`) | `apps/ezagent_core/lib/ezagent/kind/server.ex:120` |
| Handler runs under cached authority | `with_current(state.authority, …)` | `kind/server.ex:336,395,415,641,683,857,903` |
| Retire on destroy | `Cap.Authority.retire(self_uri)` (destroy hook) | `kind/server.ex:614` |
| **Match engine w/o sig (SLICE)** | `Kind.default_holds_cap?/2` (`granted_by_entity?+matches?` `:288-297`) | `apps/ezagent_core/lib/ezagent/kind.ex:255` |
| Holds-cap resolver | `Kind.holds_cap?/3` | `kind.ex:324` |
| **Match engine w/o sig (preflight)** | `Capability.Authorization.authorizes?/2` (`safe_matches?` `:28`) | `apps/ezagent_core/lib/ezagent/capability/authorization.ex:24` |
| Match engine w/o sig (identity) | `Identity.caps_authorize?/2` | `apps/ezagent_domain_identity/lib/ezagent/identity.ex:303` |
| Canonical admin predicate | `Identity.admin?/1` | `identity.ex:124` |
| Authority ecto (append-only, PK `(uri,generation)`) | `Ezagent.Ecto.KindCapAuthority` (`insert/1` `:44`, `retire_active/1` `:61`, `active/1`, `list/1`) | `apps/ezagent_core/lib/ezagent/ecto/kind_cap_authority.ex:15-66` |
| Authority migration (partial-unique active-per-uri) | — | `apps/ezagent_core/priv/repo/migrations/20260716000000_create_kind_cap_authorities.exs` |
| Snapshot delete on destroy | `KindSnapshot.delete/1` (`Repo.delete_all` `:148`) | `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex:147` |
| Destroy path | `Lifecycle.destroy/2` → `do_destroy/2` (snapshot delete `:775`, terminate `:762-765`) | `apps/ezagent_core/lib/ezagent/lifecycle.ex:686` / `:747` |
| **User delete (real path — NOT `tombstone`)** | `Users.delete/1` (`Lifecycle.destroy` `:217`, `Repo.delete` `:227-233`) | `apps/ezagent_domain_identity/lib/ezagent/users.ex:209` |
| **ETS hot-cache precedent to copy** | `Cap.DeliveryOutbox` `@target_hint_table` (`:28`), `table/0` (`:31`), `rehydrate_hints/0` (`:58-71`) | `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex` |
| ETS boot rehydrate call | sweeper `rehydrate_hints()` at boot | `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/sweeper.ex:20` |
| ETS owner (table creation) | `EzagentCore.EtsOwner` (`@tables` `:32`, `:ets.new` `:165-167`) | `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:32,153-169` |
| **Enumerator-gate model** | `CapCheckOnlyAtChokepointTest` (`@probes`, `assert offenders == []`; p3 `matches?`, p13 admin-eq forbid) | `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs` |
| **Presence-tripwire model** | `check_invariant_10` (greps `kind/runtime.ex` for `Capability.matches?`) | `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex:294-320` |
| Read-plane enumerator model | `NoSurfaceReadDispatchTest` | `apps/ezagent_core/test/invariants/no_surface_read_dispatch_test.exs` |
| Admin-operator cap-injection seam | `Invocation.with_admin_operator/2` (`:105`), `materialize_admin_action_cap/1` (`:180`), gates (`:209/:213`) | `apps/ezagent_core/lib/ezagent/invocation.ex` |

---

## DESIGN DECISIONS — resolve BEFORE kimi implements (this plan goes to codex adversarial review first)

### DECISION #0 (LOAD-BEARING) — Is the epoch the existing **key generation** (Design K), or a **new `target_generation` integer field** (Design I)?

The spec §1-4 and the parent's grounding item (1) say "add a `target_generation` field to `%Capability{}`; mint stamps it; verify compares `cap.target_generation == target.current_generation`." **Grounding the REAL merged code shows that field effectively ALREADY EXISTS as `key_id`, and this plan RECOMMENDS reusing it (Design K).** This recommendation **contradicts grounding item (1)'s prescription to add the field** — stated openly here for codex to rule on. Evidence:

1. **Substrate (i) is BUILT.** The spec's §11 Decision-1 treated substrate (i) "survives-deletion per-URI record" as "design-only / not yet built" and recommended (ii) a new global sequence. But #1457 shipped `kind_cap_authorities`: composite PK `(uri, generation)`, append-only, **no runtime delete API** (`kind_cap_authority.ex` moduledoc + only `insert`/`retire_active`), retired-not-deleted on destroy (`kind/server.ex:614`). `next_generation/1` = `max(all gens incl. retired)+1` (`cap/authority.ex:266`) → strictly monotonic across reuse. This natively satisfies requirements (a) cold-restart, (b) survives-deletion, (c) cheap read. **No new durable surface and no global sequence are needed.**
2. **The generation is ALREADY signed into every cap.** `key_id = "kind-g<generation>:<fingerprint>"` (`cap/authority.ex:172-175`), stamped at `sign/2` (`:83`), inside the signed payload (`signing.ex:89`). A holder cannot edit it without breaking the signature.
3. **Verify ALREADY compares it to the target's CURRENT value, no self-select.** `verify/3` requires `cap.key_id == authority.key_id` (`:104`), where `authority` is the **current active** row (`open/2` → `KindCapAuthority.active/1`), never selected by the cap. This is exactly spec §3.3 "the cap never self-selects its generation" — already true.
4. **Every cap-bearing target has its own authority row** (verified): sessions, workspaces, agents, users, both templates, system — **and kanban boards** (each board is a dedicated 1:1 `Entity.Agent` at `entity://<ws>/agent/<board-id>`). So a key-generation bump targets each precisely, **no over-revocation**. (Socialware feeds / `resource://` data-hosts have NO authority row — they are membership-gated projections off a host session; see Phase D — they are out of epoch scope, not under-covered.)
5. **`regenesis/3` already bumps** monotonically with a fresh keypair + fresh admin-anchor in one transaction (`cap/authority.ex:57-78`).

**Under Design K the spec's §4.2 objections to key-rotation-as-epoch are stale:** they assumed an *issuer-scoped* key (`derive_keypair(granted_by, …)`) that "revokes all caps issued by that granter." The merged key is **target-scoped** (per-Kind authority signs caps on itself). And §4.2-reason-3 ("you still need the compared generation") cuts the other way: in the built code the `key_id` **IS** that compared generation, so adding a separate integer is **redundant**.

**What Design K still needs (the real gaps — the rest of this plan):**
- `regenesis` has **zero callers** — no `revoke_all_to/1` operator action (Phase C).
- `regenesis`'s gate is a hardcoded admin comparison — must become a **cap-gate** per §9.1 (Phase C).
- The authority is **cached at `init` and never re-read** (`kind/server.ex:120→133`) → a bump on a **live** target is stale until reload → **live-propagation** task (Phase C).
- The generation check only runs in the **in-dispatch verifier**. Slice/preflight/read-plane engines (`default_holds_cap?`, `Authorization.authorizes?`, `Identity.caps_authorize?`, PTY `may_read?`, socialware reads) authorize via bare `matches?` with **no signature/key_id check** → a dormant old-gen cap passes them → **unify-authorize** (Phase A).

**Design I (fallback) — if codex/Allen reject Design K:** add `target_generation :: non_neg_integer() | nil` to `%Capability{}` (`capability.ex:40-49`), include it in `signing_payload/2` (`signing.ex:82-93`), stamp it at `Cap.Grant.issue/2` (`cap/grant.ex:77-82`) as `current_generation(instance)`, compare it in the unified verifier, and round-trip it in `to_map/from_map` + Jason encoder. The generation **still comes from `kind_cap_authorities`** (there is no reason to build the rejected global sequence). Design I is strictly MORE code and redundant with `key_id`, but decouples the "epoch integer" from "the signing key" if that separation is later wanted. **Only Phase B (and one stamp step in Phase C-2) differ between K and I; Phases A, C, D are identical.** This plan writes Phase B with both variants.

> **RECOMMENDATION: Design K.** It reuses a merged, tested, crypto-enforced mechanism; resolves the substrate decision with zero new durable surface; and needs no new signed field. Own the contradiction with grounding (1): *this proposes NOT adding `target_generation`, because `key_id` already carries the generation.*
>
> **The decision is low-risk either way — choosing I over K is purely ADDITIVE.** `key_id` (and its current-vs-cap compare) exists in BOTH designs; Design I merely layers a redundant integer compare on top of it. So Phases A/C/D are genuinely design-independent, and picking I later costs only the extra B-1I field work — it cannot invalidate the rest of the plan.

### DECISION #1 — URI-reuse posture: **refuse** (today) vs **regenesis-on-recreate**.
Today a deleted URI **cannot be re-created**: `genesis/2` hits `_historical -> Repo.rollback(:regenesis_required)` (`cap/authority.ex:201-202`), so the boot's `open/2` fails and `Kind.Server.init` stops with `{:authority_load_failed, …}` (`kind/server.ex:184`). Resurrection is therefore *already closed by refusing reuse entirely.* Epoch's value-add for URI-reuse is to **allow** reuse safely: on re-create, `regenesis` to `next_generation` (strictly higher) so old-gen caps mismatch. **DECISION FOR CODEX/ALLEN:** keep refuse-posture (epoch only serves operator revoke-all on a live target) OR wire re-create to auto-regenesis (epoch enables safe URI reuse). Recommendation: **wire re-create to regenesis** — it is the spec's stated goal (§1.2, §8.2-b) and turns a hard failure into a supported flow; the acceptance test (b) requires it.

### DECISION #2 — Scope-tuple caps (`{:within_session, S}` / `{:within_workspace, W}` / `{:spawned_by, X}`).
These **cannot be issued through `Cap.issue/3` today**: `Cap.Authority.target_uri/1` returns `{:error, :concrete_target_required}` for a non-URI instance (`cap/authority.ex:170`). So scope-tuple caps are minted by a *different* path (not the per-Kind authority) and are **not signed by a target authority** — Design K's key_id mechanism does not bind them. Spec §3.4 Open-Decision-2: bind a scope-tuple cap to the **scope target's** generation (revoke S ⇒ kill `{:within_session, S}` caps) vs exempt them. **DECISION FOR CODEX/ALLEN.** Recommendation: **bind to the scope target's generation** — under Design K that means signing scope-tuple caps with S/W/X's authority (requires extending `issue/3` to accept a scope-tuple whose `target_uri` is the scope URI); under Design I, stamp `target_generation = current_generation(scope_uri)`. **This is a real gap in BOTH designs; scope this as Phase C-4.** Until decided, treat scope-tuple caps as a documented **known exemption** in the enumerator (Phase D), never a silent skip.

### DECISION #3 — Bump propagation to a LIVE target (Phase C-3).
On `regenesis`, the running target process still holds the OLD authority in `state.authority` (`kind/server.ex:120→133`). It must be swapped or the bump is stale. Options:
- **(3-RECOMMENDED) In-process control handler.** Run the bump AS a `Kind.Server`-level control handler in the target's own process — a **sibling to the destroy hook that already calls `Cap.Authority.retire(self_uri)` from inside the server** (`kind/server.ex:614`). The handler runs `regenesis` and returns new state with `state.authority` swapped **synchronously**: no window between commit and swap, no race, and it respects the "authority is framework-private `Kind.Server` state, never a Behavior effect" boundary (`cap/authority.ex:1-12` moduledoc, `kind/server.ex:19`). This is also structurally consistent with C-1 (the cap-gated `revoke_all_to` is a chokepoint-verified action **dispatched to the target**; the target handles it in-process, exactly as `Cap.Grant.authorize_and_issue_current` already issues in-process via `Authority.issue_current`). Also `AuthorityCache.invalidate(uri)` (A-1) so non-dispatch verify sites re-read.
- **(3a — alternative) external reload message** — `regenesis` looks up the pid (`KindRegistry.lookup(instance)`) and messages the server to swap. Works, but a dispatch arriving between commit and message-handling verifies against the old cached authority (a real stale window; the load-bearing test (a) could flake on timing). Rejected in favor of the in-process handler.
- **(3b — alternative) deactivate** — drop the process so next activation reloads (simple, disruptive to runtime state).
- **(3c — alternative) per-dispatch re-read** — verifier reloads `active(uri)` (ETS-cached, A-1) each dispatch (simplest correctness, adds a hot-path read even when nothing was revoked).
**DECISION FOR CODEX/ALLEN.** Recommendation: **in-process control handler.**

### DECISION #4 (Design-K sub-fork) — cheap bump: **new keypair** vs **same keypair, new generation**.
`regenesis` today generates a fresh keypair every bump (`insert_generation/3` → `:crypto.generate_key`). A revoke-all that only needs to *invalidate old caps* can instead **keep the keypair and only increment the generation in `key_id`** (`"kind-g<N+1>:<same-fingerprint>"`) — old caps still mismatch on the `key_id` string, at ~zero crypto cost, and it **decouples revocation from key-rotation** (answering spec §4.2 reasons 1+2). Reserve full keypair regen for compromise-rotation. **DECISION FOR CODEX/ALLEN.** Minor; default to the existing new-keypair `regenesis` if undecided (correctness identical).

---

## Phase overview & PR count

| Phase | PRs | Deliverable |
|---|---|---|
| **A — Unify authorize** | A-1 … A-6 (6) | One signed-verify chokepoint; every access-authz engine/site verifies signature+key_id (not bare `matches?`). Closes the dormant-slice-cap hole. |
| **B — Epoch predicate/field** | B-1 (K) *or* B-1I (I) (1) | `epoch_bearing?/1` + strict-verify precondition (K); or the `target_generation` field (I). |
| **C — Bump primitive + wiring** | C-1 … C-4 (4) | Cap-gated `revoke_all_to/1`; live propagation; delete + URI-reuse hooks; scope-tuple binding. |
| **D — Ownership-roots closure + gate** | D-1 … D-2 (2) | Enumerator gate (empty-allowlist worklist) + presence tripwire; ownership-roots invariant test. |

**Total: 13 PRs** (12 if Design K, since B is one PR). Phase A is the largest; sub-split by domain and lean on the Phase D enumerator for completeness rather than proving every hand-migration.

**Sequencing:** A-1 (verify primitive + ETS) → A-2 (the load-bearing slice/preflight engines — the epoch's core closure) → B → C → A-3…A-6 (widen non-dispatch read-plane coverage; may run in parallel with C) → D (gate; lands last, enforces the rest).

---

# PHASE A — Unify authorization onto ONE signed-verify chokepoint

**Why first:** the epoch guarantee is "an old-generation cap is denied wherever it is presented." Today only the in-dispatch `Cap.Verifier` (`verifier.ex:47`) checks the signature/`key_id`; the slice engine `Kind.default_holds_cap?` (`kind.ex:288-297`), the preflight engine `Capability.Authorization.authorizes?` (`authorization.ex:24-29`), `Identity.caps_authorize?` (`identity.ex:303`), and the read-plane gates (PTY `may_read?`, socialware `SessionReads`, uploads controller) authorize via bare `matches?` — a dormant old-gen cap passes them. Route them all through signed verify so the generation check lives in exactly one place.

**Scope discipline (per advisor):** ~85 authz sites fan into 4 match-engines + 2 dispatch gates + 1 injection seam. Migrate **classes** (engines/domains), not 85 files by hand; the Phase D enumerator is the completeness proof. Classify each site: **ACCESS to an epoch-bearing target** (in-scope — must run signed verify) vs **GRANT-side / admin-definition** (unification-only — defer, mark exempt). Only the ACCESS class is required for the epoch guarantee.

### Task A-1: The shared signed-verify primitive + per-target ETS authority cache

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex` (add `verify_against_current/3`; `cap/authority.ex:130`)
- Create: `apps/ezagent_core/lib/ezagent/cap/authority_cache.ex` (ETS cache of active `(uri → {key_id, public_key, generation})`)
- Modify: `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:32` (register the new table in `@tables`)
- Modify: `apps/ezagent_core/lib/ezagent/cap/delivery_outbox/sweeper.ex:20` **pattern only** — add an analogous boot-time `AuthorityCache.rehydrate/0` under the core boot (or a dedicated worker); mirror `DeliveryOutbox.rehydrate_hints/0` (`delivery_outbox.ex:58-71`).
- Test: `apps/ezagent_core/test/ezagent/cap/authority_cache_test.exs`, `apps/ezagent_core/test/ezagent/cap/authority_verify_against_current_test.exs`

**Interfaces:**
- Produces: `Ezagent.Cap.Authority.verify_against_current(cap, presenter_uri, target_uri) :: boolean()` — verifies `cap`'s signature + `key_id` against the target's **current active** authority: uses the process-dict authority when `current_target?(target_uri)` is true (in-dispatch, near-free), else loads via `AuthorityCache.current(target_uri)` (ETS; falls back to `KindCapAuthority.active/1` on miss). Returns `false` (deny) when the target has no active authority (deleted/unreadable) — fail-closed.
- Produces: `Ezagent.Cap.AuthorityCache.current(uri) :: {:ok, %{key_id, public_key, generation}} | :error`, `AuthorityCache.invalidate(uri) :: :ok`, `AuthorityCache.rehydrate() :: :ok`, `AuthorityCache.table() :: atom()`.
- Consumes: `KindCapAuthority.active/1` (`ecto/kind_cap_authority.ex`), `Cap.Signing.signing_payload/1` (`signing.ex:76`), `Cap.Authority.current_target?/1` (`cap/authority.ex:140`).

- [ ] **Step 1: Write the failing test — verify_against_current denies an old-gen cap.**
```elixir
# authority_verify_against_current_test.exs
test "cap signed under gen N is denied after target bumps to N+1" do
  {uri, kind_type} = spawn_epoch_target()             # own kind_cap_authorities row @ gen 1
  presenter = uri
  cap = mint_signed_cap_for(uri, presenter)           # key_id "kind-g1:..."
  assert Ezagent.Cap.Authority.verify_against_current(cap, presenter, uri)

  {:ok, _} = Ezagent.Cap.Authority.regenesis(uri, kind_type, admin_uri())  # → gen 2, new active row
  Ezagent.Cap.AuthorityCache.invalidate(uri)
  refute Ezagent.Cap.Authority.verify_against_current(cap, presenter, uri)  # old key_id ≠ current
end

test "missing/retired authority denies (fail-closed)" do
  {uri, _} = spawn_epoch_target()
  cap = mint_signed_cap_for(uri, uri)
  :ok = Ezagent.Cap.Authority.retire(uri)             # active row → active=false
  Ezagent.Cap.AuthorityCache.invalidate(uri)
  refute Ezagent.Cap.Authority.verify_against_current(cap, uri, uri)
end
```
- [ ] **Step 2: Run to verify it fails.** `mix test apps/ezagent_core/test/ezagent/cap/authority_verify_against_current_test.exs` → FAIL (`verify_against_current/3` undefined).
- [ ] **Step 3: Implement `AuthorityCache`** mirroring `DeliveryOutbox` (`delivery_outbox.ex:28-71`): named `:public, read_concurrency: true` set table registered in `EtsOwner.@tables` (`ets_owner.ex:32`); `current/1` reads ETS, on miss loads `KindCapAuthority.active/1`, caches `{key_id, public_key, generation}`, returns `:error` if nil; `invalidate/1` `:ets.delete`; `rehydrate/0` `delete_all_objects` then reload all active rows.
- [ ] **Step 4: Implement `verify_against_current/3`** in `cap/authority.ex` (near `verify_current/2` `:131`): if `current_target?(target)` use process-dict authority via existing `verify/3`; else `AuthorityCache.current(target)` → reconstruct a minimal authority (public_key + key_id) → `cap.key_id == key_id and :crypto.verify(:eddsa, :none, Signing.signing_payload(cap), cap.signature, [public_key, :ed25519])`; `:error` → `false`.
- [ ] **Step 5: Run to verify pass.** Both tests PASS.
- [ ] **Step 6: Register the ETS table + boot rehydrate** (`ets_owner.ex:32`; boot call mirroring `sweeper.ex:20`). Add `authority_cache_test.exs` asserting the table exists after boot and `current/1` round-trips an active row.
- [ ] **Step 7: Commit.** `feat(cap): signed verify-against-current-authority + per-target ETS authority cache (epoch A-1)`

### Task A-2 (LOAD-BEARING): Route the slice + preflight match-engines through signed verify

This is the epoch's core closure: it makes a **dormant cap resident in a holder's `:identity` slice** die on bump (spec §8.2-a).

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind.ex:255-312` (`default_holds_cap?/2`)
- Modify: `apps/ezagent_core/lib/ezagent/capability/authorization.ex:24-29` (`authorizes?/2`, `authorizing_cap/2`)
- Test: `apps/ezagent_core/test/ezagent/kind/default_holds_cap_signed_test.exs`, `apps/ezagent_core/test/ezagent/capability/authorization_signed_test.exs`

**Interfaces:**
- Consumes: `Cap.Authority.verify_against_current/3` (A-1). The `needed_map.instance` is the target URI; the presenter is the slice-owner `entity_uri` (`default_holds_cap?`) / the caller (`authorizes?`).

- [ ] **Step 1: Failing test — a slice-held old-gen cap no longer authorizes after bump.**
```elixir
test "default_holds_cap? denies a slice-held cap whose generation was bumped" do
  {uri, kind_type} = spawn_epoch_target()
  holder = spawn_holder_with_sliced_cap(target: uri)   # cap in holder's :identity slice
  needed = needed_map_for(uri)
  assert Ezagent.Kind.default_holds_cap?(holder, needed)

  {:ok, _} = Ezagent.Cap.Authority.regenesis(uri, kind_type, admin_uri())
  Ezagent.Cap.AuthorityCache.invalidate(uri)
  refute Ezagent.Kind.default_holds_cap?(holder, needed)   # dormant slice cap dies
end
```
- [ ] **Step 2: Run → FAIL** (today `default_holds_cap?` only does `granted_by_entity? + matches?`, no signature — the cap still matches).
- [ ] **Step 3: Implement.** In `default_holds_cap?/2` (`kind.ex:288-297`) add, inside the `Enum.any?`, `Cap.Authority.verify_against_current(held, entity_uri, needed.instance)` **before** `matches?`. In `Authorization.authorizing_cap/2` (`authorization.ex:9-19`) add the same signed check next to `safe_matches?`. Keep `granted_by_entity?` (defense-in-depth) and the narrow rescue/catch.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Regression — legitimate current-gen slice cap still authorizes** (no-bump path stays green: run the existing `kind` + `capability` suites).
- [ ] **Step 6: Commit.** `feat(cap): slice + preflight authz engines verify signature/generation, not bare matches? (epoch A-2)`

### Task A-3: Identity-domain authz engine

**Files:** Modify `apps/ezagent_domain_identity/lib/ezagent/identity.ex:303` (`caps_authorize?/2`). Test: `apps/ezagent_domain_identity/test/ezagent/identity/caps_authorize_signed_test.exs`.
- [ ] **Steps (TDD, same shape as A-2):** failing test that a bumped-gen cap fails `caps_authorize?`; implement by threading `verify_against_current/3` (needs the target URI from the needed shape + the presenter); pass; regression; commit `feat(identity): caps_authorize? verifies generation (epoch A-3)`.

### Task A-4: Session + socialware read-plane gates (COORDINATE with read-plane hardening)

The read-plane hardening effort (`docs/superpowers/plans/2026-07-20-read-plane-hardening.md`, #1471 merged, MEMORY `reference_read_plane_authz_gap`) already routes internal reads through `Membership.authorize/3`. Epoch requires those **cap-based** read gates to also verify signature/generation.

**Files (ACCESS-class read gates):**
- `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55` (`authorize/3`)
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:191` (`authorized?/2`), `:461` (`read_unfiltered_cap?/3`)
- `apps/ezagent_domain_session/lib/ezagent/session/member_receive.ex:78` (`authorize/1`)
- Test: `apps/ezagent_domain_socialware/test/.../session_reads_generation_test.exs`

- [ ] **Steps (TDD):** failing test — a socialware read authorized by a bumped-gen member cap is denied; implement by adding `verify_against_current/3` to the cap-based branch of each read gate (leave the membership-based branch to read-plane hardening — a member with no cap uses `Membership.authorize/3`, which epoch does not touch); pass; regression (current-member read still allowed); commit `feat(socialware): read-plane cap gates verify generation (epoch A-4)`.
- **Note:** socialware feeds have NO own authority row (Phase D); the epoch-relevant target here is the **host session** (own row). Verify the member cap against the session's current authority.

### Task A-5: PTY + world + uploads

**Files (ACCESS-class):**
- `apps/ezagent_domain_pty/lib/ezagent_domain_pty/access.ex:57` (`may_read?/2`)
- `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:137-149` (`visible?/2` → `owns_or_holds_cap?/3`)
- `apps/ezagent_web/lib/ezagent_web/controllers/uploads_controller.ex:130,145` (`serve_authorized?/3`, `authorized?/2`)
- Test: `apps/ezagent_domain_pty/test/.../access_generation_test.exs` (+ world, uploads)

- [ ] **Steps (TDD):** failing test — PTY `may_read?` denies after the agent's generation bumps; implement by routing the cap branch through `verify_against_current/3` (via `Authorization.authorizes?` already migrated in A-2, so `may_read?` may inherit the fix — verify and add a direct test); pass; regression; commit `feat(pty/world/web): read gates verify generation (epoch A-5)`.

### Task A-6: The single `authorize/3` facade + classification doc

Consolidate the migrated engines behind one named facade so the enumerator (Phase D) and future callers have ONE symbol.

**Files:** Create `apps/ezagent_core/lib/ezagent/cap/authorize.ex` — `Ezagent.Cap.authorize(presenter_uri, candidate_caps, needed_map) :: {:ok, Capability.t()} | {:error, term()}` = `Authorization.authorizing_cap/2` semantics with the A-1 signed check baked in (delegate; do not fork a 5th engine). Update `Cap.Verifier.verify_cap` (`verifier.ex:68`) and the A-2…A-5 sites to call it where structurally clean. Add a moduledoc **classification table**: each of the ~85 sites tagged ACCESS-in-scope | GRANT-unification | ADMIN-definition | SCOPE-TUPLE-exempt (Decision #2) | MEMBERSHIP-gated (read-plane, not epoch).
- [ ] **Steps:** write a test asserting `Cap.authorize/3` denies a bumped-gen cap and accepts a current one; refactor the engines to delegate; run full `apps/ezagent_core` + domain suites; commit `refactor(cap): single authorize/3 facade over signed verify (epoch A-6)`.

---

# PHASE B — Epoch predicate / field

> **This is the ONLY phase that differs between Design K and Design I. Implement B-1 (K) OR B-1I (I) per DECISION #0.**

### Task B-1 (Design K — RECOMMENDED): `epoch_bearing?/1` predicate + strict-verify precondition

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/capability.ex` (add `epoch_bearing?/1`, co-located with the struct per spec §1.1/§9)
- Modify: `apps/ezagent_core/lib/ezagent/cap/verifier.ex` — assert `require_signature = true` when the matched cap's `instance` is `epoch_bearing?` (fail-closed if dual-read is on; spec §9.2)
- Test: `apps/ezagent_core/test/ezagent/capability/epoch_bearing_test.exs`, `apps/ezagent_core/test/ezagent/cap/epoch_requires_strict_test.exs`

**Interfaces:**
- Produces: `Ezagent.Capability.epoch_bearing?(instance) :: boolean()` — total predicate; `true` for a concrete `%URI{}` whose scheme ∈ {session, workspace, entity, template} (the 8 authority-bearing Kind types resolve to these schemes; see Phase D); `false` for `:any`, `system://`, `resource://`, and scope tuples (until Decision #2). Single source both minter and verifier consult (spec §1.1).

- [ ] **Step 1: Failing test.**
```elixir
test "epoch_bearing? classifies the target set" do
  refute Capability.epoch_bearing?(:any)
  refute Capability.epoch_bearing?({:within_session, session_uri()})   # Decision #2 pending
  refute Capability.epoch_bearing?(URI.new!("system://x"))
  refute Capability.epoch_bearing?(URI.new!("resource://w/kanban/b"))   # no authority row
  assert Capability.epoch_bearing?(session_uri())
  assert Capability.epoch_bearing?(agent_uri())                         # incl. kanban board agents
  assert Capability.epoch_bearing?(workspace_uri())
end

test "epoch-bearing target caps are rejected under dual-read (strict required)" do
  put_signing_config(require_signature: false)
  cap = mint_unsigned_cap_for(session_uri())     # forged: no signature
  refute authorize_via_chokepoint(cap, session_uri())   # DENY, never match-any
end
```
- [ ] **Step 2: Run → FAIL** (`epoch_bearing?/1` undefined).
- [ ] **Step 3: Implement `epoch_bearing?/1`** as a total function over `instance`. Add the strict-verify assertion in `Cap.Verifier`/A-6 facade: if `epoch_bearing?(needed.instance)` and the presented cap is unsigned, deny (do not fall through to `matches?`). (Under strict cutover unsigned caps already fail `verified_artifact?`; this is the explicit belt-and-braces per §9.2 + §7 null-gen-fails-closed.)
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `feat(cap): epoch_bearing? predicate + strict-verify precondition (epoch B-1, Design K)`

**Design-K note:** NO change to `%Capability{}`, `signing_payload`, `to_map/from_map`, or the Jason encoder — the generation rides `key_id`, already present and serialized.

### Task B-1I (Design I — FALLBACK, only if DECISION #0 = I): add `target_generation` field

**Files:** `capability.ex:40-49` (field), `signing.ex:82-93` (payload), `cap/grant.ex:77-82` (mint stamp), `capability.ex:442/456/575` (`to_map`/`from_map`/Jason), the A-6 facade (compare), plus `epoch_bearing?/1` as in B-1.

**Interfaces:** `%Capability{target_generation: non_neg_integer() | nil}` (`nil` only for non-epoch/`:any`); verifier additionally requires `cap.target_generation == current_generation(instance)`; `current_generation(uri)` reads `KindCapAuthority.active/1.generation` (NOT a new global sequence).

- [ ] **Steps (TDD):** (1) failing test: a cap stamped `target_generation: 1` is denied after the target bumps to gen 2, AND a cap with `target_generation: nil` on an epoch-bearing target is denied (spec §7 null-gen fail-closed), AND a cap whose `target_generation` was edited-after-signing fails signature (spec §8.2-f); (2) add the field + `@type`; (3) include `"target_generation"` in `signing_payload/2` sorted map; (4) stamp at `Cap.Grant.issue/2` from `current_generation(intent.cap.instance)`; (5) round-trip in `to_map/from_map` + Jason; (6) compare in the facade; (7) pass; (8) commit `feat(cap): target_generation field stamped+verified (epoch B-1I, Design I)`.

---

# PHASE C — Bump primitive, propagation, and lifecycle wiring

### Task C-1: Cap-gated `revoke_all_to/1` operator action (re-gate `regenesis`)

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex:57-78` (`regenesis/3`) — the gate.
- Create: the operator entry (a `Cap` action or `mix ezagent` verb) `Ezagent.Cap.revoke_all_to/2`.
- Test: `apps/ezagent_core/test/ezagent/cap/revoke_all_to_test.exs`

**The re-gate (spec §9.1, `cap_check_only_at_chokepoint_test.exs` p13):** today `regenesis/3` gates on `same_uri?(presenter, admin_uri())` (`cap/authority.ex:59`) — a hardcoded admin comparison. It passes p13 only because `cap/authority.ex` is p13-allowlisted (`:293`), but spec §9.1 requires the bump to be **cap-gated on an authority/manage-cap ON the target** — the same authority that gates `K.grant` issuance on the target (symmetric with issuance). Route `revoke_all_to/2` through the unified chokepoint: the caller must present a cap authorizing `?action=cap.revoke_all` (or the existing manage-cap) on the target, verified by `Cap.Verifier`/A-6 — NOT an admin-URI equality. The `delete_user` trusted-internal path (C-3) reaches the bump WITHOUT the operator cap (it already holds teardown authority).

**Interfaces:** `Ezagent.Cap.revoke_all_to(target_uri, ctx) :: {:ok, new_generation} | {:error, term()}` — authorizes `ctx.caller`/`ctx.caps` for `cap.revoke_all` on `target_uri` via the chokepoint, then dispatches the bump AS a control action **the target's `Kind.Server` handles in-process** (Decision #3-RECOMMENDED): the handler runs `regenesis` and swaps `state.authority` synchronously, sibling to the destroy hook at `kind/server.ex:614`, then `AuthorityCache.invalidate` + emit `:cap_revoked_all` audit (mirror the `:cap_revoked` emit). Keep an internal `regenesis` arity that no longer self-checks admin (authority moved to the caller-side chokepoint). This unifies C-1 (cap-gate) and C-3 (live swap) into one in-process path — do not add an external `KindRegistry.lookup` + message swap.

- [ ] **Step 1: Failing test — authorization of the bump (spec §8.2-h).**
```elixir
test "caller lacking manage-cap on B cannot bump B" do
  {b, _} = spawn_epoch_target()
  ctx = ctx_for(unprivileged_user())
  assert {:error, _} = Ezagent.Cap.revoke_all_to(b, ctx)
  assert gen(b) == 1                                   # unchanged
end
test "caller holding manage-cap on B can bump B" do
  {b, _} = spawn_epoch_target()
  ctx = ctx_for(manager_of(b))                         # holds cap.grant/manage on B
  assert {:ok, 2} = Ezagent.Cap.revoke_all_to(b, ctx)
  assert gen(b) == 2
end
```
- [ ] **Step 2: Run → FAIL** (`revoke_all_to/2` undefined).
- [ ] **Step 3: Implement** the cap-gate + `regenesis` call + cache invalidation + audit emit. Change `regenesis`'s inner gate so authority is the caller-side chokepoint (do not re-hardcode admin). Keep the p13 gate green (no new `== admin_uri()` outside allowlist).
- [ ] **Step 4: Run → PASS.** Also run `mix ezagent.check_invariants` (p13) → green.
- [ ] **Step 5: Commit.** `feat(cap): cap-gated revoke_all_to bump (epoch C-1)`

### Task C-2: The dormant + URI-reuse acceptance tests (against the real bump)

**Files:** `apps/ezagent_core/test/ezagent/cap/epoch_revocation_test.exs` (the spec §8.2 load-bearing suite).
- [ ] **Steps:** implement acceptance (a) dormant cap (in slice AND inline `ctx.caps`) denied after bump; (b) URI-reuse denies old-gen, new target's own caps authorize (depends on Decision #1 — if refuse-posture, assert re-create is refused instead); (d) single-holder `Capability.revoke/2` denies one holder, others still authorize, generation unchanged; (e) `:any` admin genesis cap + unrelated targets unaffected by a bump. Each test asserts the attempt reached the authorization boundary and was denied. Commit `test(cap): epoch revocation acceptance suite (epoch C-2)`.

### Task C-3: Live-bump propagation + `delete_user` / URI-reuse hooks

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex` — add the in-process bump control handler (Decision #3-RECOMMENDED), sibling to the destroy hook at `:614`: runs `regenesis` and returns new state with `state.authority` swapped synchronously.
- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex` (`regenesis`) — after commit, `AuthorityCache.invalidate` (the live-target swap is done in-process by the handler above, NOT by an external message).
- Modify (Decision #1 = regenesis-on-recreate): `apps/ezagent_core/lib/ezagent/cap/authority.ex:201-202` — replace `_historical -> Repo.rollback(:regenesis_required)` with an internal regenesis to `next_generation` on re-create (guarded so ONLY a legitimate re-create path triggers it, not a stale race).
- Test: `apps/ezagent_core/test/ezagent/cap/epoch_live_bump_test.exs`, `apps/ezagent_domain_identity/test/.../delete_user_owned_target_bump_test.exs`

**Owner-axis handoff (spec §6) — enumeration is OUT of scope here.** This plan owns the **target-axis primitive** (`revoke_all_to`/`regenesis`) and its **handoff interface**, NOT the owned-set query. Grounding found `Users.delete/1` (`users.ex:209`) does **not** enumerate owned targets — `cascade_derived_agents`/`Offboarding` do not exist on main; delete only retires the deleted entity's own authority (`kind/server.ex:614`). Do NOT have kimi invent an "owned target" definition. **Spec §6 composition = a separate delete_user/offboarding cascade (built elsewhere) calling `Cap.revoke_all_to`/`regenesis` per owned target via the trusted-internal path.** This plan's C-3 delivers only: (i) the trusted-internal bump entry the cascade will call, and (ii) a test asserting that *calling* the bump on a target whose owner was deleted denies that target's caps. If the owned-set enumeration is wanted in THIS effort, that is a **DECISION FOR CODEX/ALLEN** to define "owned" concretely (granted_by == U? workspace ownership? parent_template?) and add it as a distinct PR — do not fold an undefined query into C-3.

- [ ] **Step 1: Failing test — revoke-all on a LIVE target takes effect immediately.**
```elixir
test "bump on a running target denies its caps on the very next verify (no reload wait)" do
  {b, _} = spawn_epoch_target()                 # live process, authority cached at init
  cap = mint_signed_cap_for(b, holder())
  assert authorize_via_chokepoint(cap, b)
  {:ok, 2} = Ezagent.Cap.revoke_all_to(b, admin_ctx())
  refute authorize_via_chokepoint(cap, b)       # FAILS today: live process still holds gen-1 authority
end
```
- [ ] **Step 2: Run → FAIL** (stale cached authority — the process still verifies against gen 1).
- [ ] **Step 3: Implement 3a** (reload message + swap `state.authority`) and cache invalidation.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: URI-reuse + fail-closed + owner-handoff tests** (Decision #1 + spec §6 handoff): delete B → re-create at B's URI → old caps denied, new caps work; **owner handoff** — call the trusted-internal bump on a target T whose owner U was deleted → T's old caps denied (this tests the *primitive* the cascade will call, NOT an owned-set query built here). Assert fail-closed (c1) deleted-not-reused denies; (c2) inject an `AuthorityCache`/store read failure → deny (spec §8.2-c).
- [ ] **Step 6: Commit.** `feat(cap): live-bump propagation + delete/URI-reuse generation wiring (epoch C-3)`

### Task C-4: Scope-tuple binding (Decision #2)

**Files:** `apps/ezagent_core/lib/ezagent/cap/authority.ex:167-170` (`target_uri/1` — accept a scope-tuple, returning the scope URI as the signing target), `apps/ezagent_core/lib/ezagent/cap.ex:27` (`issue/3` — allow scope-tuple instances), the A-6 facade. Test: `apps/ezagent_core/test/ezagent/cap/scope_tuple_generation_test.exs`.
- [ ] **Steps (TDD, ONLY if Decision #2 = bind):** failing test — a `{:within_session, S}` cap is denied after S's generation bumps; implement by signing scope-tuple caps with the scope target's authority (K) / stamping `current_generation(scope_uri)` (I); pass; commit `feat(cap): scope-tuple caps bound to scope-target generation (epoch C-4)`. **If Decision #2 = exempt:** skip the code, and add the scope-tuple pattern as a documented allowlist entry in the Phase D enumerator with a reviewed rationale.

---

# PHASE D — Ownership-roots closure + acceptance gate

### Task D-1: The epoch enumerator gate (empty-allowlist worklist) + presence tripwire

Mirror `CapCheckOnlyAtChokepointTest` (`@probes`, `assert offenders == []`) and `check_invariant_10` (presence grep).

**Files:**
- Create: `apps/ezagent_core/test/invariants/epoch_check_at_chokepoint_test.exs`
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` (add invariant #N — presence of the signed-verify call in the facade/verifier, mirroring `:294-320`)

**Interfaces:** a source-scan (`%{id, desc, pattern, allowlist}` over `apps/*/lib/**/*.ex`, no BEAM):
- **Non-leakage probe:** every `Capability.matches?/2` consumer (the p3 set) that authorizes ACCESS to an epoch-bearing target must be in the A-migrated set (delegates to `Cap.authorize/3` / `verify_against_current`) or carry an explicit reviewed exemption (GRANT-side, ADMIN-definition, SCOPE-TUPLE per Decision #2, MEMBERSHIP-gated read-plane). Empty ACCESS allowlist = the worklist of remaining sites.
- **Presence tripwire (positive):** fail the build if the unified facade module (`cap/authorize.ex`) does NOT contain the `verify_against_current` / signed-verify call (mirrors #10 grepping `runtime.ex` for `matches?`). Asserts BOTH presence and non-leakage.

- [ ] **Step 1: Write the gate with an EMPTY ACCESS allowlist → run it → it lists every un-migrated ACCESS site** (this is the worklist; expected RED until A-2…A-6 are complete). Record the list in the PR body.
- [ ] **Step 2: Add the presence tripwire; run `mix ezagent.check_invariants` → the new invariant passes** (facade contains the check).
- [ ] **Step 3: Iterate the allowlist to exactly the reviewed exemptions**; the gate goes GREEN only when every ACCESS site is migrated. Commit `test(cap): epoch check-at-chokepoint enumerator + presence tripwire (epoch D-1)`.

### Task D-2: Ownership-roots closure invariant

Prove the epoch-bearing set = exactly the revocation targets, and no ownership root is missed (spec §1.1 + codex finding 2).

**Files:** `apps/ezagent_core/test/invariants/epoch_ownership_roots_test.exs`.

**The closure (verified):** the epoch-bearing set is exactly the Kinds that get their own `kind_cap_authorities` row = the 8 `def type_name` Kinds resolving to schemes {session, workspace, entity, template, system}. `resource://` (no GenServer, arch-gated) and socialware feeds (membership-gated projections off a host session) are **NOT** cap-bearing and are correctly out of scope.

- [ ] **Step 1: Failing test** — enumerate every `def type_name` across `apps/*/lib` (grep) and assert each resolves under `epoch_bearing?/1` to the correct ruling (session/workspace/entity/template ⇒ true; system ⇒ false-with-rationale); assert adding a new epoch-bearing Kind without a ruling trips the test (mirror the enumerator-vs-`epoch_bearing?` coupling of spec §8.1). Also assert `delete_user`'s owned-target cascade (C-3) covers each ownership axis (a target whose owner is deleted has its generation bumped).
- [ ] **Step 2: Run → FAIL if any type_name is unruled.**
- [ ] **Step 3: Complete `epoch_bearing?/1` rulings; pass.**
- [ ] **Step 4: Commit.** `test(cap): ownership-roots closure invariant (epoch D-2)`

---

## Acceptance matrix (spec §8.2 → task)

| Spec test | Assertion | Task |
|---|---|---|
| (a) dormant cap dies on bump (slice + inline) | mint, never use, bump, present → DENY | A-2, C-2 |
| (b) URI-reuse rejects old-gen; new caps work | delete→recreate→old DENY, new OK | C-3 (Decision #1) |
| (c1/c2) fail-closed: gone / store-unreadable | DENY, never default-allow | A-1, C-3 |
| (d) single-holder `revoke/2` unchanged; bump denies all | one denied, others OK, gen unchanged | C-2 |
| (e) carve-outs (`:any`, unrelated targets) unharmed | bump leaves them authorizing | B-1, C-2 |
| (f) signed generation, no self-select | edited-after-sign → signature DENY | B-1/B-1I |
| (g) null-gen fails closed (strict) | epoch-bearing + unsigned/nil-gen → DENY | B-1/B-1I |
| (h) bump is cap-authorized | no manage-cap → cannot bump; delete_user path bumps internally | C-1, C-3 |

---

## Self-Review (run against the spec §0-§11 with fresh eyes)

- **§1 model / §9 shape:** target-generation binding — B (predicate/field), mint stamps (existing `key_id` / B-1I), verify compares to current (A-1). ✔
- **§2 substrate:** resolved by DECISION #0 — reuse `kind_cap_authorities` (substrate i, BUILT), no global sequence. ETS hot-cache = A-1 (mirrors `DeliveryOutbox`). ✔ (Spec's ETS-cache reasoning applies to the **non-dispatch** verify sites; in-dispatch is process-dict cached, needing live propagation C-3 — flagged.)
- **§3 verify-time check + fail-closed + carve-outs:** A-1/A-6 (one chokepoint), B-1 (`:any`/scheme carve-outs), C-3 (fail-closed reads). ✔ Projection-bypass reads = A-4/A-5 + D-1 exemptions. ✔
- **§4 key vs integer:** DECISION #0 — argued from the merged (target-scoped) code; recommend reuse `key_id`. ✔
- **§5 single-holder revoke kept:** `Capability.revoke/2` untouched; C-2 test (d). ✔
- **§6 delete_user composition:** C-3 delivers the trusted-internal bump PRIMITIVE + handoff interface; the owned-set enumeration is explicitly OUT of scope (grounding: `Users.delete/1` has no such cascade; `Offboarding` does not exist) and flagged as a separate DECISION/PR. Grounded in REAL `Users.delete/1` (not the spec's non-existent `tombstone`/`Offboarding`). ✔
- **§7 migration / null-gen fail-closed:** wipe+reseed (no backfill code); B null-gen DENY. ✔
- **§8 acceptance gate:** D-1 (enumerator + presence tripwire), D-2 (ownership roots), acceptance matrix. ✔
- **§9.1 bump authorized (not admin-hardcoded):** C-1 re-gate; p13 stays green. ✔
- **§9.2 strict-verify precondition:** B-1 assertion + Global Constraints. ✔
- **§10 non-goals / §11 open decisions:** issuer-axis = delete_user (C-3); Decisions #0-#4 surfaced for codex. ✔

**Placeholder scan:** every task cites real file:line and shows test + implementation locus; no "add error handling"/"similar to Task N" placeholders. **Type consistency:** `verify_against_current/3`, `AuthorityCache.current/1`, `epoch_bearing?/1`, `revoke_all_to/2` used consistently across A/B/C/D.

**Known residual (flag for codex):** (1) DECISION #0 contradicts grounding item (1) — own it. (2) Phase A coordinates with the in-flight read-plane hardening (`2026-07-20-read-plane-hardening.md`) — the membership-gated read branch is theirs, the cap branch is epoch's; confirm no double-gate. (3) Scope-tuple issuance is a real gap in BOTH designs (Decision #2 / C-4).

---

**Codex review asks (architecture, per `feedback_codex_spec_review_architecture_not_details`):**
1. **DECISION #0** — given `key_id` already binds+compares the generation against the current-active authority, is a separate `target_generation` field justified, or is Design K (reuse `key_id`) correct? Does anything require the integer to be decoupled from the signing key?
2. Is the Phase-A "route every ACCESS engine through signed verify" the right closure for dormant slice caps, and is the ACCESS vs GRANT/ADMIN classification sound?
3. Is the live-bump propagation (Decision #3) the right mechanism, or should verify re-read per dispatch (accepting the hot-path cost)?
4. URI-reuse posture (Decision #1): refuse vs regenesis-on-recreate — which does Allen want?
5. Scope-tuple binding (Decision #2) and the `target_uri/1` extension — bind or exempt?
