# Unified Generation-Based Revocation + `authorize/3` — Reconciled Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. **Load `ezagent-developer` + `elixir-phoenix-helper` project skills before writing any `.ex`** (`feedback_subagent_must_load_project_skills`). **Before ANY grant/revoke/cap/authz code, read `.claude/skills/ezagent-developer/references/capbac.md`.**

**Goal:** Collapse three parallel revocation plans — target-epoch (`2026-07-20-epoch-revocation-implementation.md`), delete_user-invalidation (`2026-07-20-delete-user-invalidation-implementation.md`), and membership-cap-as-truth (`2026-07-20-membership-cap-as-truth-implementation.md`) — into ONE paradigm: **generation is the single revocation primitive, and every authorization consumer routes through ONE `authorize/3` chokepoint** that verifies signature + generation (both axes) + membership, with an explicit holder.

**Architecture (Allen's decision — the spine).** Canonical delete = **generation-bump (revoke) THEN delete**, for ALL delete ops. Two axes, ONE primitive (the per-Kind authority generation in `kind_cap_authorities`, already born-signed into every cap via `key_id = "kind-g<gen>:<fingerprint>"`, #1457 merged):
- **Target-axis** — revoke every cap pointing AT a target T: `regenesis(T)` bumps T's generation → every cap keyed by an old gen fails `verify`. ALREADY EXISTS.
- **Principal-axis** — a principal P can no longer ACT anywhere: P's HELD caps are signed by OTHER targets (keyed by their gens), so bumping P's own gen does NOT kill them. RESOLUTION = **gen-check the principal at the two points authority is USED**: (1) authentication (bind P's PAT to P's generation), and (2) cap-load (`EntityCaps.load(P)` yields `[]` when P's generation moved past the generation its acting-credential was pinned to). Realized (recommended) as a **signed self-license cap** on P so principal-axis is literally a target-axis check on P's own authority — generation stays the single primitive.
- **delete_user(U)** = `regenesis(U)` (target-axis: caps-to-U die + principal-axis: U inert) + **cascade `regenesis` each owned/lineage agent** (each agent is its own principal). No separate "tombstone" mechanism — **tombstone == generation bumped past all live caps.**
- **Membership** = "holds the session membership cap" = a normal cap-check on `authorize/3`. The `members` roster is demoted to a delivery-targeting projection.

**Tech Stack:** Elixir/OTP umbrella (`apps/*`), Ecto + Postgres (`EzagentCore.Repo`), ed25519 caps (`:crypto` eddsa), ETS hot-caches (`EzagentCore.EtsOwner`), `mix test` + `mix ezagent.check_invariants` gates.

---

## Global Constraints (verbatim — apply to every task)

- **Born-signed base is MET.** Cap-signing Path A (per-Kind ed25519 authority) is MERGED (#1457): `cap/verifier.ex`, `cap/authority.ex`, `ecto/kind_cap_authority.ex`, `cap/signing.ex`. Build ON TOP; never re-implement cap-signing.
- **Strict verify is a precondition.** Generation protection is ZERO while `require_signature = false`. Every acceptance test runs under `require_signature = true` (spec-epoch §9.2).
- **Authz is a cap check or `Ezagent.Identity.admin?/1` — NEVER a hardcoded admin-principal comparison** (`cap_check_only_at_chokepoint_test.exs` p13 forbids `caller == admin_uri()` outside 3 allowlisted files). The bump primitive MUST be cap-gated (spec-epoch §9.1).
- **No back-compat shims** (`feedback_let_it_crash_no_workarounds`; SPEC v2 §5.11). DB wiped+reseeded on cutover EXCEPT the one-time membership-cap backfill (Phase M) and the additive `entity_tokens.bound_generation` column (Phase G-2), which are live-grants/additive, not schema back-compat.
- **`uv run` not `python`; `pnpm` not `npm`; `mix format` only touched files.** `mix precommit` is the final gate.
- **TDD every PR** (fail-before/pass-after, independently testable, frequent commits). Reproduce the deny/allow on a clean base or the failure is yours (`feedback_zero_new_failures_baseline_proof`). Completion = an invariant test that fails when the goal is unmet (`feedback_completion_requires_invariant_test`).
- **Fail-closed at every authority-use chokepoint:** a missing/unreadable authority or a failed gen-read is a DENY (`[]` / `{:error, …}`), never a default-allow — EXCEPT the documented `DBConnection.OwnershipError` test-sandbox rescue already used by `Offboarding.refute_tombstoned/1`.
- **Reviewer gate (core cap-model):** Phase F, Phase G, Phase D PRs, and the Phase M authz-integration PRs change the core cap model → **codex adversarial review BEFORE kimi implements each**; never self-merge (`feedback_codex_review_every_pr`, `feedback_no_admin_merge_codex_prs`). Per the orchestration doc: cc plans → kimi implements → codex reviews → cc merges.
- **MERGE GATE (repo-wide):** nothing merges until **CI-health is true-green** and the repo-wide CI unblock lands. Verify main is green (not just the PR) before merge (`feedback_verify_main_green_before_merge`).

### BASE-BRANCH RECONCILIATION SEAM (load-bearing — resolve at kickoff)

The three source plans do not share a base: epoch + membership are written against `origin/main` (`fe2906431`); delete_user cuts from `feat/delete-user-atomic-revocation` (#1469) and REUSES its cascade/`AgentTombstone`/`Offboarding` machinery, which **does not exist on main**. One spine needs one base.

**DECIDED (this plan): cut `feat/unified-generation-revocation` from `origin/main`.** The `tombstoned_principal?` transitive predicate from #1469 is **retired** (superseded by the generation primitive), and its **owned/lineage enumeration** is **NOT ported** — **[v2/MF6] it is superseded** by a fresh DURABLE APPEND-ONLY `derivation_edges` store + `record_derivation_edge` creation chokepoint + grep gate (D-1), because #1469's cascade rode the mutable single-parent `AgentLineage` (`forget/1`-deletable, depth-100 capped, un-indexed) — which cannot give the completeness guarantee the generation model needs (no transitive backstop). The rest of #1469 (`teardown_and_reap`, honest-terminate, reap-queue) is re-landed where the generation model still needs it (Phase D-3). **DECISION FOR CODEX/ALLEN:** confirm base = main + build the durable edge store fresh (recommended, keeps epoch/membership rebase-free) vs base = #1469 (forces epoch/membership to rebase onto unmerged work AND inherits the mutable-lineage completeness gap).

---

## THE UNIFIED PARADIGM (read first — this is the spine)

### The A/B/C model of delete

For `delete_user(U)` (the general shape; every delete is a subset):

| Axis | Threat | Mechanism | Status |
|---|---|---|---|
| **A — caps TO U** | someone holds `cap(→U)` and acts on U | `regenesis(U)` bumps U's gen → every `cap(→U)` fails `verify` (`key_id` mismatch) | **EXISTS** (per-Kind key_id + `regenesis`) — Phase G target-axis |
| **B — U's HELD caps** | U (or a stale process/token of U) presents caps signed by *other* targets | **gen-check the principal at authenticate + cap-load** (self-license realization) | **NEW** — Phase G principal-axis (THE key new mechanism) |
| **C — U's owned/lineage agents** | a derived agent A keeps acting after U is gone | **cascade `regenesis(A)` per owned/lineage agent** (each is its own principal → its own A+B) | **NEW closure** — Phase D cascade + enumerator gate |

**"Tombstone" dissolves:** a tombstoned principal is precisely one whose generation was bumped past all its live caps/credentials. There is NO separate tombstone table, marker, or predicate in the target design — `tombstoned_principal?/1` is replaced by the generation compare that Phase F/G already run at every chokepoint.

### Why principal-axis needs its own mechanism (and how generation stays the single primitive)

`regenesis(U)` re-keys the authority that signs caps **on U** (target-axis). But U's *held* caps are signed by their targets' authorities, keyed by *their* generations — bumping U's own gen does not touch them. So B needs a check keyed on **U's own generation**, applied wherever U's authority-to-act is consumed.

Two consumption points, both required:

1. **Authentication** (`token.ex` `enabled_principal/1`): a new login / a killed-then-respawned process re-authenticates. Bind the PAT to U's generation (Phase G-2). Bump U's gen → pre-bump PATs are stale → cannot authenticate → cannot spawn a principal → cannot present any cap.
2. **Cap-load** (`entity_caps.ex` `load/1` + `load_persisted/1`): a **live, already-authenticated** process does NOT re-authenticate — it keeps sourcing its cached slice caps via `EntityCaps.load(U)`. This is the bypass the token check alone cannot close. `EntityCaps.load(U)` must yield `[]` for a revoked principal (Phase G-3).

**Recommended realization of the cap-load gate — a signed self-license (makes generation literally the single primitive).** Rather than a mutable `acting_generation` baseline field (which is split across two stores — `users.caps_json` for users, the `:identity` slice for everyone else — and can be silently re-armed), give every principal P a **self-license**: a cap targeting P, granted to P, **signed by P's own authority** at principal creation. Then:

```
EntityCaps.load(P) returns [] UNLESS the loaded set contains a self-license L
whose embedded generation == KindCapAuthority.active(P).generation   # read FRESH from the DB active row
```

`regenesis(P)` bumps P's gen → P's old self-license `key_id = kind-g<old>` ≠ P's current active-row generation → the gate fails → `load(P)` returns `[]`. This is **exactly a target-axis check on P's own authority** — principal-axis IS target-axis applied reflexively. Properties: tamper-proof (a signed artifact cannot be re-stamped), **re-arm-impossible** without a deliberate re-issue of the self-license under the current gen (a legitimate re-credentialing act), and NO new mutable field or store-split.

> **Critical: the gate must read the CURRENT-ACTIVE authority row FRESH (via `verify_against_current/3` + the ETS `AuthorityCache`, F-1), NOT `valid_for_target?`.** `valid_for_target?` (#1477) verifies against the target's *cached* `state.authority`, which `regenesis` does NOT swap on a live process — so on a live/busy P it would keep validating the stale self-license until P restarts. The revocation basis is a fresh read of `KindCapAuthority.active/1`; see DECISION #2 and the #1477 section.

### Everything routes through ONE `authorize/3`

The generation checks (both axes), the membership predicate, and the holder identity live in a **single chokepoint** `Ezagent.Cap.authorize(holder_uri, candidate_caps, needed)`. This closes a REAL current gap: today only the in-dispatch `Cap.Verifier` checks signature/gen; three side paths authorize via bare `Capability.matches?` with NO signature/gen check —
- `Kind.default_holds_cap?/2` (`kind.ex:288-297`),
- `Capability.Authorization.authorizes?/2` (`authorization.ex:24-29`),
- `Identity.caps_authorize?/2` (`identity.ex:303`) —
so a **dormant old-gen cap passes them today.** Phase F routes them all through `authorize/3`.

---

## GROUND-TRUTH ANCHOR TABLE (real current-main — verified 2026-07-20 @ `origin/main` `fe2906431`)

Read current-main via `git show origin/main:<path>` or the clean off-main worktree `/private/tmp/ci189-bc-wt` (READ ONLY). Symbols the source specs named that **do NOT exist on main**: `Users.tombstone`, `Identity.Offboarding` (that's on #1469), `Entity.Token.revoke_all_for_entity`, `Cap.verify/1`, `granted_via_holds_cap?`, `runtime.ex:362-411`. Trust this table over the specs' cited lines.

| Concern | Symbol | Path:line |
|---|---|---|
| **BUMP primitive (admin-gated today)** | `Cap.Authority.regenesis/3` (gate `same_uri?(presenter, admin_uri())`) | `apps/ezagent_core/lib/ezagent/cap/authority.ex:57-78` |
| Generation → key_id encoding | `key_id/2` = `"kind-g#{generation}:#{fingerprint}"` | `cap/authority.ex:172-175` |
| Verify (compares key_id to CURRENT) | `Cap.Authority.verify/3` (`cap.key_id == authority.key_id`) | `cap/authority.ex:98-104` |
| Authority open (reads active row / genesis) | `Cap.Authority.open/2`; genesis refuses reuse `_historical -> Repo.rollback(:regenesis_required)` | `cap/authority.ex:34-42`; `:201-202` |
| In-process current-authority | `with_current/2`, `verify_current/2`, `current_target?/1` | `cap/authority.ex:118`, `:131`, `:140` |
| target_uri (rejects scope-tuples) | `target_uri/1` → `{:error, :concrete_target_required}` for non-URI | `cap/authority.ex:167-170` |
| Authority ecto (append-only, PK `(uri,generation)`) | `KindCapAuthority` (`active/1`, `insert/1`, `retire_active/1`, `next_generation`) | `apps/ezagent_core/lib/ezagent/ecto/kind_cap_authority.ex:15-66` |
| **THE dispatch verifier chokepoint** | `Cap.Verifier.authorize/5`; `verify_cap/5` (candidate filter) | `apps/ezagent_core/lib/ezagent/cap/verifier.ex:47`; `:68-97` |
| **Per-cap verify primitive (#1477 promoted PUBLIC)** | `Cap.Verifier.valid_artifact?/2` → `Authority.verify_current` | `cap/verifier.ex` (post-#1477; pre-#1477 = private `verified_artifact?`) |
| **Live-target-resolved current-authority verify (#1477 NEW)** | `Cap.valid_for_target?/2` (in-proc fast path OR `GenServer.call {:ezagent_verify_cap_artifact,…}`) | `apps/ezagent_core/lib/ezagent/cap.ex` (post-#1477) |
| Live-target verify handler (#1477 NEW) | `Kind.Server.handle_call({:ezagent_verify_cap_artifact,…})` (runs under `with_current(state.authority,…)`) | `apps/ezagent_core/lib/ezagent/kind/server.ex:639-651` (post-#1477) |
| Non-cap allowlist (dual-list) | `@non_cap_actions` / `non_cap_action?/2` | `cap/verifier.ex:21-41` / `:58` |
| Dispatch → verifier call | `Kind.Runtime.do_handle_dispatch/4` | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:161-173` |
| Authority cached once at init (stale on live bump) | `Kind.Server.init/1` (open `:120`, stored `:133`); retire on destroy `:614` | `apps/ezagent_core/lib/ezagent/kind/server.ex` |
| **Bare-matches BYPASS 1 (slice)** | `Kind.default_holds_cap?/2` (`granted_by_entity? + matches?`) | `apps/ezagent_core/lib/ezagent/kind.ex:255-312`, esp. `:288-297` |
| **Bare-matches BYPASS 2 (preflight)** | `Capability.Authorization.authorizes?/2` (`safe_matches?`) | `apps/ezagent_core/lib/ezagent/capability/authorization.ex:24-29` |
| **Bare-matches BYPASS 3 (identity)** | `Identity.caps_authorize?/2` | `apps/ezagent_domain_identity/lib/ezagent/identity.ex:303` |
| Canonical admin predicate | `Identity.admin?/1` | `identity.ex:124` |
| **Cap-load path (principal-axis gate site)** | `EntityCaps.load/1` (live-first, slice → `verified/2`); `load_persisted/1` (user=`UserStore.load`, else=`snapshot_caps`) | `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:44-52`; `:56-67` |
| **Authentication (principal-axis gate site)** | `Entity.Token.authenticate/1`; `enabled_principal/1` (user disabled-check only; agent `else -> {:ok, principal}`) | `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:105-116`; `:192-205` |
| **Token schema (needs `bound_generation`)** | `entity_tokens` (fields: `entity_uri, token_digest, digest_version, expires_at, workspace_uri…` — NO generation) | `token.ex:37-56` |
| Token mint (stamp site) | `mint/1` (`Repo.insert!` of the changeset) | `token.ex:76-104` |
| User delete (real path) | `Users.delete/1` (`Lifecycle.destroy` `:217`, `Repo.delete` `:227-233`) — **no owned-agent cascade on main** | `apps/ezagent_domain_identity/lib/ezagent/users.ex:209` |
| **Read-plane membership predicate (#166 + epoch A-4 + M-1 all touch)** | `Session.Membership.authorize/3` (`owner? or member_with_held_cap?` `:59`); `member?/2` `:108-111`; `holds_member_cap?/2` `:77-82` | `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55-71` |
| Receive-plane held-cap gate | `MemberReceive.authorize/1`; `holds_member_cap_over?/2` | `apps/ezagent_domain_identity/lib/ezagent/session/member_receive.ex:78-116` |
| Roster write (do_join) | `Membership.do_join/5`; `{:set, :members, …}` effect | `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:28-105`; `:461` |
| Member-cap grant (Phase-A mint, `:async`) | `MemberCap.grant_at_join/2` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:31-83` |
| Reconcile floor (union→evict flip) | `reconcile_after_load/2`; `candidate_uris/1` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex:53-85` |
| Supervisor cap bundle (NO member cap) | `ResponsibilityAssignment.assigned?/3`; `supervisor_caps_for_session/2` (bundle `:123-136`) | `apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignment.ex:106-136` |
| Supervisor write-plane acceptance (the asymmetry) | `SupervisorApproval.handle_submit_verdict/2` (`assigned?/3` gate, never `:members`) | `apps/ezagent_domain_session/lib/ezagent/behavior/supervisor_approval.ex:37-79` |
| Enumerator-gate model | `CapCheckOnlyAtChokepointTest` (`@probes`, `assert offenders == []`) | `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs` |
| Presence-tripwire model | `check_invariant_10` (greps `runtime.ex` for `Capability.matches?`) | `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex:294-320` |
| ETS hot-cache precedent | `Cap.DeliveryOutbox` (`@target_hint_table`, `rehydrate_hints/0`); `EtsOwner.@tables` | `apps/ezagent_core/lib/ezagent/cap/delivery_outbox.ex:28-71`; `ezagent_core/ets_owner.ex:32` |

---

## DECISIONS — resolve BEFORE kimi implements (this plan → codex adversarial review first)

Each is a **DECISION FOR CODEX/ALLEN**; recommendation is the default.

### DECISION #1 (LOAD-BEARING) — principal-axis cap-load gate: **signed self-license** (recommended) vs **mutable `acting_generation` baseline field**.
The gate must make `EntityCaps.load(P)` return `[]` for a revoked P, keyed on P's own generation, at BOTH `load/1` (slice) and `load_persisted/1` (user=caps_json / other=snapshot). Two realizations:
- **(1a — RECOMMENDED) self-license cap.** P holds a cap targeting P signed by P's own authority; `load(P)` gates the whole set on `action_of(L)==:self_license` AND `verify_against_current(L, P, P)` (fresh active-row read, F-1 — NOT `valid_for_target?`). Pure-generation, tamper-proof, re-arm-impossible, no store-split. **Open sub-question — ANSWERED by v2 ground-truth:** NO minted self-cap exists on main — the docstrings referencing `add_owner_identity_cap/2` are STALE (that function has no definition; self-authority is structural via `data_owner/1 = entity_uri`, `identity.ex:192-195`). So G-3a MUST mint the self-license fresh, and **[v2/MF1]** it is minted ONLY when `create_freshness == :created` (`server.ex:162`), seam 1a (thread into `Behavior.Identity.create/1`), with a dedicated `action: :self_license` axis. See v2/MF1 for the airtight un-re-mintable chain.
- **(1b — fallback) mutable `acting_generation`.** A durable per-principal baseline stamped at credential/grant issuance; `load(P)` returns `[]` when `acting_generation < current_generation(P)`. Must be written in BOTH stores and **pinned** at issuance — NEVER re-derived from current on activate/snapshot-restore (that re-arms a revoked principal). More code, store-split, mutable → re-arm risk.
**Recommendation: 1a.** It is the only realization under which "generation is the SINGLE primitive" is literally true. **The pin-timing property is the residual for codex regardless of realization** (see Residual Risk).

### DECISION #2 (CORRECTED — load-bearing) — target-axis revocation-verify: **`verify_against_current/3` (fresh active-row read)** vs #1477 `valid_for_target?` (cached-state).
**The revocation basis MUST be a fresh read of the current-active authority row, NOT the cached `state.authority`.** Traced against main: `regenesis/3` is pure DB (`retire_active` + `insert_generation`, `cap/authority.ex:57-78`) — it never swaps any live process's `state.authority`; `Kind.Server.init` opens the authority once and stores it (`:120-133`) and every handler runs under `with_current(state.authority,…)`. #1477's `valid_for_target?` verifies against exactly that cached authority (the `current_target?` fast path uses the process-dict authority; the `GenServer.call` handler runs `with_current(state.authority,…)`). **So after `regenesis(T)`, a LIVE T keeps validating gen-1 caps until it restarts** — which is precisely the "even if their processes are live/busy, kill-independent" case the acceptance criteria require. `valid_for_target?` does NOT propagate a bump on a live target.
The fix is epoch A-1's **`verify_against_current(cap, presenter, target) :: boolean()`**: read `KindCapAuthority.active(target)` FRESH (through an ETS `AuthorityCache` mirroring `DeliveryOutbox`, **invalidated on every `regenesis`**), reconstruct the public key + `key_id`, and compare `cap.key_id == active.key_id` + `:crypto.verify`. A fresh active-row read reflects the bump immediately, independent of whether the target's process is alive/busy — strictly more robust than an in-process swap message (epoch Decision #3), which would depend on a busy process handling a control message.
**Recommendation:** Phase F/G route every ACCESS/revocation check through **`verify_against_current/3`** (current key_id from the DB active row, atomically flipped by `regenesis`; ETS memoizes only the immutable `key_id → public_key` — v2/MF4, no mutable-cache staleness). Keep `valid_for_target?` ONLY where #1477 uses it — presenter-set freshness + grant idempotency, where "current as the target itself knows it" is the correct semantic. **This also resolves DECISION #2's stated hot-path worry** (the cross-Kind `GenServer.call`): a fresh ETS active-row read replaces the live call, removing the re-entrancy/latency hazard. Do NOT build the in-process swap handler (epoch Decision #3) — the fresh read obviates it.

### DECISION #3 — URI-reuse posture: **regenesis-on-recreate** (recommended) vs keep refuse.
Today `genesis/2` refuses reuse (`_historical -> Repo.rollback(:regenesis_required)`, `cap/authority.ex:201-202`), so a deleted URI cannot be recreated. Allen wants **recreate = regenesis**: on re-create at a deleted URI, `regenesis` to `next_generation` (strictly higher) so old caps to X fail gen-check. Use it as the **gen-bump acceptance test** (delete at X → recreate at X → old caps to X all fail → proves the bump). **Recommendation: wire re-create to regenesis** (guarded so only a legitimate re-create triggers it, not a stale race).

### DECISION #4 — one generation per URI conflates the two axes (flag; recommend one counter).
`regenesis(P)` bumps a SINGLE counter that both (target-axis) kills caps-to-P and (principal-axis) disarms P-as-actor. For delete/disable both are wanted → one counter is correct. A hypothetical "revoke everyone's access TO P but keep P acting" op cannot be expressed with one counter. **Recommendation: ONE counter (YAGNI second counter).** Document the conflation; add an inbound-vs-principal split only if such an op is ever required. **DECISION FOR CODEX/ALLEN.**

### DECISION #5 — supervisor moderation model (Allen's product decision; carries from #166 DECISION #A).
Grounded asymmetry on main: a workspace supervisor holds a cap bundle (`read_unfiltered`, turn/surface/verdict) but **NO membership cap** → **write plane ACCEPTS** them (moderate verbs authorize on the bundle), **read plane REJECTS** them (`Membership.authorize/3` has no supervisor branch). "Can moderate, cannot read" is the middle state Allen rejected. Under cap-as-truth it dissolves: **member IFF holds the membership cap.**
- **Option 1 (RECOMMENDED, Allen's default): no middle state.** A supervisor who must touch a session is granted a **per-session reviewer-membership** (holds the membership cap → is a real member with read+moderate). The content verbs (turn/surface/verdict) additionally require membership. Scope **1a: per-session opt-in** (not workspace-wide — avoids making a supervisor a member of every session + an after-created-session hook).
- **Option 2:** supervisors never act on session content (strip content verbs; workspace-scoped oversight only).
- **Option 3 (rejected):** keep the asymmetry as explicit content-free oversight.
**Recommendation: Option 1, scope 1a.** **DECISION FOR ALLEN** — S-2's code is GATED on this choice.

### DECISION #6 — scope-tuple caps (`{:within_session, S}` etc.) bind to scope-target gen vs exempt. **[v2/MF9 upgraded — now paired with a denial proof.]**
Scope-tuple caps are minted off a different path (`target_uri/1` rejects them) and are not signed by a target authority → neither axis binds them. **Recommendation: DEFER bringing them under signing** — BUT v1's "exempt" is upgraded to **denied at ACCESS** (they fail `verify_against_current` and are stripped from durable slices by `verified/2`; permitted only as grant-authorization bounds), with a Z-1 gate proving no production ACCESS dispatch rides an unsigned scope-tuple `ctx.cap`. See v2/MF9. **DECISION FOR ALLEN:** confirm DEFER is acceptable given they are now provably denied at access.

### DECISION #7 — `merge_member` shape (#166 DECISION #B).
Express `merge_member(from→to)` as `grant(to)` + cap-gated `self-add(to)` + `leave(from)` (reuses the Phase-A/B seam) vs a dedicated cap-gated relabel handler. **Recommendation: (i) compose existing seams**, preserving read-marker repoint atomicity. **DECISION FOR CODEX.**

### DECISION #8 — create-path first-message delivery (#166 DECISION #D). **[v2/MF10 made concrete.]**
Between grant (Phase A) and self-add (Phase B), a fan-out may target an incomplete roster → a new member could miss the FIRST message. **Recommendation: (i) durable joined-cursor + replay is mandatory (correctness); (ii) eager warm is an optional create-path optimization.** v2/MF10 makes (i) concrete: the cursor is set atomically-with the `{:set, :members}` mount (not the async grant) and is a monotonic SEQ (not wall-clock). **DECISION FOR ALLEN:** confirm seq-vs-timestamp.

### DECISION #9 (NEW — [v2/MF7]) — delete cascade: durable pending-revocation FENCE vs one atomic transaction.
The cascade must leave NO window where a descendant is live because its bump hasn't committed. **(i — RECOMMENDED) durable fence** (enroll U + `descendants(U)` before any bump; deny at authenticate/load/authorize; clear per-bump) — the only option that scales to unbounded lineage and survives a mid-cascade crash. **(ii) one atomic `Repo.transaction`** over U + all descendants — simple but infeasible for large lineages and rolls back everything on any failure. **Recommendation: (i) fence.** See v2/MF7 / D-5. **DECISION FOR ALLEN.**

### DECISION #10 (NEW — [v2/MF6]) — provenance store + "owned" edge-kind scope.
**#A (store):** a new dedicated append-only `derivation_edges` table (RECOMMENDED) vs extend `CreationInventory`. **#B ("owned" scope):** which edge KINDS (creator / `spawned_by` / workspace-ownership / `parent_template_uri`) a `delete_user` cascade closes over — ALL are recorded as edges; which trigger the cascade (e.g. does deleting a user delete forked-template descendants?) is the product call. **Recommendation: dedicated table + cascade over the full edge set.** See v2/MF6 / D-1. **DECISION FOR ALLEN** — this is the cascade-completeness source of truth; do NOT let kimi invent the definition.

---

## v2 — codex must-fix resolutions

> Codex verdict on v1: **NEEDS-REVISION.** The generation primitive is a viable foundation, the self-license CONCEPT is right, and the phase structure + #1477 land-first coordination hold. But v1 did not yet PROVE principal revocation, kill-independence, descendant completeness, or single-chokepoint coverage — it contained privilege-restoration paths AND false-revocation windows. This section resolves ALL 10 must-fix items against real current-main code (`origin/main` `fe2906431`, verified 2026-07-20); each fix is FOLDED into the numbered PR that carries it (see the per-Phase "**[v2/MF-N]**" call-outs). A fix is either **RESOLVED-IN-CODE** (concrete mechanism + file:line) or **DECISION FOR ALLEN** (a real product/architecture choice — options + recommendation).
>
> **The two load-bearing sharpenings:** (i) the self-license mechanism is made airtight by **mint-only-on-genuine-creation** (`create_freshness == :created`, server.ex:162) + **dependency-inverted holder-license resolution** (the principal gate is checked on the HOLDER's independently-loaded set, never on inline `ctx.caps`); (ii) the cascade is made provably complete by a **durable append-only derivation-edge chokepoint + grep gate** (not a mutable/bounded walk) plus a **durable pending-revocation fence** that fail-closes descendants until every bump commits. **MF8 is corrected — see below; its resolution does NOT lean on generation/self-license.**

### MF1 — Unique self-license artifact + mint-only-on-creation recognition rule. **RESOLVED-IN-CODE** (one seam DECISION).

**The artifact (unique, unforgeable, un-re-mintable).** A self-license is a `%Capability{}` with a **dedicated recognizable action axis `action: :self_license`** (a new reserved action, matched as a real axis by `capability/match.ex`), `kind = P`'s kind, `instance = P`, `grantee_uri = P`, **signed by P's OWN authority** (`key_id = kind-g<gen>:<fp>`) via `Cap.Grant.issue`/`Authority.sign` (`authority.ex:82-94`). Uniqueness: exactly one self-license per principal, enforced by a mint-guard that fail-closes if any `action: :self_license` cap already exists in P's durable store. Unforgeable: it is a target-signed artifact — reproducing it needs P's private key, which never leaves the framework compartment (`authority.ex` moduledoc). Un-re-mintable by a revoked principal: see the adversarial chain below.

**Recognition rule (the gate — G-3b).** `EntityCaps.load(P)` returns `[]` UNLESS its loaded set contains a cap `L` with `Capability.action_of(L) == :self_license` AND `Cap.Authority.verify_against_current(L, P, P) == true` (fresh active-row read, F-1 — NOT `valid_for_target?`).

**Mint-ONLY-on-creation (the airtight property).** The signal already exists on main and is **currently unconsumed** — wiring the self-license mint to it is its first real use: `Ezagent.Lifecycle.fresh_create?/1` (`lifecycle.ex:399-403`, `true` iff the durable `kind_snapshots.ever_created` marker is absent), surfaced as `Kind.Server` state **`create_freshness == :created`** (`server.ex:157-165`), computed BEFORE `persist_initial_snapshot` sets the marker (`server.ex:167`). The self-license is minted **iff `create_freshness == :created`** — NEVER on `:existed` (rehydrate/cold-restart), `:unknown` (non-Lifecycle Kind), snapshot restore, activation, or baseline replay.

**SEAM DECISION (flagged for codex) — where the mint runs.** `create_freshness` lives in core `Kind.Server.init` (`server.ex:162`) and is NOT threaded into the domain create hooks today (`activate`/`post_init` ctx is only `%{kind_module:, self_uri:}`, `server.ex:419,583`); the durable cap store is domain (`users.caps_json` / the `:identity` slice). Pick ONE seam explicitly (do not ship "init OR create hook"):
- **(1a — RECOMMENDED) thread `create_freshness` into the create hook.** Add `create_freshness` to the create-path ctx (`server.ex`) and mint the self-license in `Ezagent.Behavior.Identity.create/1` (`identity.ex:143-172`, which already runs create-only via `__init_slice__` and already assembles the initial `:identity` slice caps) when ctx says `:created`. Keeps the signed-cap mint in the domain that owns the durable store; the core only forwards the boolean. **Recommendation: 1a.**
- **(1b) mint in `Kind.Server.init` directly at `server.ex:162`** under the just-opened authority. Simpler wire, but puts a domain-cap mint in the core Kind server and needs a core→domain persistence call. Rejected unless 1a proves infeasible.

**Composition with DECISION #3 (URI-reuse=regenesis) — REQUIRED.** (i) `delete_user`/`revoke_all_to` MUST clear the stale self-license from P's durable store as part of the delete (else a leftover old-gen self-license is harmless — it fails `verify_against_current` — but leaving it is untidy and confuses the enumerator; clear it). (ii) A legitimate **re-create at a reused URI** runs `genesis`→`regenesis` to `next_generation` (DECISION #3) and is `create_freshness == :created` for the new instance → it mints a **new** self-license under the **post-regenesis current gen**. This is the ONE legitimate re-arm and it is a deliberate re-creation, not a restart.

**The un-re-mintable-by-a-revoked-principal proof (the adversarial chain codex asked for — grounded in DECISION #2).** After `regenesis(P)`:
- A **live** bumped P keeps its **gen-N** `state.authority` cached (regenesis is pure DB, never swaps a live process's cached authority — `authority.ex:57-78`, DECISION #2). Any `issue_current` it runs mints a **stale gen-N** self-license → fails `verify_against_current` → still `[]`.
- A **restarted** P re-opens the CURRENT authority (gen N+1) via `Authority.open` (`authority.ex:34-41`) BUT boots with `create_freshness == :existed` (the `ever_created` marker persisted at first creation — **guaranteed still present by the v4-H2b marker-preservation gate**, so no non-delete site can have dropped it out from under a revoke-without-delete principal) → the mint guard does NOT fire → no new self-license → `load(P)` stays `[]`.
- Only **delete + deliberate recreate** (a fresh genesis, marker cleared) legitimately mints a current-gen self-license. There is no path where a revoked principal re-arms itself.

**Residual to verify (G-3 step 5):** `activate/2` (`identity.ex:206-221`) re-unions `users.caps_json` into the live slice on EVERY start (idempotent set-union). This re-applies the SAME (old-gen) self-license — it does NOT re-mint under a fresh gen, so it is harmless — but the G-3 re-arm test MUST assert exactly this: activate/snapshot-restore re-adds only the stale artifact, never a current-gen one.

**Carrier PR:** G-3a (mint + seam), G-3b (recognition gate), delete-clears-self-license folds into D-2.

### MF2 — Dependency-inverted holder-license resolver. **RESOLVED-IN-CODE.**

`authorize(holder, candidates, needed)` MUST load the holder license **independently** — inline candidates (`ctx.caps`) can NEVER satisfy the principal gate. Concretely, F-1's facade runs the principal gate FIRST and from its OWN source:

```
authorize(holder, candidates, needed):
  # PRINCIPAL GATE — resolved independently, ignores `candidates`
  licensed = EntityCaps.load(holder)                         # entity_caps.ex:43-52 (fail-closed, self-license-gated by G-3b)
  unless Enum.any?(licensed, &self_license_current?(&1, holder)), do: return {:error, :holder_revoked}
  # TARGET GATE — per-cap sig/gen on whatever caps were presented
  candidates
  |> Enum.filter(&Cap.Authority.verify_against_current(&1, holder, target_of(&1)))
  |> Enum.find(&Capability.matches?(&1, needed))
  |> case do nil -> {:error, :no_matching_cap}; cap -> {:ok, cap} end
```

The principal gate reads `EntityCaps.load(holder)` (`entity_caps.ex:43-52`) — the framework's independent holder-cap source, gated by G-3b's self-license — **not** the `candidates` argument. This closes v1 Residual (a)'s sharpest edge: a revoked principal presenting a still-valid `cap(→T)` inline is denied because `holder` has no current self-license, regardless of what `candidates` contains. **Carrier PR:** F-1.

### MF3 — Explicit AUTHENTICATED holder at every authorization API. **RESOLVED-IN-CODE** (new PR F-6).

Every authorization API + consumer passes the **authenticated principal** explicitly; the holder is NEVER inferred from caps AND is **NOT `ctx.caller`** when the caller is machinery (CapBAC §1: caller is frequently an HTTP handler/reconciler/effect, not the principal). The authenticated holder is the value fixed at the auth boundary — `Entity.Token.authenticate/1`'s result (`token.ex:105-116`) or the web/CLI session principal — threaded down to each chokepoint:
- `Cap.Verifier.authorize/5` (`verifier.ex:47`), `Kind.default_holds_cap?/2` (`kind.ex:288-297`), `Capability.Authorization.authorizes?/2` (`authorization.ex:24-29`), `Identity.caps_authorize?/2` (`identity.ex:303`), `Session.Membership.authorize/3` (`membership_predicate.ex:55`) each take an explicit `holder_uri :: URI.t()` parameter carrying the authenticated principal.
- The plan states, per entry point, WHERE the authenticated holder comes from: web = the session principal (not the controller module); CLI = the authenticated `--as`/token principal; dispatch = the ctx's authenticated principal field (added), which is `ctx.caller` ONLY when caller IS the authenticated principal, never when caller is grant/reconcile machinery.
**Carrier PR:** F-6 (holder threading) — lands with F-2 (the bypass engines are the consumers that gain the explicit param).

### MF4 — Race-proof revocation basis (DB active row authoritative; no mutable-current cache to go stale); no process-dict shortcut. **RESOLVED-IN-CODE.**

**(a) Drop the process-dict fast path from the REVOCATION basis.** v1's F-1 specified "use the process-dict authority when `current_target?(target)`." REMOVE that for `verify_against_current/3`: the revocation basis reads ONLY the fresh active row (via `AuthorityCache`, read-through to `KindCapAuthority.active/1` on miss). `current_target?/1` (`authority.ex:140-145`) and `verify_current/2` (`authority.ex:131-136`) both read `Process.get({__MODULE__, :current})` — the live process's cached (stale-on-bump) authority — so they can NEVER carry a revocation check. They remain in use ONLY for in-process issuance (`issue_current`) and #1477's grant-idempotency, never for ACCESS/revocation.

**(b) The race-proof design: there is NO mutable "current authority" in ETS to go stale — so no stale-PRESENT window exists.** A plain `Repo.transaction` + a separate mutable `uri → current_key_id` ETS entry CANNOT be made atomic — a stale-present entry (written before the flip, not yet deleted) is not a miss; it would validate the OLD `key_id` in the commit→delete window. The fix removes the hazard structurally:
- **The CURRENT key_id for a target is read from the DB active row** (`KindCapAuthority.active(target).key_id`) — authoritative, and flipped atomically by `regenesis`'s transaction (serialized by the `active` partial-unique constraint). This is the revocation basis.
- **`AuthorityCache` memoizes ONLY the IMMUTABLE `key_id → public_key` mapping** — a given `key_id` (`kind-g<gen>:<fp>`) always maps to the same public key, so this entry can NEVER be stale (no invalidation needed; entries are add-only memos). `verify_against_current` reads the current `key_id` from the DB active row, then fetches the (immutable) public key from ETS (read-through to the DB row's `public_key` on miss), then `cap.key_id == current_key_id` + `:crypto.verify`. A revoked cap's old `key_id ≠ current_key_id` → DENY, with zero dependence on a mutable cache.
- The invariant is thus **"the current key_id is always the committed DB active row; ETS holds only immutable-by-construction data"** — strictly stronger than v1's "invalidate inside the transaction," which still left a commit→delete window for a present entry. A `uri → current_key_id` hot-path cache (with invalidate-in-transaction + generation-compare + read-through) is a LATER optimization that MUST preserve this invariant; it is not required for correctness.
**Carrier PR:** F-1 (DB-authoritative current key_id + immutable-keyed ETS memo + read-through), G-1 (regenesis flips the active row in-transaction — the atomic serialization point).

### MF5 — Gate ALL post-bump recredential paths. **RESOLVED-IN-CODE** (new PR G-6 + shared gate Z-1).

Every path that mints a bearer secret, issues a cap, or returns a principal's caps must read/stamp the principal's CURRENT generation and fail-closed on a bumped principal. The complete enumeration (verified 2026-07-20) — each is stamped-or-gated, and the Z-1 enumerator asserts none is added un-gated:

| # | Path | file:line | Gate |
|---|---|---|---|
| 1 | `Entity.Token.mint/2` + `rotate_label/3` | `token.ex:72`, `:120` | stamp `bound_generation = current_generation(uri)` (G-2); mint FAILS if the principal has no active authority row |
| 2 | dispatchable `:mint_token` action + `handle_mint_token/2` | `user_tokens.ex:95-109`, `:173` | rides #1 (calls `Token.mint`) |
| 3 | HTTP one-time PAT (`PatDelivery.issue/3`, dormant but wired to `/login/token`) | `pat_delivery.ex:14`; route `session_controller.ex:161` | rides #1 |
| 4 | Mix `ezagent.user.token --mint` | `ezagent.user.token.ex:102` | rides #1 |
| 5 | **Agent auto-provision CLI-identity PAT** | `spawn_plan.ex:335` | rides #1 |
| 6 | **Agent-bridge file bearer `EZAGENT_AGENT_TOKEN` (SEPARATE from `entity_tokens`; idempotent-no-rotate today)** | `agent_bridge/token_store.ex:32` | **NEW: gen-stamp the on-disk token; INVALIDATE-on-bump (a bumped agent's bearer is rejected). Re-mint ONLY through the legitimate re-provision path (spawn/create, gated like the self-license mint-on-create) — NOT auto-remint on detecting a higher gen (that would hand a fresh bearer to a just-revoked agent = re-arm). (G-2's `bound_generation` does NOT cover this store — MF5's "automatic agent PAT provisioning" path.)** |
| 7 | cap-issuing Mix tasks (user.create, agent.create, workspace.create_session, grant_recipe_caps, migrate.member_caps, session.migrate_grants, stress) | `ezagent.user.create.ex:245`, `ezagent.agent.create.ex:194`, `ezagent.workspace.create_session.ex:66`, `ezagent.agent.grant_recipe_caps.ex:340`, … | issue under the target's current authority (the anchor read is gen-bearing via `Cap.authorization_context` `cap.ex:232-244`); a bumped target's old-gen issuance fails `verify_against_current` at use |
| 8 | Baseline / self-target issuance: `User.default_caps` (now `[]`), self-Identity cap, session-join grants, `admin_genesis_cap/0` | `user.ex:140`, `identity.ex:143-160`, `member_cap.ex:31`/`membership.ex:713,1245`, `capability.ex:249-265` | self-target construction gated at the self-issue chokepoint `cap.ex:99-104` (`current_target?` → ADD a current-generation check); session-join grants gated by MF8's entitlement rule |
| 9 | cap-list helpers: `EntityCaps.load`/`load_persisted`, `read_held_caps`, `list_caps_for` | `entity_caps.ex:43-67`, `identity.ex:274-279`, `:26-27` | all funnel through `EntityCaps.load` → G-3b self-license gate returns `[]` for a bumped principal |

**Carrier PR:** G-6 (recredential-generation gate: stamp/gate #1, #5, #6, #8-self-target; the shared Z-1 enumerator asserts every mint/issue site reads current generation).

### MF6 — Complete durable provenance (append-only derivation edges; no depth cutoff). **DECISION FOR ALLEN** (store choice + "owned" scope) with a recommended RESOLVED-IN-CODE design.

**The gap (verified):** no complete durable provenance exists on main. `AgentLineage` (`agent_lineage.ex`) is durable-but-MUTABLE (upsert + `forget/1` hard-delete), single-parent, un-indexed on `spawned_by`, and its only walk is the depth-100-capped UPWARD `spawned_in_lineage?/3` (`agent_lineage.ex:141-157`) — it cannot enumerate descendants. `CreationInventory` (`creation_inventory.ex`) IS append-only but is written at exactly ONE site (agent template-spawn, `template_spawn.ex:798-812`), records a single `provenance_root_uri` per row, and has no owner-indexed query. `entity_tokens`, the ApiKeys slice, and `kind_snapshots` carry no descendant edge.

**Completeness is a CREATION CHOKEPOINT + grep gate, not an index (the airtight design).** An owner index on a store that creation sites bypass proves nothing. Mirror the cap-check chokepoint pattern:
- **`record_derivation_edge(child_uri, parent_uri, kind, attempt_id)`** — a single append-only writer over a durable `derivation_edges` table (columns: `child_uri, parent_uri, edge_kind, attempt_id, inserted_at`; unique `(child_uri, edge_kind)` — **[v4-H1] NOT `(child_uri)`**: a child may carry multiple provenance edges of DIFFERENT kinds (`spawned_by` A AND template-forked from T); **index on `parent_uri`** for the reverse walk). Append-only (no update/delete; a delete is a bump, not an edge removal).
- **`descendants(root_uri) :: [URI.t()]`** — transitive closure over `derivation_edges` (recursive CTE / iterative frontier) that **[v4-H1] UNIONS the reverse-walk frontier over ALL `edge_kind`s** at each step, **NO depth-100 cutoff** — the closure runs to fixpoint.
- **Grep invariant `derivation_edge_chokepoint_test.exs`** — fails CI if any principal-creation site (user create, agent create, agent spawn, session materialize, template fork) constructs a principal without routing through `record_derivation_edge` — the same shape as `grant_dispatch_chokepoint_test.exs`. THIS is what makes the enumerator's source provably complete.

**DECISION FOR ALLEN #A (store):** (i — RECOMMENDED) a new dedicated `derivation_edges` table (clean single-responsibility, indexed both directions), vs (ii) extend `CreationInventory` (already append-only) with a `parent_uri` index + reverse query. Recommend (i) — CreationInventory's `(attempt_id, agent_uri)` key and agent-only write site make it awkward to retrofit as the universal edge store; a purpose-built append-only edge table with the chokepoint is cleaner and the grep gate guarantees every creation writes to it.
**DECISION FOR ALLEN #B ("owned" scope — supersedes v1's D-1 "pin owned concretely"):** which derivation edges count as an ownership edge that `delete_user(U)` cascades over — creator (`created_by`), spawn lineage (`spawned_by`, `agent_lineage`), workspace-ownership, `parent_template_uri` (template fork)? Recommend: **ALL of them are recorded as edges** (the chokepoint captures every derivation), and the cascade closes over the full edge set; narrowing which edge KINDS trigger a `delete_user` cascade (e.g. does deleting a user delete forked-template descendants?) is the product call. **This is the cascade-completeness source of truth — the enumerator gate (D-1/Z-1) runs empty-allowlist against `descendants(U)`.**
**Carrier PR:** D-1 (the edge store + chokepoint + grep gate + `descendants/1`), replacing v1's "port #1469 owned/lineage query."

### MF7 — Atomic cascade OR durable pending-revocation fence. **DECISION FOR ALLEN** (recommend fence) — **RESOLVED-IN-CODE** design.

There must be NO window where a descendant is live because its bump has not committed yet. Two options:
- **(i) atomic cascade** — bump U + every `descendants(U)` in one `Repo.transaction`. Simple, but a large lineage makes one transaction huge/long-held → infeasible at scale, and a mid-cascade crash rolls back ALL bumps (U left live).
- **(ii — RECOMMENDED) durable pending-revocation fence + worklist.** A durable `revocation_fence` table. `delete_user(U)`: (1) compute `descendants(U)` from the complete edge set (MF6); (2) **INSERT a fence row for U AND every descendant BEFORE bumping any** (single small transaction); (3) bump each (idempotent, retryable worklist); (4) clear each fence row only after its bump commits. **The fence is enforced at the authority-use gates, fail-closed** — the **ACT-TIME completeness boundary** `EntityCaps.load/1` (`entity_caps.ex:43-52`) + `Cap.authorize/3` (F-1), the gates every principal (agent or user, live or cold) MUST pass to ACT, so a cascade descendant is inert the instant the fence is written, before its own bump lands, with no live window — **[v4-H4] the boundary is these act-time gates, NOT a single spawn chokepoint** (descendant agents spawn via `Kind.spawn`/`SpawnRegistry.spawn`, bypassing `spawn_principal` entirely). Plus `Entity.Token.authenticate/1` (`token.ex:105-116`, PAT login) and `Ezagent.Entity.spawn_principal/1` (`entity.ex:70`, the extra early gate for cold user-login — magic-link/invite — that bypasses `authenticate`; [v4-H4]). Each DENIES when a fence row exists for the principal. The fence is not a parallel mechanism — it rides the existing authority-use gates.

**Sequencing:** MF7 depends on MF6 (the fence must know whom to fence). D-1 (edge store) → D-2 (bump+cascade) → **D-5 (durable fence, new PR)**. **Recommendation: (ii) the fence.** **Carrier PR:** D-5.

### MF8 — Reconciliation must require CURRENT entitlement, not stale roster/navigation. **RESOLVED-IN-CODE** (new PR M-10) — **CORRECTED from v1.**

**The corrected threat (this is NOT the gen-bump case).** The load-bearing re-arm is **single-holder revoke with generation UNCHANGED** (this plan's own G-4 step d: `Capability.revoke/2` de-authorizes one holder without a bump). After it: M's self-license is still current, `EntityCaps.load(M)` still works, only M's one membership cap was revoked. The generation mechanism does NOT close this — per-member revoke is not a bump, so **self-license/G-3 cannot be the fix.** The re-arm: a **roster/navigation-driven mount** re-grants M a fresh VALID membership/participation cap because its idempotency guard tests "M **lacks** the cap," not "M is **currently entitled**":
- `MemberCap.grant_at_join/2` guard `holds_member_cap_exact?/3` (`member_cap.ex:36`) — grants when M does not hold the exact member-cap.
- `grant_session_caps`/participation mount guard `already_authorized?/5` (`membership.ex:1341`, `:1328-1371`) — mounts when M does not hold an authorizing cap (`matches?`).
The stale `:members` roster is precisely what keeps M's client able to TRIGGER these owner-side/navigation mounts after revoke.

**The rule: roster presence is NOT entitlement.** The authoritative current-entitlement source is the **tier-1 membership cap itself** (this plan's cap-as-truth thesis). Three tiers, gated differently — and closing the roster-iteration vector is NOT enough; the **authenticated-rejoin vector** must also be closed (see the DECISION below):
- **Tier-0 (the JOIN-authorization — what lets M obtain tier-1 at all):** a non-public session's `:join` is authorized by a **join-entitlement** (an owner-granted join cap / invite / standing owner-intent), NOT by "M is a valid principal." `grant_at_join` fires only when `authorize(M, load(M), join_needed(S))` passes on tier-0. **This is the gate the roster-driven mounts bypass AND the gate a revoke-then-rejoin would exploit if tier-0 is left intact.**
- **Tier-1 (the membership `:receive` cap — the current-participation ENTITLEMENT):** granted ONLY on an authenticated `:join` that PASSES the tier-0 gate (`membership.ex:88`), or an owner grant — **NEVER re-granted from a roster iteration / reconcile / backfill sweep.**
- **Tier-2 (participation/view caps — `mount_participation_caps`, `grant_session_caps`):** mounted as a CONSEQUENCE of M CURRENTLY holding tier-1, verified through `Cap.authorize(M, load(M), tier1_needed)` (F-1) — NOT roster presence. After a tier-1 revoke, the tier-2 mount's precondition fails.

**The discriminating gate (M-10):** every re-grant/mount path is classified — driven by the **roster projection** (owner-side mount iterating `:members`, reconcile/backfill) or by an **authenticated M action**? Roster-driven re-grants are removed/re-gated to consult tier-1 possession via `authorize/3`. `reconcile_after_load/2` (`reconcile.ex:52-78`) already only heals the projection (reads live caps, never mints) → with tier-1 as truth it EVICTS a revoked M.

**DECISION FOR ALLEN (MF8 entitlement-source — the load-bearing semantics):** what does single-holder-revoke of M's membership cap (gen UNCHANGED) MEAN? Because M is still a live principal with a current self-license, M can issue an authenticated `:join` — so the answer determines whether revoke-then-rejoin is a re-arm:
- **(EJECT — RECOMMENDED for offboarding/removal):** M is BARRED from S. The revoke/eject operation revokes M's join cap **AND writes a durable per-`(M,S)` bar** — **[v3-H3] the "/" was an OR; the bar is mandatory, not an alternative** — so a rejoin attempt is DENIED **at EVERY tier-0 admission entry** (**[v4-H3] there is no single tier-0 gate** — the four entries are enumerated in M-10), NOT re-granted. This is what makes G-4 step d (single-holder revoke) airtight against rejoin. **Every delete/offboard uses EJECT.**
- **(DROP):** M is only removed from CURRENT participation and MAY rejoin if S's join-policy still permits (tier-0 intact). Then revoke-then-rejoin is legitimate, NOT a re-arm — and G-4 step d holds only until a policy-permitted rejoin. Appropriate for a voluntary `:leave`.
**Recommendation: the membership-revoke used by delete_user / offboarding = EJECT (removes tier-0); a voluntary leave = DROP.** Without this, "tier-1 is the entitlement source" is circular for the grant path (the cap does not exist at join-time — tier-0 gates the grant).

**New acceptance tests (M-10):** (i) roster vector — revoke M (gen unchanged) → stale roster lists M → M re-navigates → tier-2 mount DENIES + no fresh tier-1 (M stays out); (ii) **rejoin vector — EJECT M → M issues an authenticated `:join` → DENIED at tier-0 (join-entitlement removed), no tier-1 re-granted**; (iii) DROP M on a permissive session → M may rejoin (documents the semantics). **Carrier PR:** M-10.

### MF9 — Scope-tuple caps: honest narrowing + a denial proof. **DECISION FOR ALLEN** (keep DECISION #6 defer) — **RESOLVED-IN-CODE** narrowing.

Scope-tuple caps (`{:within_session, _}` etc.) cannot be target-signed (both issuance gates require a concrete `%URI{}`: `authority.ex:170`, `cap.ex:30`, `cap/grant.ex:57-59`) and are matched structurally by `capability/match.ex:120-144` with no signature/generation. v1 "exempt with an allowlist entry" is too weak — pair the exemption with a DENIAL PROOF:
- **Denied at ACCESS after F-2.** An unsigned scope-tuple cap FAILS `verify_against_current` (no `key_id`/signature) → it cannot authorize ACCESS via the verifier OR the ex-bypass engines once F-2 routes them through `authorize/3`. Durable slices already STRIP scope-tuple/unsigned caps on read (`entity_caps.ex` `verified/2:266` → `storable_for?` `cap.ex:188-200` requires a `%URI{}` instance + binary sig+key_id), so they never enter held-cap authorization.
- **Permitted ONLY as grant-authorization BOUNDS.** Scope tuples legitimately appear in `rule_cap_bounded?` (grant scoping) and wire round-trip — never as an ACCESS authorizer.
- **Production expands delegation to concrete signed caps** (`orchestrator/caps.ex:155-181` builds concrete `session_uri` caps; the only true tuple `ctx.caps` are unsigned in-memory e2e scaffolding, `agent_contract_g4.ex`).
- **New gate (Z-1):** assert NO production ACCESS dispatch authorizes on an unsigned scope-tuple `ctx.cap` against a revocable target. The "single chokepoint" claim is narrowed HONESTLY: scope-tuple caps are **denied at access, permitted only as grant bounds** — not "allowed unchecked."
**DECISION FOR ALLEN:** confirm DECISION #6 (DEFER bringing scope-tuple caps under signing) is acceptable GIVEN they are now provably denied at access. **Carrier:** F-2 (denial) + Z-1 (the proof gate).

### MF10 — Durable join cursor + replay closing the create/join first-message window. **RESOLVED-IN-CODE** (folded into M-4).

The window (verified): `do_join/5` grants via an `:async` best-effort cast (`membership.ex:88`) and mounts the roster via a DEFERRED `{:set, :members, …}` effect (`membership.ex:461`) applied only after the handler returns; `last_seen` is a cursor set ONLY on disconnect (`session.ex` `handle_signal({:DOWN,…})`) and is DELETED at join (`membership.ex:426-428`); `replay_messages_since` returns `:ok` for a nil cursor (`delivery.ex:382-387`). So a first-time joiner has NO cursor → the first message published before the mount commits is never captured or replayed.

**Fix:** establish a **durable join cursor as part of the SAME committed effect batch as `{:set, :members}`** (`membership.ex:461`) — NOT the async grant (which can be lost). In `do_join_apply/5`, instead of DELETING the member's `last_seen`, SET it to the join point and replay from it. **Prefer a monotonic sequence** over wall-clock `DateTime` (define inclusive/exclusive if timestamps are retained) to avoid same-instant first-message loss. `replay_messages_since` then replays every message from the join cursor forward, closing the nil-cursor initial window. **Carrier PR:** M-4 (readiness barrier + replay cursor — now made durable+atomic-with-mount and seq-based).

---

## v3 — round-2 review holes (RESOLVED)

Second adversarial review (2026-07-20, static/git vs `origin/main` `5f5c811d7`) returned **NEEDS-REVISION** with 4 concrete, individually-fixable holes; architecture SOUND. Each folds into an existing task (+0 PRs). Resolutions:

### v3-H1 (was MF6, STRONGEST) — `derivation_edges` single-parent contradiction.
**Hole:** D-1 (`unique(child_uri)`, ≤1 edge/child) contradicts DECISION #10B (record ALL edge kinds: creator / `spawned_by` / workspace-ownership / `parent_template_uri`). A child with divergent provenance (spawned_by A AND template-forked from T) cannot satisfy both — `unique(child_uri)` re-creates the exact single-parent limitation this plan faulted in `AgentLineage`. A dropped edge → an entity missing from `descendants(U)` → un-cascaded AND (the MF7 fence enrolls the same `descendants(U)` set) un-fenced and fully live.
**Resolution:** the constraint is **`unique(child_uri, edge_kind)`** (a child may carry multiple provenance edges of different kinds); `descendants/1` unions the reverse-walk frontier over ALL edge_kinds to fixpoint. Multi-provenance preserved, no single-parent limit. Grep gate + fixpoint closure unchanged. Update D-1 (§ `record_derivation_edge`) + DECISION #10.

### v3-H2 (was MF1) — self-license un-re-mintability is not GATE-enforced.
**Hole:** no exploit found, but un-re-mintability rests on the emergent property "only `Behavior.Identity.create/1` constructs an `action: :self_license` cap" — not a gate (violates the plan's own MF6 chokepoint+grep methodology). Sub-gaps: (a) no assertion no OTHER site constructs `:self_license`, no refusal of it in the general issue path; (b) restart-safety assumes `ever_created` is cleared ONLY by delete — a snapshot GC/compaction clearing it makes a restarted revoked-not-deleted principal `create_freshness == :created` → mint a fresh self-license at the BUMPED gen (re-arm).
**Resolution:** (a) Z-1 grows two assertions: (i) `action: :self_license` is CONSTRUCTED at exactly one source site (the G-3 create-hook mint) — grep gate fails on any other constructor; (ii) `Cap.Grant.issue`/the general grant path REFUSES `action: :self_license` → `{:error, :reserved_action}`. (b) **[SUPERSEDED by v4-H2b — see the v4 section]** the earlier text asserted "`kind_snapshots.ever_created` is cleared ONLY on delete" — that is UNGROUNDED. `KindSnapshot.delete/1` (`kind_snapshot.ex:147-148`, a full-row `Repo.delete_all` that drops the marker) is reachable from FOUR non-user-delete sites (`snapshot_store.ex:271`, `ezagent.snapshot.clear.ex:48`, `teardown.ex:78`→`retire_spawned` `agent.ex:297`, `kind_base_backfill.ex:316`). Instead of "a test/grep asserting cleared-only-on-delete," add an **empty-allowlist enumerator gate** over those four sites: each MUST be PROVEN to co-delete the principal's identity row (genuine delete — nothing to lazy-spawn from) OR reworked to preserve `ever_created` (delete `state_binary`, KEEP the marker row) — so a revoke-without-delete principal (standalone `revoke_all_to`) whose marker survives cannot lazy-spawn `:created` and re-mint a self-license under the bumped gen. Exploitable case = identity-row-outlives-marker; snapshot-only Kinds are safe. Fold into G-3 + Z-1.

### v3-H3 (was MF8) — EJECT "OR" clause leaves rejoin open.
**Hole:** EJECT = "revoke the join cap / write a durable per-`(M,S)` bar" — the "/" is an OR. Revoking the join cap ALONE does not close rejoin when tier-0 is also satisfiable by invite / standing owner-intent / a permissive join-policy (M re-issues an authenticated `:join`; tier-0 passes via the other source; tier-1 re-granted). Rejoin is closed ONLY by the durable fail-closed bar.
**Resolution [REFINED by v4-H3 — there is no single tier-0 gate]:** EJECT **MUST** write the durable per-`(M,S)` bar (mandatory, not an alternative), checked fail-closed at **EVERY tier-0 admission entry** — join authorization on `6f54f1f9e` is multi-entry: (1) dispatch `:join` cap check (step 5.5), (2) anon `public_view` open-join web path (`membership.ex:703` — explicitly NOT in `membership.ex`), (3) invite/magic-link admission (`anon_admission`, `magic_link_controller`), (4) tier-1 grant `MemberCap.grant_at_join` (`membership.ex:88`, guard `holds_member_cap_exact?` `member_cap.ex:36`) — proven by an **enumerator gate** over those four entry sites, OR all admission first funneled through ONE tier-0 `authorize` with the bar placed there. Revoking the join cap stays (removes the direct entitlement) but is necessary-not-sufficient; the bar is the airtight closure. M-10 test (ii) asserts the bar row exists after EJECT AND that **EACH enumerated entry** DENIES even when an invite/permissive-policy would otherwise admit. Update EJECT definition + M-10 (see v4-H3).

### v3-H4 (was MF5) — fence the cold user-login paths (magic-link / invite). **CORRECTED by v4-H4: `spawn_principal` is NOT the sole chokepoint.**
**Hole:** the "complete (verified 2026-07-20)" recredential table OMITS the **magic-link LOGIN** path (`entity/magic_link_token.ex` mint:40/consume:64-94 → `EzagentWeb.MagicLinkController.consume`:21 → `Ezagent.Entity.spawn_principal`:47) and `entity/invite_code.ex` (consume:93) — both authenticate/spawn a principal via a durable secret SEPARATE from `entity_tokens`, with no gen/fence check. (v3-H4's premise "D-5's fence was wired only to `Entity.Token.authenticate`" was ITSELF imprecise — MF7/D-5 already wire the fence to `authenticate` + `EntityCaps.load` + `Cap.authorize`; the real remaining gap is only the COLD-LOGIN entry, before the principal ever acts.) A gen-bumped-not-deleted principal could consume a pre-bump magic-link to re-authenticate.
**Resolution [CORRECTED by v4-H4 — the fence lives at the ACT-TIME gates, not a single spawn chokepoint]:** the fence's completeness boundary is `EntityCaps.load/1` + `Cap.authorize/3` — the ACT-TIME gates every principal (agent or user, live or cold) MUST pass to ACT, which is why they kill the cascade descendants kill-independently. **`spawn_principal/1` does NOT cover that:** on `6f54f1f9e` agents spawn via `Kind.spawn`/`SpawnRegistry.spawn` (`cc_agent/spawn.ex:259` `Kind.spawn(Agent,…)`, `agent_create.ex:485`), boot via `Kind.spawn(User,…)` (`application.ex:220/402`), lazy via `SpawnRegistry.spawn` (`invocation.ex:446`) — NONE route through `spawn_principal` — and `spawn_principal → ensure_spawned` (`entity.ex:83-89`) early-returns on a `KindRegistry` HIT (never fires on a live principal) and hardcodes `Kind.spawn(Ezagent.Entity.User,…)` (`entity.ex:~105`, a cold user-login helper). So anchoring the fence at `spawn_principal` would have RE-OPENED the descendant window. Instead, ADD `spawn_principal/1` as an **EXTRA early gate for the cold user-login paths that bypass `authenticate`** — magic-link (`magic_link_controller.ex:47`) + invite→registration (`registration.ex:143/:215`), both of which call it. **DROP the v3-H4 "single point / completeness boundary / grep gate NO-principal-live-except-`spawn_principal`" claims** — no such chokepoint exists. Per-credential gen-stamps (G-2 `entity_tokens.bound_generation`, G-6 agent-bridge token) remain as defense-in-depth. Full reframe + D-5's enforcement set (load + authorize = boundary; + authenticate PAT; + spawn_principal cold-login) is in the v4 section.

### Net
+0 PRs — all four fold into existing tasks (v3-H1→D-1, v3-H2→G-3+Z-1, v3-H3→M-10, v3-H4→D-5+Z-1). Spine unchanged. Ready for re-review as v3.

---

## v4 — round-3 review holes (RESOLVED)

Third adversarial review (2026-07-21, static/git vs `origin/main` `6f54f1f9e`) returned **NEEDS-REVISION** with 4 holes; architecture SOUND. Round-3's throughline: **three v3 fixes were written in a v-section but never propagated into the authoritative body lines kimi implements from** — a resolution the body still contradicts is not a fix. Each v4 hole is therefore folded into BOTH the v-section AND the body/earlier-section text it corrects (+0 PRs). All file:line grounded against `6f54f1f9e`.

### v4-H1 (was v3-H1) — `unique(child_uri, edge_kind)` propagated into the body.
**Hole:** v3-H1 correctly changed the derivation-edge constraint to `unique(child_uri, edge_kind)` (multi-provenance), but the AUTHORITATIVE body still said `unique(child_uri)` at the two sites kimi implements from — the MF6 `record_derivation_edge` spec and the D-1 task body. A child with divergent provenance (`spawned_by` A AND template-forked from T) would still collide on the single-column unique → a dropped edge → the child missing from `descendants(U)` → un-cascaded AND un-fenced (MF7 enrolls exactly the `descendants(U)` set) → fully live. This is the round-3 pattern: the fix lived only in v3-H1.
**Resolution:** both body occurrences now read `unique(child_uri, edge_kind)`, and `descendants/1` is made explicit — it UNIONS the reverse-walk frontier over ALL `edge_kind`s to fixpoint (stated in the MF6 spec AND the D-1 body, not only in v3-H1). Grep gate + fixpoint closure unchanged. **Edited:** MF6 `record_derivation_edge` bullet + `descendants/1` spec, D-1 files body + `descendants/1` spec. **Carrier:** D-1.

### v4-H2b (was v3-H2b) — enumerate the marker-drop paths, do not assert.
**Hole:** v3-H2 sub-gap (b)'s resolution ASSERTED "`kind_snapshots.ever_created` is cleared ONLY on delete" — ungrounded. Verified on `6f54f1f9e`: the marker is a column on `kind_snapshots` (`kind_snapshot.ex:39`), and `KindSnapshot.delete/1` (`kind_snapshot.ex:147-148`, a full-row `Repo.delete_all` that drops the `ever_created` marker together with the row) is reachable from FOUR non-user-delete sites: `snapshot_store.ex:271` (`SnapshotStore.delete`), `mix/tasks/ezagent.snapshot.clear.ex:48`, `teardown.ex:78`→`Domain.Agent.retire_spawned` (`agent.ex:297`, agent reap), and `kind_base_backfill.ex:316`. **Threat:** a revoke-WITHOUT-delete principal (a standalone `revoke_all_to`; G-1 writes no fence and does not delete) whose marker is dropped by one of these four → the next lazy-spawn boots `create_freshness == :created` → the G-3 mint fires and mints a FRESH self-license under the CURRENT (already-bumped) authority → **re-armed.** Reachable exactly where the `users` identity row OUTLIVES the marker row.
**Resolution:** replace the "add a test/grep" text with an **enumerator gate (empty-allowlist)** over the four `KindSnapshot.delete` reachability sites. Each site MUST be PROVEN to co-delete the principal's identity row (a genuine delete — nothing to lazy-spawn from) OR reworked to preserve `ever_created` (delete `state_binary`, KEEP the marker row). Honest scope note: a Kind persisted ONLY by snapshot (no identity row) is safe — there is nothing to lazy-spawn from; the ONLY exploitable case is **identity-row-outlives-marker.** Because this closes the restart-safety assumption, the un-re-mintable proof and the G-3 re-arm acceptance step that assert "restarted P boots `create_freshness == :existed`" are re-anchored: that holds **iff this enumerator gate passes.** **Edited:** v3-H2(b) resolution, MF1 proof (restarted-P clause), G-3 body (new marker-drop enumerator step + re-anchored re-arm step 5(ii)), Residual-Risk (a) pointer, Z-1 folds. **Carrier:** G-3 + Z-1.

### v4-H3 (was v3-H3) — pin the tier-0 fan-out (there is no single tier-0 chokepoint).
**Hole:** v3-H3 made the durable per-`(M,S)` bar mandatory and said it is "checked fail-closed at the tier-0 join-authorization BEFORE any join-policy/invite/standing-intent source" — presuming ONE tier-0 gate. But on `6f54f1f9e` join authorization is MULTI-ENTRY: (1) the dispatch-level `:join` cap check (step 5.5); (2) the anon `public_view` open-join web path — explicitly NOT in `membership.ex` (`membership.ex:703`: "public_view open-join is NOT handled here — that is the anon web path"); (3) invite/magic-link admission (`anon_admission`, `magic_link_controller`); (4) the tier-1 grant `MemberCap.grant_at_join` (`membership.ex:88`, guard `holds_member_cap_exact?` `member_cap.ex:36`). A bar placed at only ONE of these (v3-H3 only re-gated `grant_at_join`) leaves the other admission paths open to rejoin.
**Resolution:** enforce the durable per-`(M,S)` bar at EVERY tier-0 admission entry, proven by an **enumerator gate** whose empty-allowlist worklist is exactly the four entry sites above — OR first funnel ALL join admission through ONE tier-0 `authorize` and place the bar there (then the enumerator proves no path skips the funnel). Do NOT claim a single chokepoint that does not exist. M-10 test (ii) asserts the bar row exists after EJECT AND that EACH enumerated entry DENIES a barred M even when an invite / permissive join-policy would otherwise admit. **Edited:** v3-H3 resolution, EJECT definition (MF8), M-10 body (entry-site worklist + enumerator gate). **Carrier:** M-10 — the reconciliation-entitlement task that owns tier-0. (There is no dedicated M-8 body in this file: M-2…M-9 are delegated to the source membership plan, and M-8's backfill re-grant is already one of M-10's roster-driven paths, so the v4-H3 body edits land in M-10.)

### v4-H4 (was v3-H4) — reframe: `spawn_principal` is NOT the sole chokepoint; the fence lives at the act-time gates.
**Hole:** v3-H4 claimed `Ezagent.Entity.spawn_principal/1` (`entity/entity.ex:70`) is "the SINGLE point EVERY authentication/spawn path routes through," MOVED the D-5 fence anchor from `authenticate` to `spawn_principal`, and added a Z-1 grep gate "NO principal is made live except via `spawn_principal`." FALSE on `6f54f1f9e`: **agents** spawn via `Kind.spawn`/`SpawnRegistry.spawn` (`cc_agent/spawn.ex:259` `Kind.spawn(Agent,…)`, `agent_create.ex:485` `Kind.spawn(…)`), **boot** spawns users via `application.ex:220/402` `Kind.spawn(User,…)`, **lazy-spawn** via `invocation.ex:446` `SpawnRegistry.spawn` — NONE route through `spawn_principal`. Worse, `spawn_principal → ensure_spawned` (`entity.ex:83-89`) **early-returns on a `KindRegistry` lookup HIT** before doing any work, and its hydration path hardcodes `Kind.spawn(Ezagent.Entity.User,…)` (`entity.ex:~105`): it is a cold user-LOGIN helper (docstring: "Used by registration + magic-link login"), covering neither agents nor already-live principals. So a fence anchored ONLY at `spawn_principal` would NEVER fire on a live/busy agent — which is precisely the cascade-descendant, "processes live/busy, kill-independent" case D-5 exists to kill. Moving the anchor there would have RE-OPENED D-5's core guarantee.
**Resolution:** the revocation FENCE's completeness boundary is the **ACT-TIME multi-gate set** — `EntityCaps.load/1` + `Cap.authorize/3` — because those are the only gates EVERY principal (agent or user, live or cold) must pass to actually ACT, so they cover the cascade descendants kill-independently (the exact D-5 goal). `Entity.Token.authenticate/1` stays as the PAT-login gate (and itself routes through `spawn_principal` at `token.ex:108`). `spawn_principal/1` is ADDED as an EXTRA early gate for the cold user-login paths that bypass `authenticate` — magic-link (`magic_link_controller.ex:47`) and invite→registration (`registration.ex:143/:215`), both of which call `spawn_principal`. DROP the "sole chokepoint / completeness boundary / grep gate NO-principal-live-except-`spawn_principal`" claim — no such chokepoint exists. Internal-contradiction fix: MF7 already enforces the fence at load + authorize (+ authenticate); v3-H4's "wired only to `authenticate`" was itself false. MF7 and v4-H4 now agree: **fence = load + authorize (act-time completeness boundary) + `authenticate` (PAT login) + `spawn_principal` (cold user-login); NOT authenticate-only, NOT spawn_principal-only.** **Edited:** v3-H4 resolution, MF7 gate list, D-5 body + steps. **Carrier:** D-5.

### Net
+0 PRs — all four fold into existing tasks (v4-H1→D-1, v4-H2b→G-3+Z-1, v4-H3→M-10, v4-H4→D-5). Spine unchanged. Each fix now lands in BOTH the v4 section AND the authoritative body it corrects. Ready for re-review as v4.

---

## Phase overview & PR count

| Phase | PRs | Deliverable |
|---|---|---|
| **F — unify `authorize/3`** | F-1 … F-6 (6) | ONE signed-verify chokepoint hosting all predicates (sig + target-gen + principal-gen + membership + **explicit authenticated holder**); dependency-inverted holder-license resolver (MF2); migrate the 3 bare-matches bypasses + the read-plane cap gates onto it; **F-6 = authenticated-holder threading (MF3)**. Shared base for G/D/M. |
| **G — generation as revocation primitive** | G-1 … G-6 (6) | Cap-gated `revoke_all_to/1` (target-axis, wired to delete + URI-reuse; **revocation propagates via the atomic DB active-row flip, no stale-cache window — MF4**); auth-gen-check (token `bound_generation` + **agent-bridge token invalidate-on-bump — MF5**); cap-load principal-gen gate (**self-license, mint-only-on-`create_freshness==:created` — MF1**); URI-reuse acceptance; **G-6 = recredential-generation gate (MF5)**. |
| **D — delete_user collapse** | D-1 … D-5 (5) | **Durable append-only derivation-edge store + `record_derivation_edge` creation chokepoint + grep gate + `descendants/1` transitive closure, no depth cutoff (MF6)**; `delete_user` = bump-U + cascade-bump (+ clear stale self-license); honest-terminate + best-effort reap; completeness proof; **D-5 = durable pending-revocation fence enforced fail-closed at the act-time gates `load`+`authorize` (the completeness boundary) + `authenticate` (PAT) + `spawn_principal` (cold user-login) (MF7 / v4-H4)**. |
| **M — membership-cap-as-truth + supervisor** | M-1 … M-10 + S-1 … S-2 (12) | Membership predicate on `authorize/3`; drop roster truth; entity self-add cap-gated; convergence; grant-only join; **durable join cursor atomic-with-mount + seq-based replay (M-4, MF10)**; backfill→evict; members-not-authority gate; supervisor per-session member (S-2 gated on DECISION #5); **M-10 = reconciliation-entitlement: tier-1/tier-2 split, roster-is-not-entitlement (MF8)**. |
| **Gate** | Z-1 (1) | The unified enumerator gate: ONE source-scan proving every authority-use site routes through `authorize/3` (both axes + membership + explicit holder) + **the recredential-generation worklist (MF5)** + **the scope-tuple denial proof (MF9)** — the shared completeness proof for F/G/D/M. |

**Total: 30 PRs** (v1 was 26; +4 from the must-fix folds: F-6 holder-threading, G-6 recredential gate, D-5 durable fence, M-10 reconciliation-entitlement; D-1 is reshaped from "port #1469 walk" to "durable edge chokepoint + gate"). (The three source plans were 13 + ~9 + 11 = ~33 PRs; the collapse still removes the duplicated verify-primitive, ETS-cache, enumerator-gate, and tombstone-predicate work — one gate, one chokepoint, one primitive.)

**Sequencing (load-bearing):**
```
#1477 lands (precursor) ─► F-1 (verify_against_current fresh-read, NO process-dict shortcut + AuthorityCache read-through + authorize/3 facade w/ dependency-inverted holder gate) ─► F-2 (3 bare-matches bypasses) ─► F-6 (authenticated-holder threading)
  ─► F-3/F-4/F-5 (read-plane cap gates: session/socialware, pty/world/uploads, identity)   [parallel-ok]
  ─► G-1 (cap-gated revoke_all_to + regenesis re-gate; atomic DB active-row flip = revocation point, no stale cache)  ─► G-2 (token bound_generation + agent-bridge token, auth-gen-check)
     ─► G-3 (self-license mint-on-create + cap-load principal-gen gate)  ─► G-4 (URI-reuse=regenesis)  ─► G-5 (acceptance suite)  ─► G-6 (recredential-generation gate)
  ─► D-1 (durable derivation-edge store + creation chokepoint + grep gate + descendants/1)  ─► D-2 (delete_user = bump+cascade + clear self-license)  ─► D-3 (honest-terminate + reap)  ─► D-5 (durable pending-revocation fence, enforced at act-time load+authorize boundary + authenticate + cold-login spawn_principal — v4-H4)  ─► D-4 (completeness proof)
  ─► M-1 … M-9 (membership; M-1 composes with F-3; M-4 = durable join cursor)   S-1 rides M-1;  S-2 after DECISION #5  ─► M-10 (reconciliation-entitlement)
  ─► Z-1 (unified enumerator gate + recredential worklist + scope-tuple denial proof — lands LAST, enforces the rest)
```

> **Dependency note:** D-5 (fence) depends on D-1 (the fence must know whom to fence from the complete edge set). MF8's M-10 depends on M-1/M-2 (tier-1 membership cap as truth) + F-1 (the tier-2 mount consults `authorize/3`).

---

# PHASE F — Unify authorization onto ONE `authorize/3` chokepoint

**Why first:** the whole paradigm is "an old-gen cap (either axis) is denied wherever presented, and membership is a cap-check." That guarantee only holds if every authorization consumer runs the SAME verify. Today only the in-dispatch verifier does; the 3 bare-matches bypasses and the read-plane cap gates do not.

**Scope discipline (per the source plans + `feedback_replacement_task_gate_is_parity_audit`):** ~85 authz sites fan into 4 match-engines + 2 dispatch gates + 1 injection seam. Migrate **classes** (engines/domains), not 85 files by hand; the Phase Z enumerator is the completeness proof. Classify each site: **ACCESS to a target** (in-scope — must run `authorize/3`) vs **GRANT-side / admin-definition** (unification-only — mark exempt). Only ACCESS is required for the guarantee.

### Task F-1: The `verify_against_current/3` fresh-read primitive + ETS `AuthorityCache` + the `authorize/3` facade

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap/authority.ex` — add `verify_against_current(cap, presenter_uri, target_uri) :: boolean()` (near `verify_current/2` `:131`).
- Create: `apps/ezagent_core/lib/ezagent/cap/authority_cache.ex` — ETS memo of the IMMUTABLE `key_id → public_key` mapping (never stale — a `key_id` binds one public key forever), mirroring `DeliveryOutbox` (`delivery_outbox.ex:28-71`); `public_key/1` (read-through to the DB row on miss), `rehydrate/0`, `table/0`. **No mutable `uri → current authority` entry (v2/MF4) — the current key_id comes from the DB active row.**
- Modify: `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:32` (register the table) + a boot rehydrate mirroring `delivery_outbox/sweeper.ex:20`.
- Create: `apps/ezagent_core/lib/ezagent/cap/authorize.ex` — `Ezagent.Cap.authorize(holder_uri, candidate_caps, needed) :: {:ok, Capability.t()} | {:error, term()}`.
- Modify: `apps/ezagent_core/lib/ezagent/cap/verifier.ex` — `verify_cap/5` delegates its per-cap filter to the facade (do NOT fork a 5th engine).
- Test: `authority_verify_against_current_test.exs`, `authority_cache_test.exs`, `authorize_test.exs`

> **[v2/MF4] NO process-dict shortcut, and NO mutable "current" in ETS to go stale.** v1 said "use the process-dict authority when `current_target?(target)`." REMOVED — that reads the live process's cached (stale-on-bump) authority. `verify_against_current/3` reads the CURRENT `key_id` from the **DB active row** (`KindCapAuthority.active(target)`, authoritative, flipped atomically by `regenesis`), and `AuthorityCache` memoizes ONLY the IMMUTABLE `key_id → public_key` mapping (never stale — a `key_id` binds one public key forever). No stale-PRESENT window (see v2/MF4(b) — this is stronger than "invalidate inside the transaction," which leaves a commit→delete window for a present entry). `current_target?/1`/`verify_current/2` stay ONLY for in-process issuance + #1477 grant-idempotency, never for ACCESS/revocation.

> **[v2/MF2] Dependency-inverted holder-license gate — the principal gate ignores `candidate_caps`.** `authorize/3` resolves the holder license from its OWN source (`EntityCaps.load(holder)`), never from the `candidate_caps` argument. See the facade pseudocode in v2/MF2.

**Interfaces:**
- Produces: `Ezagent.Cap.Authority.verify_against_current(cap, presenter, target)` — reads the CURRENT `key_id` from the DB active row `KindCapAuthority.active(target)` (authoritative), fetches the immutable public key via `AuthorityCache.public_key(current_key_id)` (read-through to the DB row on miss), then `cap.key_id == current_key_id` + `:crypto.verify`. Returns `false` (fail-closed) when the target has no active row. **No process-dict fast path, no mutable-current ETS entry (MF4).** **This is the fresh-read revocation basis — NOT `valid_for_target?` (which reads the target's stale cached `state.authority`; see DECISION #2).**
- Produces: `AuthorityCache.public_key(key_id) :: {:ok, binary()} | :error` (immutable `key_id → public_key` memo — never stale), `rehydrate/0`, `table/0`. (A `uri → current_key_id` hot-path cache is a deferred optimization that MUST preserve MF4(b)'s invariant.)
- Produces: `Ezagent.Cap.authorize(holder, caps, needed)` — runs the **principal gate FIRST from an independent source** (`EntityCaps.load(holder)` must contain a current self-license, else `{:error, :holder_revoked}`; MF2 — `caps` CANNOT satisfy it), THEN filters `caps` to those where `verify_against_current(cap, holder, cap's target)` is true, then `Enum.find(&Capability.matches?(&1, needed))`. Later-phase predicate hooks run inside this one function: **principal-gen** (G-3, self-license precondition on the holder's independently-loaded set), **membership** (M-1). Returns `{:error, :no_matching_cap}` / `{:error, :holder_revoked}` — never a bare match. The `holder` is the **authenticated principal** (F-6/MF3), never inferred from `caps`.
- Consumes: `KindCapAuthority.active/1`, `Cap.Signing.signing_payload/1`, `EntityCaps.load/1` (holder gate).

- [ ] **Step 1: Failing test — `verify_against_current` denies an old-gen cap on a LIVE target (the case `valid_for_target?` misses).**
```elixir
test "cap signed under gen N is denied after a LIVE target bumps to N+1 (fresh active-row read)" do
  {target, kind_type} = spawn_target()                    # live process, authority cached at init
  cap = mint_signed_cap_for(target, target)               # key_id kind-g1
  assert Ezagent.Cap.Authority.verify_against_current(cap, target, target)
  {:ok, _} = Ezagent.Cap.Authority.regenesis(target, kind_type, admin_uri())  # DB active row → gen 2 (atomic flip)
  refute Ezagent.Cap.Authority.verify_against_current(cap, target, target)     # reads DB active row: old key_id ≠ current, no cache-invalidate needed
end
```
- [ ] **Step 2: Run → FAIL** (`verify_against_current/3` undefined).
- [ ] **Step 3: Implement** `AuthorityCache` (mirror `DeliveryOutbox`), `verify_against_current/3` (**read-through to the DB active row; NO `current_target?` process-dict fast path — MF4**; fail-closed), register the ETS table + boot rehydrate.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 4b (MF2): Failing test — the principal gate ignores inline candidates.** A revoked holder (no current self-license) presenting a still-valid `cap(→T)` **inline** is denied.
```elixir
test "authorize/3 denies a revoked holder even when it presents a valid cap inline" do
  {t, _} = spawn_target(); valid = mint_signed_cap_for(t, holder = revoked_principal())
  assert {:error, :holder_revoked} =
           Ezagent.Cap.authorize(holder, [valid], needed_map_for(t))   # candidates can't satisfy the principal gate
end
```
- [ ] **Step 5: Build the `authorize/3` facade** — principal gate FIRST from `EntityCaps.load(holder)` (MF2, independent of `candidate_caps`), then `verify_against_current` + `matches?`; route `Cap.Verifier.verify_cap/5`'s filter through it. Full `apps/ezagent_core` suite → green. (The self-license precondition itself lands in G-3; F-1 wires the seam so `caps` can never satisfy it.)
- [ ] **Step 5b (MF4): assert no process-dict read in the revocation path.** A drift/grep check: `verify_against_current/3`'s body does not call `Process.get({Authority, :current})`/`current_target?`. Fold into Z-1's presence tripwire.
- [ ] **Step 6: Commit.** `feat(cap): verify_against_current fresh-read (no process-dict shortcut) + AuthorityCache read-through + authorize/3 facade w/ dependency-inverted holder gate (unify F-1)`

### Task F-2 (LOAD-BEARING): Route the 3 bare-matches bypasses through `authorize/3`

This is the dormant-cap closure: a cap resident in a holder's `:identity` slice must die on bump at the slice/preflight/identity engines, not only in dispatch.

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind.ex:288-297` (`default_holds_cap?/2`)
- Modify: `apps/ezagent_core/lib/ezagent/capability/authorization.ex:24-29` (`authorizes?/2` / `authorizing_cap/2`)
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity.ex:303` (`caps_authorize?/2`)
- Test: `default_holds_cap_signed_test.exs`, `authorization_signed_test.exs`, `caps_authorize_signed_test.exs`

**Interfaces:** each consumes `Cap.authorize/3`. The presenter/holder is the slice-owner `entity_uri` (`default_holds_cap?`) / the caller (`authorizes?`, `caps_authorize?`); the target is `needed.instance`.

- [ ] **Step 1: Failing test (per engine) — a slice-held old-gen cap no longer authorizes after bump.**
```elixir
test "default_holds_cap? denies a slice-held cap whose target generation was bumped" do
  {target, kind_type} = spawn_target()
  holder = spawn_holder_with_sliced_cap(target: target)
  needed = needed_map_for(target)
  assert Ezagent.Kind.default_holds_cap?(holder, needed)
  {:ok, _} = Ezagent.Cap.Authority.regenesis(target, kind_type, admin_uri())
  refute Ezagent.Kind.default_holds_cap?(holder, needed)          # dormant slice cap dies
end
```
- [ ] **Step 2: Run → FAIL** (bare `matches?` still matches — no sig/gen check).
- [ ] **Step 3: Implement** — in each engine, add `Cap.authorize(holder, [held], needed)` (or `verify_against_current(held, holder, needed.instance)` inside the `Enum.any?`) **before** `matches?`. Keep `granted_by_entity?` as defense-in-depth + the narrow rescue.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Regression** — legitimate current-gen slice cap still authorizes (existing `kind`/`capability`/`identity` suites green).
- [ ] **Step 6: Commit.** `feat(cap): slice+preflight+identity engines verify sig/gen via authorize/3, not bare matches? (unify F-2)`

### Tasks F-3, F-4, F-5: Read-plane cap gates

Route the **cap-based** branch of each read gate through `authorize/3`. (The membership-based branch stays with `Membership.authorize/3`; F composes with the read-plane hardening #1471, MEMORY `reference_read_plane_authz_gap`, which already funnels internal reads through membership — F adds sig/gen to the CAP branch only.)

- **F-3 (session + socialware):** `membership_predicate.ex:55` (`authorize/3` — coordinate with M-1: one file, two changes), `session_reads.ex` (`authorized?/2`, `read_unfiltered_cap?/3`), `member_receive.ex:78`. Test: a socialware read authorized by a bumped-gen member cap is denied.
- **F-4 (pty + world + uploads):** `pty/access.ex:57` (`may_read?/2`), `world/kanban_data.ex` (`visible?/2`), `uploads_controller.ex` (`serve_authorized?/3`). Test: PTY `may_read?` denies after the agent's gen bumps.
- **F-5 (identity/notification/credential/registry):** `notification_subscriptions.ex:508`, `credential/resolver.ex:314`, `capability_registry.ex:449,526` — RULE each (route or reviewed-exempt).

Each: TDD (fail-before bumped-gen read allowed → pass-after denied), regression (current-gen read still allowed), commit `feat(<domain>): read gate verifies sig/gen via authorize/3 (unify F-N)`.

### Task F-6 (NEW — [v2/MF3]): Thread the AUTHENTICATED holder explicitly into every authorization API

**Why:** the principal gate (MF2) is only sound if `holder` is the authenticated principal — **NOT `ctx.caller`** when the caller is machinery (CapBAC §1: caller is frequently an HTTP handler / reconciler / effect, not a person; `capbac.md:23-24`). Every authorization API takes an explicit `holder_uri` carrying the value fixed at the auth boundary.

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap/verifier.ex:47` (`authorize/5` — accept + forward explicit holder), `kind.ex:288-297`, `capability/authorization.ex:24-29`, `apps/ezagent_domain_identity/lib/ezagent/identity.ex:303`, `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55` — each gains an explicit `holder_uri` parameter.
- Modify the auth-boundary sources that SUPPLY the holder: `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:105-116` (`authenticate/1` result is the authenticated principal), web session principal, CLI authenticated caller. The dispatch ctx gains an explicit authenticated-principal field distinct from `ctx.caller`.
- Test: `explicit_holder_threading_test.exs`

**Interfaces:**
- Consumes: `Entity.Token.authenticate/1 :: {:ok, principal_uri}` (the authenticated holder), `Cap.authorize/3`.
- Produces: every listed authz API signature carries `holder_uri :: URI.t()` = the authenticated principal. The plan states per entry point WHERE it comes from: **web** = the LiveView/controller session principal (not the controller module); **CLI** = the authenticated `--as`/token principal; **dispatch** = the ctx authenticated-principal field, which equals `ctx.caller` ONLY when caller IS the authenticated principal — never when caller is grant/reconcile machinery.

- [ ] **Step 1: Failing test — machinery caller cannot lend its identity as the holder.** A reconcile/effect path whose `ctx.caller` is machinery must pass the authenticated member as holder; the test asserts `authorize/3` uses the authenticated principal, not the caller module, so a revoked member is denied even when invoked by (non-revoked) machinery.
- [ ] **Step 2: Run → FAIL** (holder inferred from caller/caps).
- [ ] **Step 3: Implement** — add the explicit `holder_uri` param to each API; thread the authenticated principal from each auth boundary; forbid defaulting holder to `ctx.caller` when caller is machinery.
- [ ] **Step 4: Run → PASS.** — [ ] **Step 5: Regression** — legitimate self-caller paths (caller IS the authenticated principal) still authorize.
- [ ] **Step 6: Commit.** `feat(cap): thread authenticated holder explicitly through every authorize API — never inferred from caps/caller (F-6, MF3)`

---

# PHASE G — Generation as the revocation primitive

### Task G-1: Cap-gated `revoke_all_to/1` (target-axis) + re-gate `regenesis`

> **[v2/MF4] The revocation propagates because the CURRENT key_id lives in the DB active row, which `regenesis` flips atomically — no cache to invalidate.** `regenesis/3` is a `Repo.transaction` (`authority.ex:57-78`) that atomically `retire_active` + `insert_generation` (the `active` partial-unique constraint serializes it). `verify_against_current` reads the current key_id from that committed active row, so the bump is visible the instant the transaction commits — with NO mutable ETS "current" entry that could be stale-present in a commit→delete window (v2/MF4(b)). The ETS memo (`key_id → public_key`) is immutable and needs no invalidation.

**Files:**
- Modify: `cap/authority.ex:57-78` (`regenesis/3` gate) — authority moves from `same_uri?(presenter, admin_uri())` to a **cap-gate on the target** (symmetric with `K.grant` issuance), verified through `authorize/3`. Keep an internal arity for the trusted-internal delete path (D-2) that no longer self-checks admin. **The atomic `retire_active`+`insert_generation` in-transaction IS the revocation propagation point (MF4) — no separate cache-invalidate.**
- Create: operator entry `Ezagent.Cap.revoke_all_to/2` (+ `mix ezagent` verb).
- Test: `revoke_all_to_test.exs`, `regenesis_active_row_atomicity_test.exs`

**Interfaces:** `Ezagent.Cap.revoke_all_to(target_uri, ctx) :: {:ok, new_generation} | {:error, term()}` — authorizes the **authenticated holder** (F-6) for `cap.revoke_all` on `target_uri` via `authorize/3`, then `regenesis(target)` (atomic active-row flip) so the next `verify_against_current` reads the new active row (DECISION #2 — propagation is via the fresh DB read, NOT via `valid_for_target?`; no in-process swap, no mutable-cache window). Emit a `:cap_revoked_all` audit.

- [ ] **Step 1: Failing tests** — (h) unprivileged caller cannot bump (gen unchanged); manager-of-target can bump (gen→2). (source: epoch C-1 tests).
- [ ] **Step 2: Run → FAIL.** — [ ] **Step 3: Implement** cap-gate + `regenesis` (atomic active-row flip = the revocation point; **no separate cache-invalidate — MF4**) + audit; keep p13 green (no new `== admin_uri()` outside allowlist).
- [ ] **Step 4: Run → PASS** + `mix ezagent.check_invariants` (p13) green.
- [ ] **Step 5: Live-bump test (the load-bearing one)** — bump a RUNNING/busy target → its caps denied on the very next `authorize/3`, WITHOUT restarting the target. This FAILS if the check reads the cached `state.authority` (via `valid_for_target?`) and PASSES only via the fresh `verify_against_current` reading the DB active row. Assert it against a deliberately busy target process.
- [ ] **Step 5b (MF4): no stale-present window** — assert that the instant `regenesis` commits, `verify_against_current` denies the old-gen cap (it reads the committed DB active row; there is no mutable ETS "current" entry that could validate the old key_id). `regenesis_active_row_atomicity_test.exs`.
- [ ] **Step 6: Commit.** `feat(cap): cap-gated revoke_all_to (target-axis bump; revocation propagates via atomic DB active-row flip, no stale-cache window) (G-1, MF4)`

### Task G-2: Auth-gen-check — bind the PAT to the principal's generation

> **[v2/MF5] The `entity_tokens` `bound_generation` does NOT cover the agent-bridge file bearer.** `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/token_store.ex:32` mints an on-disk `EZAGENT_AGENT_TOKEN` (idempotent-no-rotate — the code comment notes "existing agent URIs keep their token until an explicit rotation flow is added"), a SEPARATE credential store from `entity_tokens`. A bumped agent would keep a live bridge bearer. G-2 gen-stamps the bridge token and **INVALIDATES it on bump** (a bumped agent's bearer is rejected); re-mint happens ONLY through the legitimate re-provision path (spawn/create), **NOT auto-remint on detecting a higher gen** — auto-remint would re-arm a just-revoked agent (same class as MF1). This is the "automatic agent PAT provisioning" path codex named in MF5.

**Files:**
- Create migration: `apps/ezagent_domain_identity/priv/repo/migrations/*_add_bound_generation_to_entity_tokens.exs` — add `bound_generation :: integer` (nullable for pre-existing rows; a null-gen token on a principal with a live authority is treated fail-closed per strict cutover — but per no-back-compat the DB is reseeded, so nullable is only a migration-shape concession).
- Modify: `token.ex` schema (`:40-56` add field), `mint/2` (`:72-95` stamp `bound_generation: current_generation(uri)`), `enabled_principal/1` (`:192-205` add the gen compare).
- **Modify (MF5): `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/token_store.ex:32` (`mint/1`) + the bridge-token consumption/validation point** — stamp the persisted bridge token with the agent's generation; **REJECT (invalidate) it when `current_generation(agent) != stamped`**. Re-mint ONLY on the legitimate re-provision (spawn/create) path — do NOT auto-remint on detecting a higher gen (that re-arms a revoked agent).
- Test: `token_generation_test.exs`, `agent_bridge_token_generation_test.exs`

**Interfaces:** `enabled_principal/1` returns `{:error, :disabled}` (coerced to `:invalid_credentials`) when `row.bound_generation != current_generation(principal)`. `current_generation(uri)` reads `KindCapAuthority.active(uri).generation` (fail-closed: no active row → deny). User principals ALSO keep the existing `disabled_at` gate (belt-and-braces during transition; the gen check subsumes it once delete uses bump). The agent-bridge bearer is validated the same way at its consumption point.

- [ ] **Step 1: Failing test** — a PAT minted at gen 1 no longer authenticates after `regenesis(principal)` to gen 2.
```elixir
test "a PAT for a principal whose generation was bumped no longer authenticates" do
  {p, kind_type} = spawn_principal()
  {plain, _} = Token.mint(p, label: "cli")
  assert {:ok, ^p} = Token.authenticate(plain)
  {:ok, _} = Ezagent.Cap.Authority.regenesis(p, kind_type, admin_uri())
  assert {:error, :invalid_credentials} = Token.authenticate(plain)   # stale-gen token
end
```
- [ ] **Step 2: Run → FAIL** (agent `else` branch returns `{:ok, principal}` unconditionally; no gen column).
- [ ] **Step 3: Implement** migration + schema field + mint stamp + `enabled_principal` compare (fail-closed on missing authority row).
- [ ] **Step 4: Run → PASS.** — [ ] **Step 5: Regression** — a fresh mint after a bump authenticates (new token carries the new gen); the token suite green.
- [ ] **Step 5b (MF5): agent-bridge token** — failing test: a bumped agent's on-disk `EZAGENT_AGENT_TOKEN` is REJECTED (gen mismatch) AND is NOT auto-re-minted while the agent is revoked (re-mint only via re-provision); implement gen-stamp + reject-on-bump in `token_store.ex:32`; PASS.
- [ ] **Step 6: Commit.** `feat(identity): bind PAT + agent-bridge bearer to principal generation; stale-gen credentials fail (principal-axis auth gate, G-2, MF5)`

### Task G-3: Cap-load principal-gen gate — the self-license (closes the live-process bypass)

**THE key new mechanism.** A live already-authenticated process does not re-authenticate; it sources caps via `EntityCaps.load(P)`. This gate disarms it.

> **[v2/MF1] Mint the self-license ONLY on genuine creation, with a dedicated recognizable action axis, and clear it on delete.** See v2/MF1 for the full artifact spec + un-re-mintable proof. Key points folded into G-3a/G-3b/D-2:
> - **Unique artifact:** `action: :self_license` (a new reserved action matched by `capability/match.ex`), `instance = grantee_uri = P`, signed by P's own authority. Uniqueness enforced by a mint-guard (fail if any `:self_license` cap already in P's durable store).
> - **Mint-only-on-create:** gate the mint on **`create_freshness == :created`** (`server.ex:157-165`, computed before the `ever_created` marker at `:167`) — NEVER on `:existed`/restore/activate/replay. Chosen seam = **1a (thread `create_freshness` into `Behavior.Identity.create/1`, `identity.ex:143-172`)**; do NOT also mint in init.
> - **Recognition (G-3b):** `verify_against_current(L, P, P)` AND `action_of(L) == :self_license`.
> - **Delete clears it (D-2):** `delete_user`/`revoke_all_to` remove the stale self-license from P's durable store.

**Files:**
- **G-3a (self-license mint, [v2/MF1] — mint-ONLY-on-`create_freshness==:created`, SEAM 1a):** Thread `create_freshness` into the create-path ctx (`apps/ezagent_core/lib/ezagent/kind/server.ex` create hook) and mint the self-license in `Ezagent.Behavior.Identity.create/1` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:143-172`) when ctx is `:created` — a cap `action: :self_license`, `instance = grantee_uri = P`, signed under P's just-opened authority, persisted into P's durable cap set. Mint-guard fail-closes if a `:self_license` cap already exists. Do NOT mint in `Kind.Server.init` (that path also runs on restore/`:existed`). Test: `self_license_mint_on_create_test.exs`.
- **G-3b (the load gate):** Modify `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:44-67` — `load/1` and `load_persisted/1` return `[]` unless the loaded set contains a self-license `L` with `action_of(L) == :self_license` AND **`Cap.Authority.verify_against_current(L, uri, uri)`** (fresh active-row read, F-1) — NOT `valid_for_target?` (which reads P's own stale cached authority and would never fire on a live P; DECISION #2). Applies to BOTH branches (slice AND user caps_json / snapshot) — this is where the store-split is unified (the self-license lives in whichever store holds P's caps). Test: `entity_caps_principal_gate_test.exs`.

**Interfaces:** `EntityCaps.load(P) :: [] | [caps...]` — `[]` iff no current-gen self-license (verified fresh). Consumes `Cap.Authority.verify_against_current/3` + `AuthorityCache`. Fail-closed (unreadable authority → `[]`), with the `DBConnection.OwnershipError` sandbox rescue.

- [ ] **Step 1: Failing test — a LIVE principal's cached caps become unusable on bump.**
```elixir
test "EntityCaps.load returns [] after the principal's generation is bumped, even while live" do
  {p, kind_type} = spawn_principal_with_caps()          # live process, self-license @ gen 1, caps in slice
  assert EntityCaps.load(p) != []
  {:ok, _} = Ezagent.Cap.Authority.regenesis(p, kind_type, admin_uri())   # bump P's own gen
  assert EntityCaps.load(p) == []                        # self-license stale → whole set inert
  assert EntityCaps.load_persisted(p) == []
end
```
- [ ] **Step 2: Run → FAIL** (load serves cached caps; no self-license gate).
- [ ] **Step 3: Implement G-3a** (mint self-license ONLY when `create_freshness == :created`, seam 1a) **then G-3b** (gate the load on `action_of(L)==:self_license` AND `verify_against_current(L, P, P)` — fresh active-row read).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Re-arm regression (THE residual test — [v2/MF1] un-re-mintable proof)** — bump P; restart/re-activate P's Kind; assert `load(P)` STAYS `[]`. The three-way proof, each an assertion: (i) a LIVE bumped P's `issue_current` mints a **stale gen-N** self-license (regenesis never swaps cached `state.authority`) → still `[]`; (ii) a RESTARTED P boots `create_freshness == :existed` — **conditional on the v4-H2b marker-preservation gate (no non-delete site dropped the `ever_created` marker)** → NO new self-license minted → stays `[]`; (iii) `activate/2` (`identity.ex:206-221`) re-unions `caps_json` re-adding only the SAME old-gen self-license, never a current-gen one → stays `[]`. Enumerate every cap-obtaining path (slice load, UserStore load, snapshot restore, activate re-read, `initial_caps_for_spawn`) in the test module docstring.
- [ ] **Step 5b (MF1): mint-guard test** — a second create attempt (or an ordinary init/activate) does NOT mint a second self-license; only `create_freshness == :created` mints exactly one.
- [ ] **Step 5c (v4-H2b): marker-preservation enumerator gate — restart-safety is a GATE, not an assertion.** Create `apps/ezagent_core/test/invariants/ever_created_marker_preservation_test.exs` (empty-allowlist, mirror `CapCheckOnlyAtChokepointTest`) over the FOUR sites that can reach `KindSnapshot.delete/1` (`kind_snapshot.ex:147-148`, full-row `delete_all` dropping the marker): `snapshot_store.ex:271` (`SnapshotStore.delete`), `mix/tasks/ezagent.snapshot.clear.ex:48`, `teardown.ex:78`→`Domain.Agent.retire_spawned` (`agent.ex:297`, agent reap), `kind_base_backfill.ex:316`. Each MUST either co-delete the principal's identity row (genuine delete — nothing to lazy-spawn from) OR be reworked to preserve `ever_created` (delete `state_binary`, KEEP the marker row). Failing test (fail-before): a revoke-**without**-delete principal (standalone `revoke_all_to`, no fence) whose `ever_created` is dropped by one of these four → its next lazy-spawn boots `create_freshness == :created` → G-3a re-mints a self-license under the CURRENT (bumped) authority → re-armed. Pass-after: the gate + fix make restarted-P provably stay `:existed` (this is the property G-3 step 5(ii) and the MF1 un-re-mintable proof depend on). Honest scope: snapshot-only Kinds (no identity row) are exempt — nothing to lazy-spawn from. Folds into Z-1.
- [ ] **Step 6: Commit.** `feat(cap): self-license (mint-only-on-create, action :self_license) gates EntityCaps.load + ever_created marker-preservation gate — principal-axis revocation, un-re-mintable by a bumped principal (G-3, MF1/v4-H2b)`

### Task G-4: URI-reuse = regenesis (DECISION #3) + the dormant/reuse acceptance suite

**Files:** `cap/authority.ex:201-202` (replace refuse with guarded regenesis-on-recreate); acceptance suite `unified_revocation_acceptance_test.exs`.

- [ ] **Steps:** (a) dormant cap (slice + inline `ctx.caps`) denied after bump; (b) delete at X → recreate at X → old-gen caps to X denied, new target's caps authorize (**and the recreate mints a NEW current-gen self-license — MF1 composition with DECISION #3**); (c1/c2) fail-closed (gone / unreadable authority → deny); (d) single-holder `Capability.revoke/2` still denies one holder with gen unchanged **(this is the input to MF8's re-arm test in M-10 — gen is UNCHANGED, so self-license/G-3 does NOT cover the roster-driven re-grant)**; (e) `:any` admin genesis + unrelated targets unaffected by a bump; (f) **[v2/MF9] an unsigned scope-tuple cap (`{:within_session, _}`) is DENIED at ACCESS** via `authorize/3`/`verify_against_current` (no `key_id`/signature) and is stripped from durable slices by `verified/2` — permitted only as a grant-authorization bound. Commit `feat(cap): URI-reuse=regenesis + unified revocation acceptance suite incl. scope-tuple access-denial (G-4/G-5, MF9)`.

### Task G-5: (folded into G-4 acceptance) — see acceptance matrix.

### Task G-6 (NEW — [v2/MF5]): Recredential-generation gate — every mint/issue path reads current generation

**Why:** MF5 requires that NO post-bump path re-arms a bumped principal. G-2 gated the two auth credentials (`entity_tokens` + agent-bridge); G-6 gates the remaining mint/issue + self-target-construction surfaces and installs the shared enumerator worklist (folds into Z-1).

**Files (the enumerated worklist — see the v2/MF5 table for file:line):**
- Modify: `apps/ezagent_core/lib/ezagent/cap.ex:99-104` (self-issue chokepoint) — the `current_target?(instance)` self-target gate ALSO checks the target's current generation (a bumped principal cannot construct a fresh self-target artifact).
- Modify: `capability.ex:249-265` (`admin_genesis_cap/0`) + the session-join grants (`member_cap.ex:31`, `membership.ex:713,1245`, `grant_first_join_owner_cap`) — routed under MF8's entitlement rule (M-10) and the current-generation self-issue gate.
- Create gate: `apps/ezagent_core/test/invariants/recredential_generation_test.exs` — enumerate every mint/issue site (the v2/MF5 table) and assert each reads the principal's current generation before minting/issuing; empty-allowlist to produce the worklist (mirror `CapCheckOnlyAtChokepointTest`).
- Test: `self_issue_generation_test.exs`

- [ ] **Step 1: Failing test** — a bumped principal's self-issue at `cap.ex:99-104` still constructs a self-target artifact (no gen check).
- [ ] **Step 2: Run → FAIL.** — [ ] **Step 3: Implement** the current-generation check at the self-issue chokepoint + the enumerator gate; run empty-allowlist to enumerate the full mint/issue worklist.
- [ ] **Step 4: Run → PASS** + `mix ezagent.check_invariants` green.
- [ ] **Step 5: Regression** — legitimate current-gen self-issue + admin genesis still succeed.
- [ ] **Step 6: Commit.** `feat(cap): recredential-generation gate — every mint/issue/self-target path reads current generation; enumerator worklist (G-6, MF5)`

---

# PHASE D — `delete_user` collapse

### The transitivity change (load-bearing — why the cascade is now correctness-critical)

#1469's `tombstoned_principal?/1` was **transitive**: a derived agent went inert the instant U's marker committed, *even if the cascade never reached it*, because the predicate walked UP to the owner. **The generation primitive has NO walk** — agent A is inert only if A's OWN generation was bumped; bumping U does nothing to A's authority. Consequences:
- The owned/derivation **enumerator becomes THE correctness guarantee**, not best-effort cleanup — a missed agent is fully live and capable.
- We **forfeit #1469's lost-linkage backstop** (an agent whose creator-link is gone) — no walk saves it; enumeration completeness is the only guarantee. **[v2/MF6] closes this:** the completeness comes from the DURABLE APPEND-ONLY derivation-edge set written at a creation chokepoint (D-1) — an edge cannot be "lost" because it is append-only and every creation is grep-gated to write one. The old mutable single-parent `AgentLineage` (which `forget/1` could delete) is NOT the source.
- **[v2/MF7] closes the mid-cascade window:** a durable pending-revocation fence (D-5) fail-closes every descendant BEFORE any bump commits, so there is no window where a descendant is live because its bump hasn't landed.
- **Rejected alternative:** a transitive `principal_revoked?/1` with a generation leaf — that is the tombstone with extra steps and re-introduces the depth-100 hot-path walk. Allen chose enumerate-and-bump over the complete edge set.

### Task D-1 (RESHAPED — [v2/MF6]): Durable append-only derivation-edge store + creation chokepoint + grep gate + `descendants/1`

> **[v2/MF6] Completeness is a CREATION CHOKEPOINT + grep gate, not a walk or an index.** v1 planned to "port the #1469 owned/lineage query" — but on main there is NO complete provenance: `AgentLineage` is durable-but-MUTABLE, single-parent, un-indexed, with only a depth-100 UPWARD walk (`agent_lineage.ex:141-157`); `CreationInventory` is append-only but written at ONE site (`template_spawn.ex:798-812`), records one root per row, and has no owner-indexed query. An index on a store that creation sites bypass proves nothing. Mirror `grant_dispatch_chokepoint_test.exs`: one append-only writer every principal-creation routes through + a grep gate that fails CI on any bypass. THIS is the enumerator's provably-complete source.

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/provenance/derivation_edges.ex` + migration — durable append-only `derivation_edges` table (`child_uri, parent_uri, edge_kind, attempt_id, inserted_at`; unique `(child_uri, edge_kind)` — **[v4-H1] NOT `(child_uri)`**: a child may carry multiple provenance edges of different kinds, and a single-column unique would silently drop a divergent-provenance edge → that child missing from `descendants(U)` → un-cascaded AND un-fenced; **index on `parent_uri`**; NO update/delete). Writer `record_derivation_edge(child_uri, parent_uri, edge_kind, attempt_id)`.
- Create: `descendants(root_uri) :: [URI.t()]` — transitive closure over `derivation_edges` (recursive CTE / iterative frontier) that **[v4-H1] UNIONS the reverse-walk frontier over ALL `edge_kind`s** at each step, **NO depth-100 cutoff — runs to fixpoint.**
- Modify (route through the chokepoint): every principal-creation site — user create (`users.ex` `do_create`), agent create (`agent_create.ex`), agent spawn (`template_spawn.ex:798-812`, replacing the CreationInventory-only write), session materialize (`session_creator/materializer.ex`), template fork (`agent_template.ex fork/3`).
- Create gate: `apps/ezagent_core/test/invariants/derivation_edge_chokepoint_test.exs` — grep gate: fails CI if any principal is created outside `record_derivation_edge` (literal + variable). Plus empty-allowlist `descendants/1` completeness scan.
- Test: `derivation_edges_test.exs`

> **DECISION FOR ALLEN #A (store):** new dedicated `derivation_edges` table (RECOMMENDED) vs extend `CreationInventory`. **DECISION FOR ALLEN #B ("owned" scope):** which edge KINDS (creator / `spawned_by` / workspace-ownership / `parent_template_uri`) trigger a `delete_user` cascade — all are RECORDED as edges; which ones the cascade closes over is the product call (does deleting a user delete forked-template descendants?). See v2/MF6.

- [ ] **Step 1: Failing test** — a spawned agent has NO queryable owner edge; `descendants(U)` misses it.
- [ ] **Step 2: Run → FAIL.** — [ ] **Step 3: Implement** the append-only edge table + `record_derivation_edge` + `descendants/1` (fixpoint closure) + route every creation site through the chokepoint.
- [ ] **Step 4: Run → PASS** (owned agent found; independent agent excluded; grandchild + great-grandchild found via closure, proving no depth cutoff).
- [ ] **Step 5: Grep gate** — `derivation_edge_chokepoint_test.exs` fails on a creation site that bypasses the writer; run empty-allowlist to enumerate the full worklist.
- [ ] **Step 6: Commit.** `feat(provenance): durable append-only derivation-edge store + creation chokepoint + grep gate + descendants/1 (no depth cutoff) (D-1, MF6)`.

### Task D-2: `delete_user` = regenesis(U) + cascade regenesis (the collapse)

**Files:** `apps/ezagent_domain_identity/lib/ezagent/users.ex:209` (`delete/1`) — before `Lifecycle.destroy` + `Repo.delete`, run: (0) **[v2/MF7] enroll U + `descendants(U)` in the durable revocation fence (D-5) FIRST** (fail-closes them before any bump), (1) `regenesis(U)` via the trusted-internal bump (target-axis caps-to-U + principal-axis U inert) **and clear U's stale self-license from its durable store (MF1)**, (2) `descendants(U) |> Enum.each(&regenesis + clear-self-license/1)` (each derived agent's own A+B; `descendants/1` from D-1's complete edge set — NOT `owned_lineage`/the mutable walk), (3) clear each fence row after its bump commits. Test: `delete_user_generation_test.exs`.

**How the source plans collapse here:**
- **delete_user plan PR-1 (cap-load tombstone gate)** → **G-3** (self-license gate on `EntityCaps.load`), generation-keyed instead of tombstone-keyed.
- **PR-2 (authenticate tombstone gate)** → **G-2** (token `bound_generation`), generation-keyed.
- **PR-6 (authz-decision holder-check for inline caps)** → **F-1/F-2** (the `authorize/3` holder is explicit; the principal-gen predicate runs on the holder's loaded set; inline `ctx.caps` that skip `EntityCaps.load` are covered because the self-license precondition is checked on the holder at the facade). **Residual: confirm inline-cap path applies the self-license precondition** (see Residual Risk).
- **PR-5 (spawn/commit fence)** → the spawn/create fence re-checks `current_generation` via the fresh active-row read (a revoked principal's gen is bumped; its self-license fails `verify_against_current` at activate → G-3b's re-arm test covers refuse-rehydrate). The EtsOwner-restart-durability concern folds into the fresh DB/ETS active-row read being durable, not an in-memory registry.
- **Tombstone table + `tombstoned_principal?`** → **DELETED** (generation is the truth).

- [ ] **Steps:** TDD — delete U → U's PAT fails authenticate (G-2), U's `EntityCaps.load` empty (G-3), every owned agent's caps denied + `load` empty EVEN IF its process is live/busy (cascade regenesis, kill-independent); an independent non-owned agent still authenticates. Commit `feat(identity): delete_user = regenesis(U) + cascade regenesis owned agents (tombstone dissolved) (D-2)`.

### Task D-3: Honest-terminate + best-effort reap (atomicity boundary preserved)

Keep the delete_user plan's **redrawn atomicity boundary** — but the boundary is now the **durable regenesis commit**, not a tombstone-marker commit:

| Sub-operation | On failure |
|---|---|
| **Durable regenesis commit** (bump U + cascade bumps) | `delete_user` returns **retryable non-success** — if the bump is not durable, the principal could still act. THE atomicity boundary. |
| **Process kill / teardown / snapshot delete** | **best-effort cleanup** — the busy-timeout agent is already INERT via its bumped generation (its `load` is `[]`, its PAT stale); enqueue a reap-retry; `delete_user` still `{:ok, _}`. |

**Files:** `kind.ex` (honest `terminate/1` + `terminate!/1`), `lifecycle.ex` (honest `destroy/2` + `destroy!/2`), `offboarding`→`reap_queue.ex` (best-effort retry). Same shape as the delete_user plan PR-3/PR-4 — reused verbatim, with "tombstoned" replaced by "generation-bumped". Test: `delete_user_busy_timeout_test.exs` (the headline: busy agent, terminate times out, bumps committed → `delete_user` `:ok` AND agent cannot authenticate/dispatch/load-caps AND queued for reap).

- [ ] **Steps:** port PR-3/PR-4 TDD, generation-keyed. Commit `feat(offboarding): atomicity boundary = durable regenesis commit; teardown best-effort (D-3)`.

### Task D-5 (NEW — [v2/MF7]): Durable pending-revocation fence — no live-descendant window

> **[v2/MF7] There must be NO window where a descendant is live because its bump hasn't committed.** The cascade over an unbounded lineage cannot be one atomic transaction (huge/long-held; a mid-cascade crash rolls back ALL bumps). Instead: a durable fence enrolls U + every descendant BEFORE any bump, and the fence DENIES them at the same three authority-use gates as generation, fail-closed — so a descendant is inert the instant the fence is written. **DECISION FOR ALLEN: fence (RECOMMENDED) vs one atomic cascade transaction.** Depends on D-1 (needs `descendants/1` to know whom to fence).

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/offboarding/revocation_fence.ex` + migration — durable `revocation_fence` table (`principal_uri`, `enrolled_at`, `cleared_at`). `enroll(uris)`, `fenced?(uri)`, `clear(uri)`.
- Modify (enforce the fence, fail-closed, at the authority-use gates — it rides them, not a parallel mechanism): the **ACT-TIME completeness boundary** `EntityCaps.load/1` (`entity_caps.ex:44-52`) + `Cap.authorize/3` (F-1) — the gates EVERY principal (agent or user, live or cold) must pass to ACT, so they kill cascade descendants kill-independently (**[v4-H4] agents bypass `spawn_principal` via `Kind.spawn`/`SpawnRegistry.spawn`, so the fence CANNOT rely on it for descendants**); plus `Entity.Token.authenticate/1` (`token.ex:105-116`, PAT login) and **`Ezagent.Entity.spawn_principal/1` (`entity.ex:70`, the EXTRA early gate for cold user-login — magic-link `magic_link_controller.ex:47` + invite→registration `registration.ex:143/:215` — which bypass `authenticate`)**. Each DENIES when `RevocationFence.fenced?(principal)`. NOTE: `spawn_principal` is NOT a sole chokepoint (it early-returns on a live registry HIT and does not cover agents); it is cold-login coverage only.
- Modify: `users.ex` `delete/1` — enroll `[U | descendants(U)]` in the fence FIRST, then bump each, then `clear/1` per-principal after its bump commits.
- Test: `revocation_fence_test.exs`

- [ ] **Step 1: Failing test — a descendant is live in the window between enroll and its own bump.** Simulate a slow cascade: enroll U + descendants, bump U, and BEFORE the descendant's bump commits, assert the descendant already cannot authenticate/load/authorize (fence denies).
- [ ] **Step 2: Run → FAIL** (no fence — descendant live until its bump lands).
- [ ] **Step 3: Implement** the durable fence + enforcement at the act-time gates (`EntityCaps.load` + `Cap.authorize`, the completeness boundary) + `Entity.Token.authenticate` (PAT) + the cold-login `spawn_principal` gate (**[v4-H4]**) + the enroll-before-bump / clear-after-commit ordering in `delete/1`.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Crash-recovery test** — a cascade interrupted mid-way leaves the fence rows in place (durable) → descendants STAY denied on restart until a resumed worklist bumps + clears them (no live window survives a crash).
- [ ] **Step 6: Commit.** `feat(offboarding): durable pending-revocation fence — descendants fail-closed at authenticate/load/authorize before their bump commits (D-5, MF7)`

### Task D-4: `delete_user` completeness proof

**Files:** `delete_user_completeness_test.exs` — the runtime acceptance invariants from the delete_user plan PR-8, generation-keyed: (1) derived agent revoked regardless of liveness; (2) grandchild + great-grandchild derivation revoked (via `descendants/1` closure, NOT a walk, NO depth cutoff — proves the enumerator reached it); (3) independent agent unaffected; (4) respawn/re-credential of a bumped principal refused; (5) busy terminate-timeout agent revoked + `delete_user` `:ok`; (6) idempotent cascade converges; (7) **[v2/MF7] no live-descendant window (fence denies before each bump commits, survives a mid-cascade crash)**. Commit `test(offboarding): delete_user generation-revocation completeness proof + fence-window (D-4)`.

---

# PHASE M — Membership-cap-as-truth + supervisor

The #166 plan lands almost unchanged — its "membership check RIDES the unified `authorize/3`" is now CONCRETE (F-1 exists). Ordering (ADDITIVE-FIRST, load-bearing):
```
M-1 (read plane keys on cap via authorize/3)  → M-2 (add_self writer, additive)
  → M-3 (entity convergence)  → M-4 (DURABLE join cursor atomic-with-mount + seq-based replay — MF10)
  → M-5 (CUTOVER: handle_join grant-only)  → M-6 (:join return = status)
  → M-7 (funnel: route_provisioner/approve/merge)  → M-8 (backfill → reconcile UNION→EVICT)
  → M-9 (members-not-authority gate)  → M-10 (reconciliation-entitlement: tier-1/tier-2, roster≠entitlement — MF8)
S-1 (read-plane lock + read_unfiltered-as-modifier doc) rides M-1
S-2 (supervisor = per-session member) — GATED on DECISION #5
```

**M-1 change vs the source #166 plan:** `membership_predicate.ex:55` `authorize/3` becomes `owner?(chat, holder) OR (Cap.authorize(holder, load(holder), membership_needed(S)) matches)` — the held-cap check routes through F-1's facade with the **authenticated holder** (F-6), so membership inherits target-gen + principal-gen by construction (a revoked member OR a revoked-principal member is denied). Drop the `member?` roster conjunct. **File collision: M-1 and F-3 both edit `membership_predicate.ex:55` + `member_receive.ex:78` — land as one coordinated change (conjunct-drop + authorize/3 routing compose).**

**M-4 change [v2/MF10] — durable join cursor atomic-with-mount + seq-based replay.** The v1 "readiness barrier + replay cursor" is made concrete against the verified window: `do_join/5` grants via an `:async` cast (`membership.ex:88`) and mounts via a DEFERRED `{:set, :members}` effect (`membership.ex:461`); `last_seen` is set only on disconnect and DELETED at join (`membership.ex:426-428`); `replay_messages_since` returns `:ok` for a nil cursor (`delivery.ex:382-387`) — so the first message before the mount is lost. **Fix:** establish the join cursor as part of the SAME committed effect batch as `{:set, :members}` (not the async grant, which can be lost) — in `do_join_apply/5` SET the member's cursor to the join point instead of deleting it, and replay from it. **Prefer a monotonic sequence over wall-clock `DateTime`** (define inclusive/exclusive if timestamps are retained) to avoid same-instant first-message loss. Test: first message published between grant and mount is replayed to the just-joined member (nil-cursor window closed).

**M-2 … M-9, S-1, S-2:** implement per `2026-07-20-membership-cap-as-truth-implementation.md` Tasks M-2…M-9 / S-1 / S-2 (all file:line and TDD steps there are current-main-verified; reuse them), with M-4 amended per MF10 above. S-2's code is GATED on DECISION #5 (Option 1 recommended: per-session reviewer-membership; content verbs require membership).

### Task M-10 (NEW — [v2/MF8]): Reconciliation must require CURRENT entitlement, not stale roster/navigation

> **[v2/MF8] CORRECTED — the load-bearing case is single-holder revoke with generation UNCHANGED (NOT the gen-bump case).** After G-4 step d (`Capability.revoke/2` de-authorizes ONE holder, no bump): M's self-license is still current, `load(M)` still works, only M's one membership cap was revoked — so **self-license/generation does NOT close this.** A roster/navigation-driven mount re-grants M a fresh VALID cap because its idempotency guard tests "M **lacks** the cap," not "M is **currently entitled**": `MemberCap.grant_at_join/2` guard `holds_member_cap_exact?/3` (`member_cap.ex:36`), `grant_session_caps`/`already_authorized?/5` (`membership.ex:1341`, `:1328-1371`). The stale `:members` roster is what keeps M's client able to trigger these mounts. **Rule: roster presence is NOT entitlement — the tier-1 membership cap is the authoritative entitlement (no new store; this IS cap-as-truth).**

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:31-83` (`grant_at_join/2`) — the **tier-1** membership `:receive` cap is granted ONLY on an authenticated `:join` that PASSES the **tier-0 join-authorization** (`authorize(M, load(M), join_needed(S))`) or an owner grant; NEVER from a roster iteration/reconcile/backfill. (Public sessions keep their anon `public_view` tier-0.)
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:88` (the join path — entry #4) — gate `grant_at_join` behind the tier-0 join-entitlement check AND the per-`(M,S)` bar. This is only ONE of the four tier-0 entries (see the bar-enumerator bullet below).
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1244-1282,1328-1371` (`mount_participation_caps`/`grant_session_caps`) — **tier-2** mounts gate on M CURRENTLY holding tier-1 via `Cap.authorize(M, load(M), tier1_needed)` (F-1), NOT roster presence.
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/member_backfill.ex:59` and `reconcile.ex:52-78` — no roster-driven re-grant of tier-1; `reconcile_after_load` already only heals the projection → with tier-1 as truth it EVICTS a revoked M.
- **[v4-H3] Enforce the per-`(M,S)` bar at EVERY tier-0 admission entry (there is no single tier-0 chokepoint on `6f54f1f9e`).** The four entries — the worklist an enumerator gate runs empty-allowlist against: (1) the **dispatch `:join` cap check (step 5.5)**; (2) the **anon `public_view` open-join web path** — explicitly NOT in `membership.ex` (`membership.ex:703`: "public_view open-join is NOT handled here — that is the anon web path"); (3) **invite/magic-link admission** (`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_admission.ex`, `magic_link_controller.ex`); (4) **tier-1 grant `MemberCap.grant_at_join`** (`membership.ex:88`, guard `holds_member_cap_exact?` `member_cap.ex:36`). Each must consult the bar fail-closed BEFORE admitting — OR first funnel all four through ONE tier-0 `authorize` and place the bar there (the gate then proves no path skips the funnel).
- Create gate: `apps/ezagent_domain_session/test/invariants/tier0_bar_enforced_test.exs` — empty-allowlist enumerator (mirror `CapCheckOnlyAtChokepointTest`) asserting no join-admission entry admits a barred `(M,S)` without consulting the bar; run empty-allowlist to produce the full entry worklist.
- Modify (EJECT — per the DECISION): the membership-revoke used by `delete_user`/offboarding revokes M's join cap **AND writes a durable per-`(M,S)` bar** (**[v3-H3] mandatory, not an alternative**), so a rejoin is denied at **every tier-0 admission entry** (**[v4-H3]** per the four-entry worklist above). A voluntary `:leave` = DROP (tier-0 intact).
- Test: `reconciliation_entitlement_test.exs`, `tier0_bar_enforced_test.exs`

**Interfaces:** every re-grant/mount path is classified: **roster-driven** (owner-side mount iterating `:members`, reconcile/backfill) → must consult tier-1 possession via `authorize/3`; **authenticated M action** → may grant tier-1 ONLY if tier-0 passes.

- [ ] **Step 1a: Failing test (roster vector)** — revoke M's membership cap via `Capability.revoke/2` (gen UNCHANGED, self-license still valid) → stale roster still lists M → M re-navigates → assert the tier-2 mount DENIES and NO fresh tier-1 is minted (M stays out).
- [ ] **Step 1b: Failing test (rejoin vector — the sharper one)** — EJECT M (revoke membership + **write the durable per-`(M,S)` bar**) → M attempts rejoin via EACH tier-0 admission entry (dispatch `:join`, anon `public_view` web path, invite/magic-link admission, `grant_at_join`) → assert the bar row exists AND EACH entry DENIES + NO tier-1 re-granted, **even when an invite / permissive join-policy would otherwise admit** (revoke-then-rejoin is NOT a re-arm). **[v4-H3] no single entry may be left un-gated.**
- [ ] **Step 2: Run → FAIL** (roster-driven mount re-grants; and/or rejoin re-grants tier-1 because tier-0 was left intact).
- [ ] **Step 3: Implement** the tier-0/tier-1/tier-2 split: tier-0 gates the join grant; tier-1 only from an authenticated join passing tier-0; tier-2 gated on current tier-1 possession; **EJECT writes the durable per-`(M,S)` bar enforced fail-closed at EVERY tier-0 admission entry (v4-H3 four-entry worklist) + the `tier0_bar_enforced_test.exs` enumerator gate**; remove roster-driven tier-1 re-grants.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Regression** — a legitimate current member (tier-1 held, never revoked) re-navigating still gets tier-2 mounted; a fresh authenticated join passing tier-0 still grants tier-1; a DROP-then-rejoin on a permissive session still succeeds (documents the DECISION).
- [ ] **Step 6: Commit.** `feat(session): tier-0/1/2 entitlement split — roster≠entitlement + eject removes join-authorization; closes single-holder-revoke roster AND rejoin re-arm (M-10, MF8)`

---

## #1477 COORDINATION (zyli — "reconcile stale presenter capabilities", OPEN)

**What #1477 does (verified against its diff):**
1. Promotes `Cap.Verifier.verified_artifact?` (private) → **`valid_artifact?/2` (public)** = `Authority.verify_current` (sig + gen vs the process-current authority).
2. Adds **`Cap.valid_for_target?/2`** — resolves the artifact's target Kind and verifies under *its* CURRENT authority (in-proc fast path when `current_target?`, else `GenServer.call {:ezagent_verify_cap_artifact,…}` to the live target). Handler added in `kind/server.ex`.
3. Adds `World.PresenterCaps` — World dispatches use **current Identity artifacts**, not the stale LiveView mount snapshot.
4. Fixes the Session-grant idempotency `matches?` bypass: `already_authorized?/…` now requires `identity_key ==` AND `valid_for_target?` (one of the exact bare-matches bypasses this program targets).
5. Adds a drift gate forbidding direct `current_caps` dispatch reads.

**Relationship — COMPOSES (freshness of the loaded SET), does NOT subsume the target-axis REVOCATION check.** #1477's `valid_for_target?` verifies against the target's *cached* `state.authority`, which `regenesis` does not swap on a live process — so it cannot carry revocation propagation (DECISION #2, verified against the diff). The two programs solve orthogonal problems:
- **#1477 = which caps are in-hand, and are they the target's current artifacts** (load current Identity artifacts, not a stale mount snapshot; grant-idempotency skips reissue only for an exact valid artifact). Its `valid_for_target?` / `already_authorized?` are the correct semantic for *presenter-set freshness* — "current as the target itself knows it."
- **F/G/M = is each in-hand cap still valid under the target's CURRENT generation (revocation), and is the holder a revoked principal.** This needs a fresh active-row read (`verify_against_current/3`), NOT the cached authority.
- They compose cleanly: #1477 ensures you LOAD the current artifacts; F/G/M ensure even a current artifact is DENIED if its target-gen was bumped or the holder is a revoked principal. `PresenterCaps` is the freshness precondition `authorize/3` assumes (fresh loaded set), which `EntityCaps.load` + G-3's self-license gate provide.

**Merge order + collision:** **land #1477 FIRST** (precursor/freshness). It promotes `verified_artifact?` → public `valid_artifact?` and edits `cap.ex`, `cap/verifier.ex`, `kind/server.ex`, and **`session/membership.ex`** (idempotency) — F-1/F-2 and M-5/M-7 touch the same. Rebase F/G/M on #1477. Collision points: `verifier.ex` (F-1 wraps the promoted `valid_artifact?` and adds `verify_against_current`; keep both) and `membership.ex` (#1477's `already_authorized?` idempotency vs M-5's join-cutover / M-7's funnel — compose, don't revert #1477's `identity_key ==` + valid check). **Flag for codex:** (i) confirm F-1's facade preserves #1477's drift gate (no direct `current_caps` dispatch read); (ii) confirm #1477's `already_authorized?` (grant idempotency, cached-current) correctly stays on `valid_for_target?` while the ACCESS/revocation path moves to `verify_against_current` — the two must not be conflated.

---

## Acceptance matrix

| Acceptance | Assertion | Task |
|---|---|---|
| Dormant/old-gen cap rejected EVERYWHERE (incl ex-bypass sites) | mint, never use, bump target, present at slice/preflight/identity/read-plane → DENY | F-2..F-5, G-4, Z-1 |
| Delete an object → caps-to-it instantly dead | `regenesis(obj)` atomic active-row flip → every `cap(→obj)` denied on next `authorize/3` (live via fresh `verify_against_current` reading the DB row, no restart, no stale-cache window) | G-1 |
| `delete_user` → U + owned agents inert even if processes live/busy | PAT stale (G-2) + `load`=[] (G-3) + cascade bump (D-2), kill-independent | D-2, D-3, D-4 |
| URI-reuse-after-delete does NOT resurrect old caps | delete X → recreate X (regenesis) → old-gen caps to X DENY, new caps OK | G-4 |
| membership == holds-cap | just-joined cap-holder (not in roster) reads; revoked ex-member (stale roster) denied | M-1 |
| supervisor is a real member | assigned supervisor holds membership cap → reads + moderates as a member; non-member cannot | S-2 (DECISION #5) |
| No authority-use site bypasses `authorize/3` | empty-allowlist enumerator lists every un-migrated site → drive to green | Z-1 |
| Principal-axis has no re-arm bypass | bump P → restart/activate/snapshot-restore P → `load(P)` stays `[]` | G-3 step 5 |
| **[MF1] Self-license un-re-mintable by a bumped principal** | live-P mints stale gen-N; restarted-P is `:existed`→no mint; activate re-unions only old-gen artifact → all stay `[]` | G-3 step 5 |
| **[MF2] Inline caps cannot satisfy the principal gate** | revoked holder presents valid `cap(→T)` inline → `{:error, :holder_revoked}` | F-1 step 4b |
| **[MF3] Holder is the authenticated principal, not the machinery caller** | machinery caller path → authz uses authenticated member, revoked member denied | F-6 |
| **[MF4] No stale-present window** | the instant `regenesis` commits the active-row flip, `verify_against_current` denies the old-gen cap (current key_id read from the DB active row; ETS holds only the immutable `key_id→public_key`); no process-dict read in revocation path | G-1 step 5b, Z-1 |
| **[MF5] No post-bump path re-arms a principal** | bumped agent's bridge token rejected/re-minted; every mint/issue site reads current gen | G-2 step 5b, G-6, Z-1 |
| **[MF6] Cascade source is complete (no depth cutoff)** | grandchild + great-grandchild found via `descendants/1` closure; no creation bypasses the edge chokepoint | D-1, D-4 |
| **[MF7] No live-descendant window** | fence denies each descendant at authenticate/load/authorize BEFORE its bump commits; survives mid-cascade crash | D-5, D-4 |
| **[MF8] Single-holder revoke (gen UNCHANGED) does not re-arm via stale roster** | `Capability.revoke/2` M → M re-navigates → tier-2 mount DENIES, no fresh tier-1 minted | M-10 |
| **[MF9] Unsigned scope-tuple cap denied at ACCESS** | `{:within_session,_}` cap → denied by `verify_against_current`; stripped from durable slices; only a grant-bound | G-4(f), Z-1 |
| **[MF10] First-message window closed** | message published between grant and roster-mount is replayed to the just-joined member (durable seq cursor) | M-4 |

---

## PHASE Z — the unified enumerator gate (lands LAST)

**Task Z-1:** ONE source-scan (mirror `CapCheckOnlyAtChokepointTest`, `@probes`, `assert offenders == []`) + presence tripwire (mirror `check_invariant_10`) proving: every `Capability.matches?` / authority-use consumer either routes through `Cap.authorize/3` (which runs target-gen + principal-gen + membership + **explicit authenticated holder**) OR sources caps from the fail-closed `EntityCaps.load` OR carries a reviewed explicit exemption (GRANT-side, ADMIN-definition, membership-gated read-plane). The **same site list** is the shared worklist for F (bare-matches), G (gen), D (principal/holder), M (`:members`-not-authority) — build it ONCE (this collapses the three source plans' three separate enumerator gates into one).

**Z-1 folds these v2 sub-gates (each a distinct `assert offenders == []`):**
- **[v2/MF5] recredential-generation worklist** — every mint/issue/self-target site (the v2/MF5 table + G-6's empty-allowlist output) reads the principal's current generation.
- **[v2/MF9] scope-tuple denial proof** — NO production ACCESS dispatch authorizes on an unsigned scope-tuple `ctx.cap` against a revocable target (scope tuples are denied at access by `verify_against_current`, stripped from durable slices by `verified/2`, permitted only as grant-authorization bounds). Narrows the "single chokepoint" claim HONESTLY — not "allowed unchecked."
- **[v2/MF4] no-process-dict tripwire** — `verify_against_current/3` does not read `Process.get({Authority, :current})`/`current_target?` in the revocation path.
- **[v2/MF6] derivation-edge chokepoint** — no principal-creation bypasses `record_derivation_edge` (from D-1's grep gate).
- **[v4-H2b] `ever_created` marker-preservation** — each of the four `KindSnapshot.delete` reachability sites (`snapshot_store.ex:271`, `ezagent.snapshot.clear.ex:48`, `teardown.ex:78`→`agent.ex:297`, `kind_base_backfill.ex:316`) co-deletes the identity row OR preserves the marker, so no revoke-without-delete principal can lazy-spawn `create_freshness == :created` under a bumped gen (from G-3 step 5c).

Presence tripwire: fail the build if `cap/authorize.ex` lacks the `verify_against_current`/gen call OR the dependency-inverted holder gate. Commit `test(cap): unified authority-use enumerator + recredential worklist + scope-tuple denial proof + presence tripwires (Z-1, MF4/MF5/MF6/MF9)`.

---

## RESIDUAL RISK — the one thing codex MUST verify

**Does gen-check-auth (G-2 token `bound_generation`) + cap-load-gen-check (G-3 self-license) cleanly give principal-axis revocation with NO bypass?** Two sub-questions, both must hold:

**(a) No cap-obtaining path re-derives the principal baseline from the CURRENT generation and re-arms a revoked principal. [v2: RESOLVED — codex re-verify the chain.]** The self-license is minted ONLY on `create_freshness == :created` (MF1) and is NEVER re-minted on activate/snapshot-restore/re-read (proven by the three-way un-re-mintable chain: live P mints stale gen-N; restarted P is `:existed` → no mint — **conditional on the v4-H2b marker-preservation gate: no non-delete `KindSnapshot.delete` site drops `ever_created` out from under a revoke-without-delete principal**; activate re-unions only the old-gen artifact). The inline-`ctx.caps` path — the sharpest — is closed by MF2: `authorize/3` runs the principal (self-license) gate on the HOLDER's INDEPENDENTLY-loaded set (`EntityCaps.load(holder)`), ignoring `candidate_caps`, so a revoked principal presenting a still-valid `cap(→T)` inline is denied. Every cap-obtaining path (`load/1` slice, `load_persisted/1` UserStore + snapshot, inline `ctx.caps`, activate re-read, `initial_caps_for_spawn`, PAT/bridge re-mint) is enumerated in G-3 step 5 + the G-6/Z-1 recredential worklist and fail-closes on the current generation. **Codex asks: confirm the chain has no gap.**

**(b) Is the derivation cascade enumeration complete, given there is no transitive backstop? [v2: RESOLVED — codex re-verify.]** The generation primitive has no owner-walk, so a derived agent the enumerator misses is fully live. MF6 makes the source provably complete: a DURABLE APPEND-ONLY `derivation_edges` set written at a `record_derivation_edge` creation chokepoint (grep-gated — no creation can bypass it), with `descendants/1` as a fixpoint transitive closure (NO depth-100 cutoff). MF7's durable fence fail-closes every descendant BEFORE its bump commits, closing the mid-cascade window. **Codex asks: confirm every principal-creation site routes through the chokepoint, that "owned"/edge-kind coverage (DECISION #B) is complete, and that the fence rides the same three authority-use gates.**

---

## Self-Review

- **Phase F** closes the 3 bare-matches bypasses (`kind.ex:288-297`, `authorization.ex:24-29`, `identity.ex:303`) + read-plane cap gates onto ONE `authorize/3`. ✔ Adds `verify_against_current/3` (fresh active-row read) as the revocation basis, reusing #1477's `valid_artifact?` crypto — `valid_for_target?` (cached-state) is retained only for #1477's grant-idempotency. ✔
- **Phase G** — target-axis (`revoke_all_to` + fresh `verify_against_current` reading the atomic DB active-row flip, propagates on a live target with no stale-cache window), principal-axis (token `bound_generation` + agent-bridge invalidate + self-license cap-load gate), URI-reuse=regenesis, recredential gate, acceptance. ✔ Generation stays the single primitive (self-license = target-axis on P). ✔
- **Phase D** — `delete_user` = bump-U + cascade-bump; tombstone dissolved; source-plan PRs mapped to G-2/G-3/F; atomicity boundary = durable regenesis commit; honest-terminate + reap best-effort; completeness proof. ✔ Transitivity-loss flagged → cascade enumerator correctness-critical. ✔
- **Phase M** — membership predicate on `authorize/3`; roster demoted; supervisor per-session member. ✔ File collision M-1↔F-3 coordinated. ✔
- **#1477** — subsumption + freshness precondition + merge-first + collision note. ✔
- **Decisions #1-#10** surfaced for codex/Allen; recommendations defaulted. ✔ **Residual risk (a)+(b)** stated for codex (both now RESOLVED via MF1/MF2 and MF6/MF7 — codex re-verifies). ✔
- **[v2] All 10 codex must-fixes** folded into concrete PR tasks (not just the v2 summary): MF1→G-3a(mint-on-create), MF2→F-1(dep-inverted holder), MF3→F-6(authenticated holder), MF4→F-1/G-1(atomic cache, no process-dict), MF5→G-2/G-6(recredential gate incl. agent-bridge), MF6→D-1(durable edge chokepoint+gate), MF7→D-5(durable fence), MF8→M-10(tier-1/tier-2 entitlement), MF9→G-4(f)/Z-1(scope-tuple denial), MF10→M-4(seq join cursor). ✔ **DECISION-FOR-ALLEN items:** #1(self-license realization), #4(one-vs-two counters), #5(supervisor), #6/MF9(scope-tuple defer), #7(merge_member), #8/MF10(seq cursor), #9/MF7(fence-vs-atomic), #10/MF6(store+owned scope). ✔
- **Placeholder scan:** every task cites real current-main file:line + a concrete fail-before/pass-after; mechanical detail for unchanged M-2…M-9/S tasks is delegated by explicit reference to the current-main-verified source plan (not hand-waved). **Type consistency:** `authorize/3` (holder-first, dependency-inverted), `verify_against_current/3` (no process-dict; current key_id from the DB active row), `AuthorityCache.public_key/1` (immutable `key_id → public_key` memo, no mutable-current), `valid_for_target?/2` (retained only for #1477 idempotency), `valid_artifact?/2`, `revoke_all_to/2`, `regenesis/3` (atomic active-row flip = revocation point), `bound_generation`, `descendants/1` (replaces `owned_lineage/1`), `record_derivation_edge/4`, `RevocationFence.{enroll,fenced?,clear}`, `action: :self_license`, self-license (mint-only-on-create) used consistently.

---

## Codex review asks (architecture — `feedback_codex_spec_review_architecture_not_details`)

> **v2 RE-REVIEW asks (the 10 must-fixes) come first; the original architecture asks follow.**

**v2 must-fix verification:**
- **[MF1]** Is the un-re-mintable chain airtight — mint gated on `create_freshness == :created` (server.ex:162), seam 1a (create hook), delete clears the self-license, recreate=regenesis mints a fresh one? Any path where a bumped principal re-arms?
- **[MF2/MF3]** Does the dependency-inverted holder gate (principal check on `EntityCaps.load(holder)`, never `candidate_caps`) + explicit AUTHENTICATED holder (never `ctx.caller` when caller is machinery) fully close inline-`ctx.caps`?
- **[MF4]** Is "invalidate INSIDE the regenesis transaction + read-through to the DB active row + no process-dict shortcut" race-proof (ETS never stale across a bump)?
- **[MF5]** Is the recredential enumeration COMPLETE — incl. the agent-bridge file bearer (`token_store.ex:32`, separate from `entity_tokens`), all mix tasks, self-target construction?
- **[MF6]** Does the `record_derivation_edge` creation chokepoint + grep gate provably cover every principal-creation site, and is `descendants/1` a true no-cutoff fixpoint closure over an append-only edge set?
- **[MF7]** Does the durable fence (enroll-before-bump, deny at authenticate/load/authorize, survive crash) leave NO live-descendant window? Fence vs atomic (DECISION #9)?
- **[MF8]** Is the tier-1/tier-2 entitlement split correct — is "roster presence is not entitlement" enforced so single-holder revoke (gen UNCHANGED) does NOT re-arm via a roster-driven mount? (This does NOT lean on generation/self-license.)
- **[MF9]** Is the honest narrowing sound — scope-tuple caps denied at ACCESS (not "exempt"), permitted only as grant bounds, with a Z-1 proof gate?
- **[MF10]** Is the join cursor set atomically-with the `{:set, :members}` mount and seq-based, closing the nil-cursor first-message window?

**Original architecture asks (still open):**
1. **DECISION #1** — is the signed self-license the right realization of principal-axis (generation as single primitive), or is the mutable `acting_generation` baseline preferable? (v2 makes the self-license airtight via mint-on-create; confirm it beats 1b.)
2. **DECISION #2 (corrected)** — confirm the target-axis revocation basis is `verify_against_current/3` (fresh active-row read + ETS `AuthorityCache`, invalidate-INSIDE-transaction), NOT `valid_for_target?` (cached `state.authority`). Is `valid_for_target?` correctly retained ONLY for #1477's grant-idempotency/presenter-freshness?
3. **DECISION #4** — one generation per URI conflating target-axis and principal-axis — correct (delete wants both) or does a real op need two counters?
4. **DECISION #5** — supervisor = per-session reviewer-membership (Option 1/1a) — the right dissolution of the review-but-not-member middle state?
5. **base-branch** — base=main + build the durable derivation-edge store fresh (MF6 supersedes v1's "re-land #1469 cascade") vs base=#1469?
6. **#1477** — is the split correct: #1477's `valid_for_target?`/`already_authorized?` (cached-current) stays for grant-idempotency/presenter-freshness, while F-1's `verify_against_current` (fresh active-row read) owns the ACCESS/revocation path? Does F-1 preserve #1477's drift gate (no direct `current_caps` dispatch read)?
