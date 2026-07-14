# Codex Handoff — cap-signing "no-tail" upgrade (re-provision-signed, not a backfill fix)

**Note:** `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md` (the real-canary-data finding + buckets).
**Repo:** esr-ng. **Target branch:** `feat/cap-signing-notail-upgrade` (you own it; land sub-steps; coordinator reviews + merges to `main`).
**Context:** Phase-4 signing is on main (dual-read). Goal (lead): a **no unsigned tail** state — every cap signed — then flip `require_signature:true`. Real-data E2E showed the existing `CapSigningBackfill` (EventLog re-auth) only signs 6/196 canary caps; it is **the wrong tool**. The right path is **re-authorizing caps through the signing `Cap.issue`**.

## Constraints (lead-locked)

1. **No caps_json SSOT rewrite of the schema.** signature/key_id/grantee_uri live inside the existing `caps_json` JSON — no new columns (confirmed: Phase-4 migration is "already up" on canary).
2. **Do NOT flip `require_signature:true` until an audit proves 0 unsigned authorizer caps** on the target.
3. **The `CapSigningBackfill` EventLog path is not the upgrade mechanism** — do not try to make it reconcile the 74 malformed / 30 missing events. Retire or bypass it.
4. Each sub-step: full `mix ci.local` green + rebased on main before self-merge. Elixir via editor; `MIX_TEST_PARTITION` for parallel tests.

## Sub-step 1 — per-class audit: does each cap class self-sign on re-derivation?

For each cap-producing path, determine whether the cap goes through the **signing `Cap.issue/3`** on its normal lifecycle (activation / materialization / grant), or is constructed directly (bypassing signing):
- user go-live provisioning (`Users.create` → caps_json)
- agent structural caps (`Identity.create/1` — Sandbox / ConfigEvolve / Identity / Manage / Template / Terminable)
- recipe caps (`recipe_cap_binding` → activation replay)
- session / socialware-materialized caps
- genesis / admin (`admin_genesis_cap`)

**Output:** a table `{class → self-signs-on-rederive? yes/no + the issue site or the bypass site}`. This decides which classes self-heal (re-activate) vs need an explicit re-issue. **Verify against code — do not assume** (the coordinator's hypothesis that agent-structural self-heals is UNconfirmed).

## Sub-step 2 — re-issue-signed for the STORED classes (at least user caps_json)

For classes that do NOT self-sign on re-derivation (confirmed at least `users.caps_json`, 99 caps on canary): an idempotent operation that, per holder, **re-issues each currently-held authorizer cap through the signing `Cap.issue`** (preserving identity/scope/owner per #154) and **rewrites the durable store** (caps_json) with the signed artifacts. Skip declared/needed sentinels. A cap whose owner/authority can't be resolved → **quarantine + report, not blind-sign** (same safety as the backfill). Provide it as a `mix` task / ops fn, NOT auto-run.

## Sub-step 3 — self-healing classes: verify + (if needed) fix the issue site

For classes sub-step-1 finds DON'T self-sign but SHOULD (e.g. a structural cap constructed directly instead of via `Cap.issue`): route them through the signing issue path so re-activation produces signed caps. If a class already self-signs, no code — document "re-activate to upgrade."

## Sub-step 4 — audit + runbook

- An **audit** (`mix` task): scan every entity's held caps, count unsigned authorizer caps by class → the go/no-go for enforce (`require_signature:true`). Reuse it as the acceptance gate.
- A **runbook** (`docs/guide/`): the no-tail upgrade procedure — (1) seed present; (2) re-activate/re-materialize self-healing classes; (3) run the sub-step-2 re-issue for stored classes; (4) genesis signed; (5) audit → 0 unsigned → flip enforce. Coordinator runs it on canary; prod is separate lead ops.

## Verification
Re-run against the isolated canary-data env (coordinator can re-provide the DB dump): after the upgrade pass, the audit reports **0 unsigned authorizer caps**, and `require_signature:true` denies nothing legitimate.

## Grounding
`CapSigningBackfill` (the wrong tool) `apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex` · `Cap.issue/verify` `cap.ex:33,51` · `activate/2` reads caps_json as-is `behavior/identity.ex:288-345` · `Users.create`/caps_json `users.ex:81-120` · `Identity.create` structural caps `behavior/identity.ex:142-260` · recipe binding `recipe_cap_binding.ex` · genesis `entity/user.ex:81-100`. Finding note: `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md`.
