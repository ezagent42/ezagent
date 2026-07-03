# Codex Handoff — Socialware Manifest track

**To:** codex (development). **From:** lead (Allen + Claude). **Date:** 2026-07-03.

## Target branch model
Develop on **`integration/socialware-manifest`** (already created off `main`). Each PR/wave: commit + push to that branch, self-merge your own increments **onto that branch** — do NOT merge to `main`, do NOT open PRs against `main`. When the track's acceptance gate is met, **return the branch** to the lead, who runs full gates and merges to `main`. Keep the branch rebased on `main`.

## Read first (both on this branch)
- **Plan:** `docs/together/2026-07-03/plans/socialware-manifest-plan.md` — the 6 PRs, DoDs, **and the "Codex adversarial review — corrections that OVERRIDE" section (C-1..C-7): those corrections are authoritative.**
- **Spec:** `docs/superpowers/specs/2026-07-03-socialware-manifest-design.md` — the model + field set + decisions.
- **Skills to load:** `ezagent-socialware`, `ezagent-developer`, `ezagent-session-orchestrator` (as relevant).

## Goal (one line)
Make a socialware authorable as a **pure-config manifest (zero code; all code in a plugin it `uses`)** that goes **create → publish → discover → install → use**, with a **non-cc-flavor** agent materializing — the full chain, not per-layer stubs.

## Acceptance gate (the track's DoD — non-negotiable)
An **E2E test** that authors a real socialware as pure config, publishes it (`ConfigGovernance.Socialware`), discovers it (`DefinitionRegistry.list`), installs it via the new-session page, and uses it — **with ≥1 non-cc agent materializing (config+readiness+role+grants+join) and its views rendering** — and **fails if any link breaks**. Plus `mix ezagent.socialware.check` extended to assert manifest validity+installability. Plus all standard gates green (`arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test`/`:ezagent_plugin_check`). **Backend-only "done" is rejected.**

## Waves (sequencing per correction C-3 — the plan's "PR1-4 independent" claim is WRONG)
- **Wave A (parallel):** PR-1 (name-ref resolver **+ add `uses` field to the `Definition` struct** — C-5) · PR-2 (`DefinitionRegistry.list` **+ write ownership ACL with a named authority boundary** — C-4).
- **Wave B (both DISCUSS-FIRST — post a short design + self-run a codex adversarial review of that design before coding):**
  - **PR-4 (flavor) — the load-bearing piece (C-1).** NOT a shallow `Recipe.Compose` swap. Route socialware agent materialization through / share the **world create-agent flavor pipeline** (`agent_create.ex:336` + `role_step.ex:159`) that already does flavor template-data + config validation + cap minting + role markers + config_dir + readiness. `Recipe.Compose` alone does NOT compose caps (`compose.ex:19,55`).
  - **PR-3 (publish) — needs a NEW cap model (C-2).** `ConfigGovernance` is agent-bound (caps/subject/self/effects). Define a concrete **subject-owner + cap shape** for a `socialware:<name>` subject (a socialware is NOT an agent — who owns it? the creating user/workspace). Reusable machinery ≈ `ConfigChangeStore` (which does NO auth — you must add the auth). `.Agent` = today unchanged; `.Socialware` = new.
- **Wave C:** PR-5 (new-session page — needs PR-1,2,**4**) · PR-6 (dogfood autoservice/hello as pure-config manifest + the acceptance-gate E2E — needs PR-1..4).

## Rules
- **Every PR carries a behavioral proof** (not just `socialware.check` statics — C-6). A regression/E2E test that fails on the pre-change code.
- **Fail-closed** everywhere: a manifest referencing an un-installed plugin/view must NOT produce a half-built socialware; write/publish must reject cross-workspace/forged subjects.
- **PR-3 and PR-4 designs get a codex adversarial review before implementation** (they touch CapBAC/core + the materialization pipeline).
- Keep `main` green discipline: rebase on `main`, run the affected suites (`MIX_TEST_PARTITION=<unique>` when running in a worktree).
- Report back per wave: what landed on the branch, gates run, and any design decision that needs the lead/Allen (e.g. the PR-3 socialware-subject cap shape).

## Return
When the acceptance gate is green on `integration/socialware-manifest`, return the branch + a summary (each wave's proof + the E2E transcript). Lead runs full gates + merges to `main`.
