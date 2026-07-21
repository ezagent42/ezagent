# KIMI HANDOFF — #195 Unified Generation-Revocation + `authorize/3` (WHOLE PROGRAM, one shot)

You are implementing a **security-critical, multi-phase cap-model program** in the ezagent Elixir umbrella. This is the complete remaining #195 program (~28 PRs across 4.5 phases). Work through it phase-by-phase IN ORDER; it is long — checkpoint-commit as you go and do NOT stop until every phase is implemented or you hit a genuine blocker.

## Repo / base
- Repo: the ezagent umbrella. Branch FROM the latest `origin/main` (has F-1 `#1493` + read-plane PR-1..5 + `#1477` presenter-cap reconcile all landed).
- Create ONE feature branch: `feat/195-unified-revocation`. Commit per TASK with the task id in the message (e.g. `feat(cap): G-1 cap-gated revoke_all_to …`). Open a **DRAFT** PR (`gh pr create --draft --base main`) once Phase F is green; keep pushing to it as phases land. **Do NOT merge. Do NOT self-review-merge** — this is security code; the coordinator + codex run the adversarial review gate before anything merges.

## READ FIRST (load these — this is the cap-model core with silent invariants)
1. The **`ezagent-developer` skill** + its `references/capbac.md` (the cap-model bible), and the `elixir-phoenix-helper` skill if present.
2. **THE PLAN — read it in full, it is the spec:** `docs/superpowers/plans/2026-07-20-unified-generation-revocation-and-authorize.md` (on `main`, ~830 lines, v4 — 4 rounds of adversarial review folded in). It has the paradigm, the ground-truth anchor table (real file:line on main), the decisions, the v2/v3/v4 must-fix resolutions, and **every task F-2…Z-1 with code blocks + acceptance criteria**. Implement the tasks EXACTLY as written; the code blocks are the design.

## SCOPE — implement everything EXCEPT F-1 (already merged as #1493)
Follow the plan's **"Sequencing (load-bearing)"** section (line ~371) as your order:

- **Phase F remainder**: F-2 (route the 3 bare-matches bypasses through `authorize/3`), F-6 (thread the AUTHENTICATED holder into every authorization API). **F-3/F-4/F-5** (read-plane cap gates) — the read-plane epic (PR-1..5) already landed the session/socialware/pty/world/uploads/identity read gates; your F-3/4/5 job is to **RE-POINT those existing gates onto the unified `authorize/3`** (not re-implement them). Verify against main what's already gated before writing.
- **Phase G** (G-1…G-6): generation-as-revocation-primitive. Cap-gated `revoke_all_to/1` + re-gate `regenesis` (G-1); token `bound_generation` + agent-bridge invalidate-on-bump (G-2); **G-3 self-license principal-gen gate INCLUDING the v4-H2b marker-preservation enumerator gate (Step 5c) over the FOUR `KindSnapshot.delete` reachability sites** (`snapshot_store.ex:271`, `mix/tasks/ezagent.snapshot.clear.ex:48`, `teardown.ex:78`→`retire_spawned` `agent.ex:297`, `kind_base_backfill.ex:316`) — this is a correctness precondition, do not skip it; URI-reuse=regenesis (G-4); acceptance suite (G-5); recredential-generation gate (G-6).
- **Phase D** (D-1…D-5): durable append-only derivation-edge store + `record_derivation_edge` chokepoint + grep gate + `descendants/1` (D-1); `delete_user` = bump-U + cascade-bump + clear stale self-license (D-2); honest-terminate + reap (D-3); durable pending-revocation FENCE enforced fail-closed at the act-time gates (`load`+`authorize`+`authenticate`+`spawn_principal`) (D-5); completeness proof (D-4).
- **Phase M** (M-1…M-10 + S-1/S-2): membership-cap-as-truth predicate on `authorize/3`; drop roster truth; grant-only join; durable join cursor atomic-with-mount + replay (M-4); reconciliation-entitlement tier-1/tier-2 split (M-10); supervisor per-session member (S-2, gated on the plan's DECISION #5 — if that decision is unresolved in the plan, STOP and flag S-2, implement M-1..M-10 + S-1).
- **Phase Z** (Z-1, LANDS LAST): the unified enumerator gate — ONE source-scan proving every authority-use site routes through `authorize/3` (both axes + membership + explicit holder) + the recredential worklist + the scope-tuple denial proof. Build it empty-allowlist, run it, and let it produce the worklist — it is the shared completeness proof for F/G/D/M.

## Non-negotiables
- **Ground every symbol against real main.** The plan's anchor table was verified at `fe2906431`/`6f54f1f9e`; main has moved (read-plane + #1477). Before implementing a task, `git grep` the cited symbols; if a cited file:line or function has moved or no longer exists, **STOP and report the specific gap** rather than guessing — this is core cap code and a wrong guess is a security hole.
- **The enumerator gates (G-3 Step 5c, Z-1) are GATES, not assertions** — empty-allowlist, mirror `CapCheckOnlyAtChokepointTest`. They must fail-before / pass-after.
- **TDD**: failing test first for each task's acceptance criterion.
- **Tests**: `export MIX_TEST_PARTITION=p195` first. Per phase, verify: your new tests + `apps/ezagent_core` suite + `mix compile --warnings-as-errors` clean. A full `mix ci.local` per phase is ideal but slow — at minimum compile-clean + the phase's own suites + the arch/invariant gates.

## Deliverable & reporting
- Commit per task; push to `feat/195-unified-revocation`; DRAFT PR.
- **Final message**: a per-phase table — for each of F/G/D/M/Z: tasks done, tests (fail-before/pass-after for the security-critical ones: revoke denies old-gen, self-license un-re-mintable, marker-preservation gate, membership-as-truth, Z-1 enumerator empty-allowlist result), any plan ambiguity / missing-symbol you STOPPED on, and the PR URL.
- If any single phase's design in the plan is ambiguous or a cited symbol is gone, STOP that phase and report — do not force a resolution on cap-core.

This whole program is budgeted as a long multi-hour run — read the plan fully first, then grind phase by phase. The coordinator (cc) + codex will run the adversarial review + pre-merge gate on your hand-back.
