# Handoff — reflow.sh Phase-1: daily migration-rehearsal with FULL data reflow (incl credentials) + verify + deploy.yml schedule + deploy-skill update (codex)

**To:** codex  ·  **From:** coordinator (Claude)  ·  **Date:** 2026-06-29
**Repo:** `/Users/h2oslabs/Workspace/esr-ng` (ezagent42/ezagent)

## Mission
Harden the existing `docker/reflow.sh` into a daily migration-rehearsal pipeline: after every nightly and beta deploy, reflow stable's FULL data (including credentials — no scrub, no table-picking) into the target env, run the migration, verify it, and block promotion on failure. Wire it into `deploy.yml`. Update the deploy-skill (#111).

## Context (verified — read these files first)
- `docker/reflow.sh` — the existing one-way stable→beta/nightly data reflow. **Currently protects target credentials** (saves target's cred tables + FS cred subtree → overwrites with stable → restores target's creds). **Lead's NEW requirement: reflow EVERYTHING including credentials** (so new users created in prod are testable in nightly/beta). Remove the credential-protect logic.
- `docker/backup.sh` — per-domain pg_dump + FS snapshot + manifest. **Reuse this** (call before reflow as a rollback anchor; don't reinvent pg_dump).
- `docker/deploy.sh` — build-once/promote-artifact deploy + health-check + rollback.
- `.github/workflows/deploy.yml` — self-hosted Mac runner; triggers: nightly=daily cron 03:00 CST, beta=push `beta`, stable=push `release` + GitHub Environment approval.
- `docs/together/2026-06-29/specs/cross-env-data-sync.md` (#1082) — the SPEC (Phase-1 design; note: SPEC assumed scrub/credential-protect — lead OVERRIDES that: full reflow including credentials).
- `docs/together/2026-06-29/notes/migration-rehearsal-phase1-draft.md` (#1085) — the analysis draft (reflow vs SPEC diff).

## Lead decisions (OVERRIDES SPEC where conflicting)
1. **nightly/beta = pre-production verification envs** (prod data + new code) — NOT fresh experiment envs. So in-place reflow is correct (no ephemeral DB).
2. **FULL data reflow including credentials** — no scrub, no table-picking. messages.body, credential_grants, entity_tokens, password_hash, ALL of it. Reason: new users in prod must be testable in nightly/beta. **Remove the credential-protect logic from reflow.sh** (steps 1, 4-restore, 6 in the current script).
3. **Deploy schedule kept**: nightly=daily cron, beta=push beta, stable=push release+approval.
4. **Deploy-skill (#111) must be updated** to include the reflow+verify step.
5. **Failure blocks promotion**: reflow/verify failure on nightly → blocks beta promotion; failure on beta → blocks stable promotion.

## Handoff contract
- Target branch `fix/reflow-phase1-full-data-rehearsal` off `origin/main`. Worktree under `.worktrees/`.
- **Self-merge all commits onto the target branch; do NOT merge to main, do NOT open a PR.** Return target branch to coordinator for accept+merge.
- `Skill: ezagent-developer`. **Goal: reflow.sh hardened + verify-rehearsal.sh + deploy.yml wired + deploy-skill updated; gates green.** Self-drive.
- **Commit per step; push incrementally.** If you stall (usage cap), the pushed commits persist.

## The work

### 1. Simplify reflow.sh: FULL data reflow (remove credential-protect)
- **Remove** the credential-protection logic: steps 1 (save target creds), 4-restore (restore target FS creds), 6 (restore target DB creds). The reflow becomes: stop target ezagent → stable DB full dump → DROP+recreate target schema → load stable data → stable FS full copy → start target ezagent → Release.migrate() → health check.
- The `CRED_TABLES` / `CRED_FS_PATH` variables and their save/restore become dead code — remove them.
- Keep: the one-way enforcement (stable=source only, refuse stable as target), the health check, the schema DROP+recreate + load.
- Update the moduledoc/comments: "FULL data reflow including credentials — target env becomes a faithful copy of stable for pre-production verification."

### 2. Add `docker/verify-rehearsal.sh <channel>` — 6-gate post-migration verification
After reflow+migrate, verify the migration succeeded (not just "container healthy"):
1. **Migration log clean**: `Release.migrate()` produced no errors (check container logs for migration errors / Ecto exceptions).
2. **Row-count sanity**: key tables (users, entity_profiles, socialware_config_objects, kind_snapshots, messages, sessions) have row counts comparable to stable (within a tolerance — exact match expected since full copy).
3. **ConfigObject decode**: sample ConfigObjects (recipe key "recipe", socialware key "socialware") can be read + decoded without error (the `kind_snapshots.state_binary` term_to_binary didn't corrupt).
4. **Schema version**: `schema_migrations` version in target matches the code's latest migration version (no pending migrations left).
5. **Agent slice integrity**: at least 1 agent's kind_snapshot can be loaded (SafeLoad) without error.
6. **HTTP serve**: the channel's apex `/login` returns 200 (the app booted + serves post-migration).
- Exit non-zero on any failure; print which gate failed.

### 3. Wire into `deploy.yml` — daily rehearsal after nightly + beta deploy
- After the nightly deploy step (cron trigger): add `backup.sh nightly` → `reflow.sh nightly` → `verify-rehearsal.sh nightly`. If verify fails → the job fails (marks this nightly deploy as failed; blocks downstream beta promotion).
- After the beta deploy step (push beta trigger): add `backup.sh beta` → `reflow.sh beta` → `verify-rehearsal.sh beta`. If verify fails → blocks stable promotion.
- **Stable does NOT get reflow'd** (it's the source — nothing to reflow into it).
- The existing `smoke.sh beta` stays; verify-rehearsal is additive.

### 4. Update deploy-skill (#111)
- Extract the deploy-flow (build→promote→reflow→verify→smoke) into the `ezagent-deploy` skill (referenced from `dev-together`). Include the reflow+verify step in the documented flow. This closes #111.

### 5. Reuse backup.sh
- `backup.sh <channel>` is called BEFORE reflow (rollback anchor). If reflow/verify fails, the operator can restore from the backup. Don't reinvent pg_dump.

## Verify (the goal)
- reflow.sh: full-data reflow works end-to-end (stable→nightly, stable→beta), no cred-protect, target boots + migrates + healthy.
- verify-rehearsal.sh: all 6 gates pass after a clean reflow; fails deliberately if you break something (test: skip a migration, verify-rehearsal should catch it).
- deploy.yml: the nightly + beta jobs include backup→reflow→verify steps; stable does not.
- `mix compile`, `mix ezagent.arch.scan`, `mix ezagent.check_invariants` green (the scripts are bash; the arch gate is about Elixir code, so no new violations expected).
- **socialware P10 E2E gate** still green (the reflow/verify scripts don't touch Elixir code).
- Known flakes note-only.

## Hand-back
Push `fix/reflow-phase1-full-data-rehearsal`; report:
1. reflow.sh: what was removed (cred-protect steps) + what stays.
2. verify-rehearsal.sh: the 6 gates + how each is implemented.
3. deploy.yml: the new steps + how failure blocks promotion.
4. deploy-skill: the extracted skill doc (or a stub if #111 is larger scope).
5. backup.sh reuse: where it's called.
6. Gate results + any OQ.
**STOP — do not merge, do not open a PR. Coordinator accepts + merges.**
