# Dev Together Stack - 2026-06-29

planned_at: 2026-06-30 09:35 +0800
lead: allen / codex
timezone: GMT+8

This stack reconciles the 2026-06-29 returns folder after the fact. The day had
returns but no `stack.md`; this file is the close ledger so merged, deferred,
and stale PR states are explicit.

## Return Reconciliation

| return | branch / PR | owner | status | close outcome |
|---|---|---|---|---|
| `returns/cc-agent-create-failure-resolution.md` | `fix/cc-agent-create-autoservice`, #1096 | gaga + codex lead redo | stacked -> merged | Rebased on `origin/main`, removed the core `dispatch_registered_local` approach, switched to create-time sandbox init, ran full local `mix precommit` against temporary PG, CI green, squash-merged as `72ae93a381d87943d2d41a04446483c8026fa7b0`. |
| `returns/autoservice-live-verify-codex.md` | verify worktree, evidence only; related #1095 | codex | stacked -> merged as refreshed docs | The live create blocker is fixed by #1096. #1095 was rebased after #1096, refreshed to remove the stale local-dispatch conclusion, CI-green, and squash-merged as `23320282478194263e207ed305660a551219cc80`. Remaining live issues are separate: Claude auth/bridge readiness, `Unsupported node: container`, pnpm Vite shim, anonymous channel write semantics. |
| `returns/world-host-scope-config-driven.md` | `fix/world-host-scope-config-driven`, no PR | codex | deferred | Static gates passed, DB-backed gates were blocked in the return environment. Needs rerun with temporary PG Docker and then PR/merge decision. |
| `returns/zyli-fp4-design-system.md` | `zyli/0629-ui-shadcn-handoffs`, #1083 | zyli | merged before this close ledger | #1083 is already on `main` before this ledger (`a7ad4a66 feat(ui): migrate handoff surfaces to shadcn brand system`). Residual external DS-source question remains a follow-up, not a blocker for the app-surface merge. |

## Open PR Reconciliation

| PR | state on 2026-06-30 close pass | decision |
|---|---|---|
| #1096 `fix/cc-agent-create-autoservice` | CI green, mergeable | Merged: `72ae93a381d87943d2d41a04446483c8026fa7b0`. |
| #1095 `docs(fp2): refresh AutoService live verify after #1096` | refreshed after #1096, CI green | Merged: `23320282478194263e207ed305660a551219cc80`. |
| #1027 `docs(qa): agent console findings` | open, mergeable=false, docs-only QA report | Keep as intake source for today's Agent Console bugfix plan; close or refresh after fixes are scheduled. |
| #1026 `docs(together): 2026-06-26 team-PR intake` | open, mergeable=false, stale lead-side analysis | Close after any still-relevant notes are copied into current stack/review. |
| #1022 `chore(world): lockfile sync + docs/rh` | open, mergeable=false, 39 files / lockfile + personal docs | Split or close. Lockfile sync must be rebased and verified separately from personal docs. |
| #1020 `feat(kanban): team dev flow` | open, mergeable=true, 209 files / 13k LOC | Needs dedicated review/test track. Do not opportunistically merge during 0629 close. |

## Verification Recorded For #1096

- Local temporary PG: Docker container `ezagent-pr1096-test-pg`, `POSTGRES_PORT=55433`; stopped and removed after tests.
- `MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps mix compile --warnings-as-errors` passed.
- Targeted sandbox/identity/AutoService/cc/grant suites passed.
- Full local `MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps POSTGRES_PORT=55433 mix precommit` passed.
- GitHub checks passed:
  - `Only repo owner may edit dev-together skill`
  - `Return file advisory`
  - `precommit + check_invariants`

## Main Outcome

Merged to `main`:

```text
72ae93a381d87943d2d41a04446483c8026fa7b0 fix(autoservice): initialize cc sandbox at create time (#1096)
```
