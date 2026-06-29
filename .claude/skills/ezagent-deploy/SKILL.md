---
name: ezagent-deploy
description: Use when deploying or promoting ezagent through nightly, beta, or stable; changing deploy scripts/workflows; verifying migration rehearsals; or explaining the Mac self-hosted deployment flow.
---

# ezagent-deploy

Deploy flow for the three-channel Mac stack. The invariant is build once, promote the same artifact, then prove the promoted code can migrate a stable-shaped data copy before it moves outward.

## Channels

| Channel | Ref | Image tag | Trigger | Data role |
|---|---|---|---|---|
| nightly | main HEAD | `ezagent:nightly` | daily cron | rehearsal target |
| beta | `beta` branch | `ezagent:beta` | push `beta` | rehearsal target + smoke gate |
| stable | `release` branch | `ezagent:stable` | push `release` + GitHub Environment approval | stable is the source |

`beta` and `release` are deploy pointers, not task branches. Task branches merge to `main`; promotion advances pointers after gates pass.

## Promotion Flow

1. `main` passes CI and is picked up by the nightly schedule.
2. `docker/deploy.sh nightly` builds `ezagent:<sha>`, tags `ezagent:nightly`, starts nightly, and checks container health.
3. Nightly rehearsal runs:
   - `docker/backup.sh nightly`
   - `docker/reflow.sh nightly`
   - `docker/verify-rehearsal.sh nightly`
4. If nightly deploy or rehearsal fails, do not promote that SHA to beta.
5. Promote to beta with the existing pointer command from the deploy spec, then the workflow runs `docker/deploy.sh beta`.
6. Beta rehearsal runs:
   - `docker/backup.sh beta`
   - `docker/reflow.sh beta`
   - `docker/verify-rehearsal.sh beta`
7. Beta smoke then runs `docker/smoke.sh beta`.
8. If beta deploy, rehearsal, or smoke fails, do not promote that SHA to stable.
9. Promote to stable by advancing `release` and tagging the release. Stable is never reflowed because stable is the source.

## Reflow Contract

`docker/reflow.sh <nightly|beta>` is destructive by design. It replaces the target channel with stable's FULL data, including credentials, tokens, password hashes, message bodies, ConfigObjects, snapshots, and agent FS credentials. It does not scrub data and does not restore the target channel's old credentials.

The script must always reject `stable` as a target. Any change that reintroduces target credential protection, table-picking, or scrub logic contradicts the current Phase-1 lead decision.

## Verification Contract

`docker/verify-rehearsal.sh <nightly|beta>` blocks promotion on any failed gate:

1. Migration log clean: no migration/Ecto/Postgrex error signatures in the target container logs.
2. Row-count sanity: `users`, `entity_profiles`, `socialware_config_objects`, `kind_snapshots`, `messages`, and logical `sessions` match stable within `EZAGENT_REHEARSAL_ROW_TOLERANCE` (default `0`).
3. ConfigObject decode: sample `recipe` and `socialware` ConfigObjects exist and have JSON object bodies.
4. Schema version: target `schema_migrations` max version equals the latest release migration in `priv/repo_pg/migrations`.
5. Agent slice integrity: at least one agent snapshot decodes through the release runtime.
6. HTTP serve: target `/login` returns 200 through the channel admin port.

## Failure Policy

GitHub Actions failure is the promotion block. Do not paper over a rehearsal failure with a manual pointer push. Fix the migration/data issue, rerun the failed channel, and only promote from a green run.

If a backup, reflow, or verification command fails, preserve the logs and use the fresh `backup.sh` artifact as the rollback anchor. Do not merge a deploy-flow change that removes the backup-before-reflow step.

## Files

- `.github/workflows/deploy.yml` wires the nightly/beta post-deploy rehearsal and keeps stable excluded.
- `docker/deploy.sh` handles build/promote/start/health/rollback.
- `docker/backup.sh` creates the rollback anchor before destructive reflow.
- `docker/reflow.sh` copies stable FULL data into nightly/beta and runs target migrations.
- `docker/verify-rehearsal.sh` implements the six promotion-blocking gates.
- `docs/superpowers/specs/2026-06-25-deploy-flow-design.md` remains the topology/design source.
- `docs/together/2026-06-29/specs/cross-env-data-sync.md` records the migration rehearsal analysis and the Phase-1 override context.
