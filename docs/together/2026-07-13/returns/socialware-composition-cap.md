# Return — socialware composition-cap lane (v5)

> **Task:** socialware composition-cap lane v5
> **Branch:** `feat/socialware-composition-cap`
> **PR:** none
> **Dev:** codex
> **returned_at:** 2026-07-13 09:29 +0800
> **deadline:** n/a — off-plan agent support
> **deadline_status:** out_of_scope

## Summary

The socialware **composition-cap** lane declares and mints **operate** capabilities
between socialware members (a "source operates target" edge) through the codebase's
**existing owner gate**, not a new authorization primitive. An operate-cap is minted
only when the configurer legitimately owns the source member and the target resolves
to a real data-owner; when owner authority is absent the edge **fail-closes to
participate-only** (no over-privileged operate cap). The lane spans six commits: two
fixes that make owners resolvable and installs fail-closed (PR-0a/0b), the Definition
`operates` declaration + conformance (PR-1), the owner-gated mint under
`{:held_by, configurer}` (PR-2), the consent/revocation lifecycle (PR-3), and lifting
passive **data-as-agent** roles onto composition caps without joining session
membership (PR-4).

Implementation is **complete** and local focused + invariant gates are **green**. The
**machine return gate is NOT met**: there is no PR and therefore no remote CI URL, and
the full `mix ci.local` aggregate exits **2** due to the repo's pre-existing
default-SessionTemplate concurrent-seed flake (isolated re-run of the same files
passes). Per the dev-together standard this return does **not** self-declare "READY TO
MERGE" — it asks the lead to review the target branch and decide review/CI topology.

This is **off-plan agent support**: the closest daily ledger is `docs/together/2026-07-10/plan.md`
(that day's tracks were AgentRuntime boundary / cc-headless / kanban+dealscout, with
the coordinator as off-plan support). The composition-cap spec is dated 2026-07-12 and
is not a planned 2026-07-10 track, so `deadline_status: out_of_scope`. There is no
`docs/together/2026-07-13/plan.md`.

## Source of truth

- **Spec:** `docs/specs/2026-07-12-socialware-composition-cap-lane.md` read from branch
  `spec/socialware-composition-cap-revision-v5` @ **`9243ff1f4c007255b6d6dbc7e35bc85c929d191b`**
  (verified: that commit's tree carries the file; blob
  `12857e08d353729e0ef777d59914223c6204611f`). This is **v5**, not v4 and not the
  intermediate v5 commit `5d216a7be`.
- **Baseline pin (spec §13.4 #9):** `origin/main` @ `720913ad` — verified real
  `origin/main` = `720913ad698caffc7091776f6fbc822a038214d8`.
- **v5 core model (unchanged from v3/v4, Allen-approved):** the operate-cap mint routes
  through the **existing** `authorize_cap_shape` owner check via the
  `{:held_by, configurer}` tag; foreign target → `:grant_not_owner` → fail-closed →
  participate-only. v5's single substantive change vs v4: **the blanket core
  `authorize_cap_shape` fail-closed flip (v4 PR-0a(b)) is DESCOPED** to a separate
  out-of-scope CapBAC-hardening item (spec §7.1). The lane keeps PR-0a(a) (route
  operable targets to a real owner resolver) + the §3.6(iii) mint-time self-assertion,
  which alone keeps the lane fail-closed.

## Six-stage commit ledger

All six SHAs verified as ancestors of `HEAD` (= `d7ebcd39b`); 0 behind / 6 ahead of
`origin/main`.

| # | SHA | Subject | What it does |
|---|-----|---------|--------------|
| PR-0a | `3d8842a80` | fix(caps): resolve operable agent owners | Domain/plugin-layer `data_owner/1` delegation to canonical `Ezagent.ActionSet.ApiKeys.data_owner/1` for cc-headless + Kanban (KB delegated in PR-4). Owner chain `creator_uri → AgentLineage → :no_owner`. Did **not** push agent/api_keys/creator_uri concepts into the `ezagent_core` business-blind macro. |
| PR-0b | `acc6008dc` | fix(socialware): fail install without session owner | Install must resolve a **real** session owner; configurer provenance no longer uses an admin fallback; fail-closed when no real owner exists. Touches `session_creator.ex` (+ install test). |
| PR-1 | `b919558ff` | feat(socialware): declare composition operate edges | `Definition` supports composition `operates` declaration; shape / target-role / action / target-behavior conformance. Did **not** write runtime participant URIs into the Definition. |
| PR-2 | `3b41d157c` | feat(socialware): mint composition operate caps | Operate-cap routed back through the owner gate; tag `{:held_by, configurer}` (**not** `{:rule,…}` which bypasses the owner check). Direct `Cap.issue` + `absorb_cap` + VERIFY retained; `granted_by` = real target owner; **target-owner mint-time self-assertion before ISSUE** (fail-loud when `data_owner_of ≠ %URI{}`); source-owner assertion requires configurer owns the SOURCE member. **No global core `authorize_cap_shape` DENY flip.** |
| PR-3 | `20bc76283` | feat(socialware): add composition consent lifecycle | participate/operate split; operate fail-closes to participate without owner consent; consent / leave / remove / uninstall revocation lifecycle; provenance + binding lifecycle auditable. |
| PR-4 | `d7ebcd39b` | feat(socialware): lift data roles onto composition caps | Passive data-as-agent role **materializes but does NOT join session membership** (preserves RF-6); passive URI derived deterministically from session URI + role name via the normal recipe materializer, building owner lineage; `DefinitionAgents` hands a role→member-URI map to `CompositionCaps.reconcile_session`. Kanban manifest adds a passive board role; kanban-assistant gets all Kanban actions via **20 exact-instance operate edges**; kanban-assistant + dev-together recipe ambient `requested_caps` cleared; Autoservice gets `Kb.query` via `autoservice operates kb`; **removed direct `Identity.grant_cap`** in the Autoservice seed script; KB `data_owner/1` delegates to `ApiKeys.data_owner/1`; added KB owner-resolution/authorization tests; data-as-agent target resolves a real owner before the mint self-assertion. |

## Locked decisions / descope (must not be misreported)

- **0a(b) is REMOVED from this lane (v5).** There is **no** change to core
  `authorize_cap_shape`'s `else -> :ok` / catch-all. Whether core gets a surgical
  tightening is spec **§7.1**, a separate follow-up — NOT this lane.
- Do **not** put agent / api_keys / creator_uri concepts into the core business-blind
  macro. Owner resolution stays in the domain/plugin `data_owner/1` implementations.
- This lane did **not** fix the repo's pre-existing default-SessionTemplate
  concurrent-seed flake. That flake is independent CI-stability debt (see below).

## DoD reconciliation

Closed set of 19 lines. Each carries status + proof. Paths are repo-relative to the
worktree root; line numbers cited where verified against the committed tree.

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Owner of all operable composition targets delegates via domain/plugin `data_owner/1` to the canonical 3-tier resolver | **met** | KB: `apps/ezagent_plugin_kb/lib/ezagent/behavior/kb.ex:76` → `ApiKeys.data_owner/1` (+ `apps/ezagent_plugin_kb/test/behavior/kb_data_owner_test.exs`). Kanban: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:249` → `ApiKeys.data_owner/1` (+ `kanban_data_owner_test.exs`). cc-headless: `apps/ezagent_plugin_cc/lib/ezagent/behavior/cc_headless_agent.ex` (+ `cc_headless_agent_data_owner_test.exs`). |
| 2 | 0a(b) core global DENY flip NOT in this lane | **met** | `git diff origin/main...HEAD -- apps/ezagent_core/lib/ezagent/capability_registry.ex` is **empty**; `git log origin/main...HEAD` on that file lists **no commits**. Core `authorize_cap_shape` untouched. |
| 3 | Configurer provenance uses real installer/owner; admin owner fallback removed | **met** | PR-0b `acc6008dc`: `session_creator.ex` (48 lines) + `install_session_socialware_test.exs` (+30) — install fail-closes without a real session owner. |
| 4 | Definition `operates` schema + source role + target role + action + target-behavior conformance | **met** | PR-1 `b919558ff`; conformance in `definition_test.exs` (+117) and manifest conformance tests (`manifest_yaml_test.exs`). Wired to `mix ezagent.socialware.check`. |
| 5 | participate/operate split; no-owner-auth → downgrade to participate only, no over-privileged operate | **met** | `composition_caps.ex` `classify_source_authority/2` (~L264) sets `source_required?`; `composition_consent.ex` + `composition_caps_test.exs` (+684) cover the downgrade. |
| 6 | SOURCE-owner assertion exists; configurer must own source member | **met** | `composition_caps.ex:266-269` `source_authorized? = match?(%URI{}, source_owner) and (same_uri?(source_owner, configurer) or Identity.Authority.manages?(configurer, source_uri))`; regression in `composition_caps_test.exs`. |
| 7 | operate-cap via `authorize_cap_shape`, tag `{:held_by, configurer}` | **met** | Mint at `composition_caps.ex:241` `Ezagent.Cap.issue({:held_by, configurer}, item.source_uri, item.cap)`. `authorize_cap_shape` is core's **internal** owner gate reached **because** of the `{:held_by,…}` tag (vs `{:rule,…}` which bypasses it) — the name does not appear literally in the lane diff; the routing is the tag choice. |
| 8 | `granted_by` = real target owner, no admin fallback | **met** | `composition_caps.ex:247-249` re-issues under `{:held_by, item.target_owner}`; `target_owner` comes from `assert_target_owner/2` (real `%URI{}` owner, fail-loud otherwise). Covered by mint/authorization tests in `composition_caps_test.exs`. |
| 9 | Direct `Cap.issue` + `absorb_cap` + VERIFY retained; mint-time owner `%URI{}` self-assertion | **met** | `Cap.issue` L241/L247; `Identity.absorb_cap` L308; self-assertion `assert_target_owner/2` L393-405 requires `data_owner_of` to return `%URI{}`. Invariant coverage in `composition_caps_test.exs`. |
| 10 | Configurer provenance traceable to install/definition config/hash | **met** | Provenance fields carried on the binding/consent rows (`composition_binding.ex`, `composition_consent.ex`) + migrations `20260712000000_*` / `20260712001000_*`; asserted in `composition_caps_test.exs`. |
| 11 | leave/remove/uninstall revokes composition bindings/caps/consents | **met** | `composition_caps.ex` `deactivate_session/2` (L57, `:uninstall`) + `deactivate_member/3` (L68, `:role_departure`); `composition_consent_command.ex`; lifecycle tests in `composition_caps_test.exs` + `installation_test.exs`. |
| 12 | passive data-as-agent role not in membership but owner-resolvable + usable as composition target | **met** | PR-4 `definition_agents.ex` materializes passive role with owner lineage, no membership join (RF-6); `definition_agents_materialize_test.exs` (+95). |
| 13 | Kanban assistant gets only passive-board exact-instance caps; dev-together gets no ambient board cap | **met** | Kanban manifest `apps/ezagent_plugin_kanban/.../socialware_seed/kanban/manifest.yaml` = 20 exact-instance operate edges (grep: 21 `operates`/`action:` markers incl. header); ambient `requested_caps` cleared; `kanban_manifest_test.exs`, `kanban_role_test.exs`, `kanban_team_*` integration tests. |
| 14 | Autoservice KB perm from composition edge, not direct `Identity.grant_cap` or recipe ambient cap | **met** | `apps/ezagent_web/priv/socialware_seed/autoservice/manifest.yaml:15-19` `operates: role: kb … action: query`; `git grep Identity.grant_cap scripts/autoservice_tier1_seed.exs` = **no match** (removed). KB E2E via plugin_kb tests. |
| 15 | pnpm-lock.yaml ci.local noise removed | **met** | `git status --short apps/ezagent_web/assets/pnpm-lock.yaml` = clean; worktree clean overall; no lockfile diff vs HEAD. |
| 16 | Target independent, not merged to main, no PR to main | **met** | `git rev-list --left-right --count origin/main...HEAD` = `0  6`; branch not merged to `main`; no PR exists. See Branch/remote topology. |
| 17 | Machine return gate: PR-head remote CI green | **NOT-MET** | There is **no PR** and therefore **no CI run URL**. Local tests are not remote CI and are not presented as such. Open decision for the lead. |
| 18 | Branch rebased/current against main | **met** | After `git fetch origin main`, `0` behind `origin/main`. Real `origin/main` SHA = `720913ad698caffc7091776f6fbc822a038214d8`. Merge-base is up to date. |
| 19 | Full local gate aggregate exit 0 | **NOT-MET** | `mix ci.local` exits **2** due to the repo's pre-existing concurrent-seed flake (3 setups across 2 files). The failing files pass on isolated re-run (see Known flake). Not an aggregate exit-0. |

**Method friction:** see the dedicated section below.

## Verification evidence (recorded as LOCAL results, NOT remote PR CI)

**Read-only checks re-run against the current committed tree (`d7ebcd39b`):**

- `git status --short --branch` → clean (`## feat/socialware-composition-cap...origin/feat/socialware-composition-cap`, no working-tree changes).
- `git rev-parse HEAD` = `d7ebcd39b00a6481fab8217dcf7ea8f6fd5754d2` = `git rev-parse origin/feat/socialware-composition-cap` (local == remote).
- `git rev-list --left-right --count origin/main...HEAD` = `0  6`.
- `git diff --check` → clean.
- All six ledger SHAs are ancestors of HEAD.
- `capability_registry.ex` has **no diff** vs `origin/main` (DoD 2).
- `pnpm-lock.yaml` clean (DoD 15).
- `scripts/autoservice_tier1_seed.exs` has **no** `Identity.grant_cap` (DoD 14).

**Heavy-suite results (recorded as PRIOR-RUN evidence per handoff — NOT re-run in this
return unless noted below; labeled honestly as prior-run):**

- Latest full gate: `MIX_ENV=test MIX_TEST_PARTITION=cccompositionfinal2 ERL_FLAGS='+S 4:4' mix ci.local` → aggregate **exit 2**.
  - `ezagent_core` + rest **pass**; `ezagent_domain_socialware` **231/0**; `ezagent_plugin_kb` **24/0**; `ezagent_plugin_kanban` **80/0**; `ezagent_web` **331/0**; `ezagent_cli` **32/0**.
  - `mix ezagent.check_invariants` **pass**.
  - socialware conformance: chat **15/15**, orchestrator **15/15**, socialware **15/15**.
  - The 3 aggregate failures = the SAME pre-existing seed race (see Known flake).
- `mix precommit` → only hit the same seed flake; isolated re-run **9/0**.
- PR-4 focused regression: `DefinitionAgents` **16/0**, Kanban integration **2/0**.
- Earlier expanded focused suites: domain session DefinitionAgents/manifest **32/0**; plugin KB/Autoservice **4/0**; Kanban suites pass.

**Fresh isolated flake re-run performed in THIS return:** see the Known flake section
(result recorded verbatim from the run, distinct from the prior-run numbers above).

## Known flake + isolated proof

- **Nature:** the repo's `seed_default_session_template` intermittently fails under the
  high-concurrency umbrella aggregate with `persist failed: :failed`. It is a
  concurrent-seed race, **independent of composition-cap** — do not attribute it to this
  lane.
- **Where it bites the aggregate:** 3 setups across 2 files —
  `apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs`
  (2 setups) + `apps/ezagent_domain_session/test/ezagent/entity/session/default_session_template_seed_test.exs`
  (1 setup). Common error: `seed_default_session_template: persist failed: :failed`.
- **Isolated proof (prior run, per handoff):** `mix test <those 2 files>` in the same
  partition → **14 tests, 0 failures, exit 0**.
- **Isolated proof (fresh re-run, this return, 2026-07-13):**
  `MIX_ENV=test MIX_TEST_PARTITION=cccompositionfinal2 ERL_FLAGS='+S 4:4' mix test
  apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs
  apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs`
  → **14 tests, 0 failures** (finished in 18.0s), exit 0. Matches the prior-run isolated
  proof; confirms the aggregate exit-2 is the non-deterministic concurrent-seed race, not
  a stable failure.
- **Disposition:** file as a **separate CI-stability debt** (default-SessionTemplate
  concurrent-seed race), not a composition-cap regression.

## Branch / remote topology

- **Target branch:** `feat/socialware-composition-cap`.
- **Local HEAD:** `d7ebcd39b00a6481fab8217dcf7ea8f6fd5754d2`.
- **origin/feat/socialware-composition-cap:** `d7ebcd39b00a6481fab8217dcf7ea8f6fd5754d2` (local == remote; nothing to push).
- **origin/main:** `720913ad698caffc7091776f6fbc822a038214d8`.
- **Position vs main:** `0` behind / `6` ahead. Not merged to `main`. **No PR to main. PR field = none.**
- Worktree clean; `git diff --check` clean.

## Deferred / open decisions for lead

1. **Machine return gate (DoD 17) — remote CI:** no PR / no CI URL. Does the lead accept
   local focused + invariant green as the return evidence for this off-plan lane, or
   require a PR (against a non-main review target) to produce a green CI head first?
2. **Full aggregate (DoD 19) — the concurrent-seed flake:** accept "aggregate exit 2 +
   isolated-proven pre-existing flake" as local evidence, or block on making the
   aggregate deterministically exit 0?
3. **Review/CI topology:** the machine gate is not met, so the lead decides how to review
   — establish a non-main review/CI topology (a review branch/PR that does not target
   `main`), or review the target branch directly?
4. **Default-SessionTemplate concurrent-seed flake:** file as independent CI-stability
   debt (separate issue), tracked apart from this lane?
5. **Core `authorize_cap_shape` §7.1 follow-up (descoped):** confirm it stays out of this
   lane and is scheduled separately with its own issuance-path inventory.
6. **Post-review rebase/revision:** lead may rebase/fix the target after review.

## Method friction

- **Spec moved v4 → v5 mid-development, and the v5 HEAD was corrected from the
  intermediate `5d216a7be` to `9243ff1f4`.** Handoffs must always bind a **full commit
  SHA** for the source-of-truth spec, never "v5" or a name.
- **0a(b) was proposed then explicitly descoped.** Without "no core global flip" pinned
  as a **LOCKED decision** in the handoff, it is easy to over-reach on a broad security
  change to core `authorize_cap_shape`.
- **PR-4's data-as-agent case requires the passive target to have owner lineage BEFORE
  the mint self-assertion.** That dependency must be **explicitly enumerated in the DoD**
  (it is DoD 12 here) — otherwise the mint fails-loud with no obvious cause.
- **`mix ci.local` rewrites `apps/ezagent_web/assets/pnpm-lock.yaml`** with
  dependency-sync noise; it must be **restored before return** (confirmed clean here).
- **The repo's default-SessionTemplate seed intermittently fails under the
  high-concurrency umbrella but the isolated files pass;** treat as **independent
  CI-stability debt**, NOT attributable to composition-cap.

## Merge request

**Do NOT merge to `main` and do NOT create a PR to `main`.** The lane is
implementation-complete but the **machine return gate is not met** (no PR / no remote CI
URL; `mix ci.local` aggregate exits 2 on the pre-existing concurrent-seed flake), so
this is **not** a "READY TO MERGE" verdict — that is the lead's call at `close`.

**Request:** please **review** `origin/feat/socialware-composition-cap @ d7ebcd39b`
(6 commits ahead of `origin/main` `720913ad`, 0 behind, worktree clean). Because the
machine gate is not yet met, the lead decides the review/CI topology — either review the
target branch directly, or establish a non-main review/CI target (a PR that does **not**
target `main`) to produce a green CI head. The lead may rebase/fix the target after
review. Open decisions 1–6 above are for the lead to adjudicate.

**Layered conclusion (machine gate NOT met — not "all gates green"):**
1. Implementation status: **complete**.
2. Local focused/invariant status: **green**.
3. Full aggregate status: **exit 2**, only the isolated-proven pre-existing
   concurrent-seed flake.
4. Remote CI status: **not available** (no PR / no CI URL).
5. Merge readiness: **open decision for the lead**.
6. Lead decides: accept aggregate-flake + isolated-green as local evidence? establish a
   non-main review/CI topology or review target directly? file the default-SessionTemplate
   concurrent-seed flake as separate debt? rebase/revise target after review?
