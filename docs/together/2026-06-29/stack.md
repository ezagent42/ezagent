# Dev Together Stack - 2026-06-29

planned_at: 2026-06-30 09:35 +0800
lead: allen
timezone: GMT+8

This stack reconciles the 2026-06-29 team PRs and returns after the fact. The
important accounting correction is that the day had 6 merged team PRs; Codex
worktree returns are support/verification artifacts, not owners.

## Team PR Reconciliation

| PR | branch | author | track | status | close outcome |
|---|---|---|---|---|---|
| #1083 `feat(ui): migrate handoff surfaces to shadcn brand system` | `zyli/0629-ui-shadcn-handoffs` | zyli | FP4 design system | merged | `a7ad4a66ed638e8fe285f151de4c2d44601c4cff`; DS/shadcn migration with visual evidence. |
| #1090 `feat(website): 官网 demo` | `docs/website-demo` | ruihua | FP6 website demo | merged | `2adb5685d4670a94383255955498c4398b8a8020`; docs/website-demo only, multi-page demo + mock API + world.cup. |
| #1095 `docs(fp2): refresh AutoService live verify after #1096` | `worktree-verify+autoservice-live` | gaga | FP2 AutoService verification | merged | `23320282478194263e207ed305660a551219cc80`; records current live verification state after #1096. |
| #1096 `Fix AutoService cc orchestrator materialization` | `fix/cc-agent-create-autoservice` | gaga | FP2 AutoService fix | merged | `72ae93a381d87943d2d41a04446483c8026fa7b0`; final design removed core local dispatch and initializes sandbox config at create time. |
| #1099 `feat(hello): render_card tool + fix main compile` | `feat/hello-render-card-tool` | zhaomato | hello / website substrate | merged | `cd8db2f98543dedbdaf4655bfcf67fc4a33436f6`; adds `render_card` and fixes #1097 compile regression. |
| #1100 `docs(spec): AI 开发治理机制 rule-gate` | `claude/musing-shtern-27c9a6` | FatNine | governance / rule-gate design | merged | `24a66628613a84b78da1e35d2e1b2021ff8cb631`; docs/spec only, no runtime change. |

## Related Support / Duplicate Items

| item | owner / author | state | decision |
|---|---|---|---|
| #1089 `fix(web): make world host scope config driven` | zyli | closed unmerged | Duplicate/superseded by the already merged #1086 line; do not count as one of the 6 merged team PRs. |
| `returns/autoservice-live-verify-codex.md` | agent support | evidence only | Useful independent verification evidence for #1095/#1096, but not a team PR owner row. |
| `returns/world-host-scope-config-driven.md` | agent support | deferred | Static gates passed, DB-backed gates need temporary PG rerun before PR/merge decision. |
| `returns/cc-agent-create-failure-resolution.md` | lead support for gaga #1096 | merged via #1096 | Records the redo rationale and verification for #1096; owner remains gaga. |

## Open PR Reconciliation

| PR | state on close pass | decision |
|---|---|---|
| #1027 `docs(qa): agent console findings` | open, docs-only QA report | Keep as intake source for 0630 Agent Console bugfix plan; close or refresh after fixes are scheduled. |
| #1026 `docs(together): 2026-06-26 team-PR intake` | open, stale lead-side analysis | Close after any still-relevant notes are copied into current stack/review. |
| #1022 `chore(world): lockfile sync + docs/rh` | open, mixed scope | Split or close. Lockfile sync must be rebased and verified separately from personal docs. |
| #1020 `feat(kanban): team dev flow` | open, large diff | Needs dedicated review/test track. Do not opportunistically merge during 0629 close. |

## Verification Notes

- #1096 was verified with a temporary PostgreSQL Docker container
  (`ezagent-pr1096-test-pg`, `POSTGRES_PORT=55433`) and the container was removed
  after tests.
- #1083 includes visual evidence under
  `docs/together/2026-06-29/evidence/visual-fp4-brand/`.
- #1090 was directory-isolated under `docs/website-demo/`.
- #1100 is docs/spec only.

## Main Outcome

Merged to `main` as the 0629 team close set:

```text
a7ad4a66 feat(ui): migrate handoff surfaces to shadcn brand system (#1083)
2adb5685 feat(website): 官网 demo (#1090)
23320282 docs(fp2): refresh AutoService live verify after #1096 (#1095)
72ae93a3 fix(autoservice): initialize cc sandbox at create time (#1096)
cd8db2f9 feat(hello): add render_card tool (#1099)
24a66628 docs(spec): add rule-gate design (#1100)
```
