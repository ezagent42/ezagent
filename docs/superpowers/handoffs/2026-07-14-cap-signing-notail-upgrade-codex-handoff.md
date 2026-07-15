# Codex Handoff — cap-signing "no-tail" upgrade (re-provision-signed, not a backfill fix)

**Note:** `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md` (the real-canary-data finding + buckets).
**Repo:** esr-ng. **Target branch:** `feat/cap-signing-notail-upgrade` (you own it; land sub-steps; coordinator reviews + merges to `main`).
**Context:** Phase-4 signing is on main (dual-read). Goal (lead): a **no unsigned tail** state — every cap signed — then flip `require_signature:true`. Real-data E2E showed the existing `CapSigningBackfill` (EventLog re-auth) only signs 6/196 canary caps; it is **the wrong tool**. The right path is **re-authorizing caps through the signing `Cap.issue`**.

## Constraints (lead-locked)

1. **No caps_json SSOT rewrite of the schema.** signature/key_id/grantee_uri live inside the existing `caps_json` JSON — no new columns (confirmed: Phase-4 migration is "already up" on canary).
2. **Do NOT flip `require_signature:true` until an audit proves 0 unsigned authorizer caps** on the target.
3. **The `CapSigningBackfill` EventLog path is not the upgrade mechanism** — do not try to make it reconcile the 74 malformed / 30 missing events. Retire or bypass it.
4. Each sub-step: full `mix ci.local` green + rebased on main before self-merge. Elixir via editor; `MIX_TEST_PARTITION` for parallel tests.

## Sub-step 1 — EMPIRICAL differential test: which cap classes bypass the signing issue?

**Do this empirically, NOT by reading code** (lead's method, and better — real behavior beats hypothesis). In the isolated env (below), with signing on: exercise each cap class through its **normal re-derivation path** (agent/session re-activation & materialization; user grant/seed), then **audit which held caps come out UNSIGNED**. An unsigned cap after a re-issue/re-activation **is** a path that constructs the cap directly instead of via `Cap.issue`. Cover: user go-live provisioning (`Users.create`→caps_json), agent structural (`Identity.create/1` — Sandbox/ConfigEvolve/Identity/Manage/Template/Terminable), recipe (`recipe_cap_binding`→activation replay), session/socialware-materialized, genesis/admin (`admin_genesis_cap`).

**Output:** `{class → signs-on-normal-rederive? yes/no + the bypass site if no}`, from the empirical audit (not code-reading).

**⚠ Must root-cause this specific signal (coordinator's ad-hoc harness, UNCONFIRMED):** calling low-level `Ezagent.Cap.Signing.sign/2` on **wildcard user caps** (`behavior`/`action`/`instance` = `:any`, e.g. the admin full-wildcard cap) threw **`ArgumentError` (13/13 sampled)**. The harness was unclean (it booted the app; user-cap count 13 ≠ the dry-run's 99), so this may be a harness artifact OR a real edge. **With a clean setup, determine: can a fully-wildcard cap be signed via `Cap.issue` / `Signing.sign`?** The admin wildcard cap **MUST** be signable (or given a genesis exemption) — a no-tail enforce depends on it. Report the root cause.

## Sub-step 2 — re-issue-signed for the STORED classes (at least user caps_json)

For classes that do NOT self-sign on re-derivation (confirmed at least `users.caps_json`, 99 caps on canary): an idempotent operation that, per holder, **re-issues each currently-held authorizer cap through the signing `Cap.issue`** (preserving identity/scope/owner per #154) and **rewrites the durable store** (caps_json) with the signed artifacts. Skip declared/needed sentinels. A cap whose owner/authority can't be resolved → **quarantine + report, not blind-sign** (same safety as the backfill). Provide it as a `mix` task / ops fn, NOT auto-run.

## Sub-step 3 — self-healing classes: verify + (if needed) fix the issue site

For classes sub-step-1 finds DON'T self-sign but SHOULD (e.g. a structural cap constructed directly instead of via `Cap.issue`): route them through the signing issue path so re-activation produces signed caps. If a class already self-signs, no code — document "re-activate to upgrade."

## Sub-step 4 — audit + runbook

- An **audit** (`mix` task): scan every entity's held caps, count unsigned authorizer caps by class → the go/no-go for enforce (`require_signature:true`). Reuse it as the acceptance gate.
- A **runbook** (`docs/guide/`): the no-tail upgrade procedure — (1) seed present; (2) re-activate/re-materialize self-healing classes; (3) run the sub-step-2 re-issue for stored classes; (4) genesis signed; (5) audit → 0 unsigned → flip enforce. Coordinator runs it on canary; prod is separate lead ops.

## Isolated E2E environment — how to run against real canary data (NEVER touch live stacks)

Reproduce the coordinator's setup on this host. **NEVER** use the live `canary`/`beta`/`stable` (ezagent-deploy docker-compose channels) or `dev`(:10042)/`prod`(:10043) — read-only backups only; **never `reflow.sh`** (destructive).

1. **Canary data dump** (already exists, real data, 7 users): `/Users/h2oslabs/Workspace/ezagent-deploy/backups/canary/20260713T200002Z/db.sql.gz`. To refresh: `cd ~/Workspace/ezagent-deploy && docker/backup.sh canary` (read-only `pg_dump` on live canary — safe).
2. **Throwaway Postgres** (a restored instance may already be up as container `p4-canary-e2e-pg` on `:55450`, db `ezagent_e2e`). To (re)create:
   ```bash
   docker run -d --name p4-canary-e2e-pg -e POSTGRES_USER=ezagent -e POSTGRES_PASSWORD=ezagent -p 55450:5432 postgres:16
   docker exec p4-canary-e2e-pg psql -U ezagent -d postgres -c "CREATE DATABASE ezagent_e2e;"
   gzcat ~/Workspace/ezagent-deploy/backups/canary/20260713T200002Z/db.sql.gz | docker exec -i p4-canary-e2e-pg psql -U ezagent -d ezagent_e2e -q
   ```
3. **Run Phase-4 code against it** from a worktree on this branch/main:
   ```bash
   export MIX_ENV=dev POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55450 POSTGRES_DB=ezagent_e2e \
          POSTGRES_USER=ezagent POSTGRES_PASSWORD=ezagent \
          EZAGENT_SIGNING_SEED_V1="<a ≥32-byte string>"    # runtime_seed needs ≥ @hash_size (32) bytes
   export NO_PROXY=127.0.0.1,localhost
   mix ecto.migrate     # expect "already up" — Phase-4 adds NO columns (signature lives in caps_json JSON)
   mix ezagent.caps.signing_audit --strict   # independent four-source signing audit
   ```
   Note: `mix run` scripts may boot the app (activation writes snapshots to the throwaway DB — fine, it's disposable). Prefer a proper ExUnit test with a sandbox for the empirical audit to avoid boot side-effects (the coordinator's ad-hoc `mix run` harness was unclean — write it as a test).

## Verification
Re-run against the isolated canary-data env: after the upgrade pass, the audit reports **0 unsigned authorizer caps**, and `require_signature:true` denies nothing legitimate. **Return results to the coordinator** (dry-run counts, the per-class bypass table, the wildcard root-cause).

## Grounding
`CapSigningBackfill` (the wrong tool) `apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex` · `Cap.issue/verify` `cap.ex:33,51` · `activate/2` reads caps_json as-is `behavior/identity.ex:288-345` · `Users.create`/caps_json `users.ex:81-120` · `Identity.create` structural caps `behavior/identity.ex:142-260` · recipe binding `recipe_cap_binding.ex` · genesis `entity/user.ex:81-100`. Finding note: `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md`.
