# Return: FP4 design system / brand UI migration

> **Task:** FP4 design system upgrade / shadcn brand-system migration
> **Branch:** `zyli/0629-ui-shadcn-handoffs`
> **PR:** https://github.com/ezagent42/ezagent/pull/1083
> **Dev:** zyli
> **returned_at:** 2026-06-29 16:02 +0800
> **deadline:** 2026-06-29 23:59 +0800
> **deadline_status:** on_time

## What is done

- Removed the daisyUI vendor layer from the touched web bundle surface.
- Migrated the touched operator shell, auth/error pages, socialware viewer, world island, and hello shell surfaces onto shadcn/Tailwind semantic tokens.
- Added the FP4 brand palette as shared `--ez-*` tokens:
  - `#D81830` red
  - `#0048A8` blue ink
  - `#FFD400` yellow
  - `#0B5CFF` cobalt
  - `#E8E8EB` page background
- Loaded the FP4 font stack on the touched surfaces:
  - Inter
  - Noto Sans SC
  - Noto Serif SC
  - Space Mono
- Fixed the World mobile shell and Sessions surface so mobile pages no longer create page-level horizontal overflow.
- Removed previously introduced nonessential/format-like changes from the PR, including `apps/ezagent_core/`, `router.ex`, `config.exs`, `ide_shell.ex`, and an unrelated 2026-06-26 return doc change.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | DS component/UI surfaces use shadcn/token classes rather than daisyUI component classes. | met | PR diff removes `apps/ezagent_web/assets/vendor/daisyui.js` and `apps/ezagent_web/assets/vendor/daisyui-theme.js`; touched components now use semantic token/Tailwind classes across web, socialware viewer, world, and hello. |
| 2 | Ezagent UI renders the brand palette `#D81830/#0048A8/#FFD400/#0B5CFF/#E8E8EB`. | met | Runtime token capture in `docs/together/2026-06-29/evidence/visual-fp4-brand/mobile-final-result.json`; token definitions in `apps/ezagent_web/assets/css/app.css`, `apps/ezagent_web/assets/css/viewer.css`, `apps/ezagent_plugin_world/assets/src/styles.css`, and `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/shell_css.ex`. |
| 3 | Font stack uses Inter + Noto Sans SC + Noto Serif SC + Space Mono on touched app surfaces. | met | Google Fonts links and CSS variables in `apps/ezagent_web/lib/ezagent_web/components/layouts/root.html.heex`, auth/error/denied pages, socialware controllers, and app/viewer/world/hello CSS. |
| 4 | User-facing visual pass covers operator shell and world sessions on desktop/mobile. | met | Evidence files: `desktop-admin.png`, `desktop-sessions.png`, `mobile-admin-final.png`, `mobile-sessions-final.png`, and `mobile-final-result.json` under `docs/together/2026-06-29/evidence/visual-fp4-brand/`. |
| 5 | Mobile pages have no page-level horizontal overflow. | met | `mobile-final-result.json` records `scrollWidth == clientWidth == 390` for both `sessions` and `admin`; `pageErrors: []`. |
| 6 | Local build/architecture gates pass for the touched work. | met | Ran `mix assets.build`, `mix compile --warnings-as-errors`, `mix ezagent.arch.scan`, `mix ezagent.check_invariants`, and `curl http://127.0.0.1:10042/_health -> 200`. |
| 7 | PR branch is rebased on current `main`. | met | `origin/main` and `git merge-base origin/main HEAD` both equal `755b2a9bf73214753e81b795dabb97f4bfaa6a6b`. |
| 8 | CI `precommit + check_invariants` is green on the PR head. | not-met | PR head `041f7ea57eaee935714b4d032cfab4cc5c117504`; CI run https://github.com/ezagent42/ezagent/actions/runs/28356923198 failed. Failure: `apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs:215` raises `Jason.Encoder` for PID from `EzagentPluginWorld.WorldLive.handle_params/3`. Lead should not merge until this is fixed and CI is green. |
| 9 | External design-system source upgrade from `/Users/h2oslabs/Workspace/ezagent-design/components` to shadcn, if considered part of this handoff. | deferred | This PR only changes the ezagent repo. The handoff wording mixed external DS-source upgrade with ezagent UI adaptation; lead should decide whether the external DS repo upgrade is a separate FP4 follow-up or required before closing FP4. |

**Method friction:** The FP4 handoff mixed two scopes: updating the external `ezagent-design` source and adapting ezagent app surfaces. The current branch completes the ezagent app adaptation, but the external design-system source path is outside this repo and should be split into a separate handoff or explicitly marked out-of-scope. Also, the machine gate caught a World host routing regression after visual/local targeted gates passed; future UI handoffs touching World should include `apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs` in the targeted verification list.

## Gate status

- Branch head: `041f7ea57eaee935714b4d032cfab4cc5c117504`
- Rebase base: `755b2a9bf73214753e81b795dabb97f4bfaa6a6b`
- PR: https://github.com/ezagent42/ezagent/pull/1083
- CI run: https://github.com/ezagent42/ezagent/actions/runs/28356923198
- CI status: failed
- Failed check: `precommit + check_invariants`
- Failure summary: `EzagentWeb.WorldHostRoutingTest` fails because `EzagentPluginWorld.WorldLive.handle_params/3` attempts to JSON-encode a PID in props.

## Deferred / open decisions

- Decide whether the external `/Users/h2oslabs/Workspace/ezagent-design` shadcn migration is part of this FP4 return or a separate follow-up.
- Fix the CI failure before merge.

## Merge request

Do not merge yet. The branch is ready for review as the FP4 app-surface implementation, but the machine return gate is red. Merge request becomes valid after the CI failure is fixed and `precommit + check_invariants` is green on PR head.
