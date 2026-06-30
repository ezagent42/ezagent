# Dev Together Review - 2026-06-29

reviewed_at: 2026-06-30 09:45 +0800
lead: allen
timezone: GMT+8

## 1. Close Summary

2026-06-29 的团队 close 结果是 6 个非 Allen 团队 PR 合入 main：

| PR | author | track | merge SHA |
|---|---|---|---|
| #1083 | zyli | FP4 design system / shadcn brand migration | `a7ad4a66ed638e8fe285f151de4c2d44601c4cff` |
| #1090 | ruihua | FP6 official website demo / world.cup / mock API | `2adb5685d4670a94383255955498c4398b8a8020` |
| #1095 | gaga | FP2 AutoService live verification report | `23320282478194263e207ed305660a551219cc80` |
| #1096 | gaga | FP2 AutoService cc orchestrator materialization fix | `72ae93a381d87943d2d41a04446483c8026fa7b0` |
| #1099 | zhaomato | hello `render_card` tool + main compile fix | `cd8db2f98543dedbdaf4655bfcf67fc4a33436f6` |
| #1100 | FatNine | AI development rule-gate design spec | `24a66628613a84b78da1e35d2e1b2021ff8cb631` |

Codex/Claude entries in the returns folder are verification/support artifacts,
not team PR owners. The review and stack should attribute ownership to the
human/team PR authors above.

## 2. Product / Architecture Notes

- Website: #1090 delivered the FP6 demo in `docs/website-demo/`, including the
  multi-page site, mock ezagent API, team data, and world.cup interaction model.
- Design system: #1083 migrated touched handoff/world/viewer/hello surfaces to
  shadcn/Tailwind semantic tokens and attached visual evidence.
- AutoService: #1095 recorded the live verification state; #1096 fixed the cc
  orchestrator materialization path by moving sandbox config into Agent create
  state. The final #1096 merge has no `apps/ezagent_core/lib/ezagent/invocation.ex`
  change and does not keep `dispatch_registered_local`.
- Hello: #1099 added the producer-free `render_card` tool and fixed the main
  compile regression introduced by #1097 helper placement.
- Governance: #1100 added the rule-gate design spec for AI development layer
  selection. It is docs/spec only, no core/domain runtime change.

## 3. What Went Well

- The six team PRs cover the intended 0629 spread: DS, website, AutoService
  verification/fix, hello substrate, and AI-development governance.
- The suspected #1096 core leak was caught before merge. The accepted solution
  keeps normal `Identity.Grant` + `Invocation.dispatch/1` and moves the specific
  state into create-time agent materialization.
- #1099 surfaced and fixed a broken-main compile issue quickly instead of
  leaving the hello task blocked by unrelated main state.
- #1100 kept rule-gate as a design/spec PR rather than sneaking enforcement into
  core before review.

## 4. Friction / Process Debt

- The 0629 return/stack ledger was reconstructed after the fact and initially
  undercounted the day by only listing Codex-handled close work. Future close
  must start from GitHub PR state plus forwarded PRs, not from the agent's local
  work queue.
- Owner attribution must be human/team PR authors. Agent verification artifacts
  can be recorded as support evidence, but not as `owner`.
- `team.md` still points several developers at old latest returns. Today's plan
  should cite current PR state and update team state at the next review.
- Local default PG on 55432 is corrupt. Durable test rule remains: use temporary
  PostgreSQL Docker for tests and delete it after the run.

## 5. Carry Forward To 2026-06-30

1. Run the remaining AutoService real answer-loop verification after Claude Code
   auth/bridge readiness is available. #1095 records state and #1096 fixes
   materialization, but no agent-authored reply is proven yet.
2. Turn #1027 Agent Console QA findings into prioritized bugfix tasks instead of
   leaving the report as an open stale docs PR.
3. Rerun `world-host-scope-config-driven` DB-backed gates with temporary PG and
   decide whether to open/merge a PR.
4. Review #1020 as a dedicated kanban/dev-together E2E track. It is too large for
   opportunistic close.
5. Decide #1026/#1022 stale PR cleanup after extracting any useful notes.
