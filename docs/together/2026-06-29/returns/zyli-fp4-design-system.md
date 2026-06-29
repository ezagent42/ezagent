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
- Added the World React-island navigation bridge: same-origin World links are intercepted in the island, sent as `world:navigate`, validated in `WorldLive`, and applied with `push_patch` so internal navigation does not trigger browser full-page reloads.
- Follow-up fix `d1dd406270992a9c3d5512675f882c04a81db64c` removes stdlib `URI.parse/1` from the World navigation validation path so the URI canonicalization invariant stays green.
- Follow-up fix `71efe1b93db86b3f63a9a0eb7b0c2d51cce4eb9d` fixes opening an existing session from the Sessions table: the `Open` button now provisions owner-rooted join authority for existing members before dispatching `session.join`, then patches to the conversation detail route.
- Removed previously introduced nonessential/format-like changes from the PR, including `apps/ezagent_core/`, `router.ex`, `config.exs`, `ide_shell.ex`, and an unrelated 2026-06-26 return doc change.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | DS component/UI surfaces use shadcn/token classes rather than daisyUI component classes. | met | PR diff removes `apps/ezagent_web/assets/vendor/daisyui.js` and `apps/ezagent_web/assets/vendor/daisyui-theme.js`; touched components now use semantic token/Tailwind classes across web, socialware viewer, world, and hello. |
| 2 | Ezagent UI renders the brand palette `#D81830/#0048A8/#FFD400/#0B5CFF/#E8E8EB`. | met | Runtime token capture in `docs/together/2026-06-29/evidence/visual-fp4-brand/mobile-final-result.json`; token definitions in `apps/ezagent_web/assets/css/app.css`, `apps/ezagent_web/assets/css/viewer.css`, `apps/ezagent_plugin_world/assets/src/styles.css`, and `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/shell_css.ex`. |
| 3 | Font stack uses Inter + Noto Sans SC + Noto Serif SC + Space Mono on touched app surfaces. | met | Google Fonts links and CSS variables in `apps/ezagent_web/lib/ezagent_web/components/layouts/root.html.heex`, auth/error/denied pages, socialware controllers, and app/viewer/world/hello CSS. |
| 4 | User-facing visual pass covers operator shell and world sessions on desktop/mobile. | met | Evidence files: `desktop-admin.png`, `desktop-sessions.png`, `mobile-admin-final.png`, `mobile-sessions-final.png`, and `mobile-final-result.json` under `docs/together/2026-06-29/evidence/visual-fp4-brand/`. |
| 5 | Mobile pages have no page-level horizontal overflow. | met | `mobile-final-result.json` records `scrollWidth == clientWidth == 390` for both `sessions` and `admin`; `pageErrors: []`. |
| 6 | Local build/architecture gates pass for the touched work. | met | Original FP4 gates passed: `mix assets.build`, `mix compile --warnings-as-errors`, `mix ezagent.arch.scan`, `mix ezagent.check_invariants`, and `curl http://127.0.0.1:10042/_health -> 200`. Navigation follow-up verification also passed locally: `node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs`, `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/assets/world_navigation_test.exs`, `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/invariants/uri_canonicalization_invariant_test.exs`, and `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs --trace` (14 tests, 0 failures after `71efe1b9`). |
| 7 | PR branch is rebased on current `main`. | met | `origin/main` and `git merge-base origin/main HEAD` both equal `fbe4caf8dba65c945448919ffd961b42b9f31c3d` at the navigation follow-up update. |
| 8 | CI `precommit + check_invariants` is green on the PR head. | not-met | Implementation head `71efe1b93db86b3f63a9a0eb7b0c2d51cce4eb9d` fixes the World navigation URI parser gate and existing-member session-open regression locally. Latest observed GitHub CI before this return-doc update was https://github.com/ezagent42/ezagent/actions/runs/28363802856/job/84024599620 on older PR head `af80077bc581693402097be556ec6f7a96704703`; it failed on `URI.parse/1` in `WorldLive` plus two `PluginIsolationWorkspaceTest` failures. Local `POSTGRES_PORT=5432 mix precommit` was attempted after `50c000a6` but failed on unrelated environment/baseline issues (`pg_dump` missing, DB schema workspace_uri checks, scanner timeouts, TTL boundary); lead should wait for post-push CI on the latest PR head. |
| 9 | External design-system source upgrade from `/Users/h2oslabs/Workspace/ezagent-design/components` to shadcn, if considered part of this handoff. | deferred | This PR only changes the ezagent repo. The handoff wording mixed external DS-source upgrade with ezagent UI adaptation; lead should decide whether the external DS repo upgrade is a separate FP4 follow-up or required before closing FP4. |

**Method friction:** The FP4 handoff mixed two scopes: updating the external `ezagent-design` source and adapting ezagent app surfaces. The current branch completes the ezagent app adaptation, but the external design-system source path is outside this repo and should be split into a separate handoff or explicitly marked out-of-scope. Also, the machine gate caught World-specific regressions after visual/local targeted gates passed; future UI handoffs touching World should include `apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs` and `apps/ezagent_core/test/invariants/uri_canonicalization_invariant_test.exs` in the targeted verification list.

## Post-return update -- World navigation reload fix

- **updated_at:** 2026-06-29 18:35 +0800
- **Implementation commits:** `af80077bc581693402097be556ec6f7a96704703` adds the React island -> LiveView `world:navigate` bridge; `d1dd406270992a9c3d5512675f882c04a81db64c` removes stdlib `URI.parse/1` from the server-side path validation; `71efe1b93db86b3f63a9a0eb7b0c2d51cce4eb9d` fixes existing-member session opens from the Sessions table.
- **Behavior:** internal same-origin World links now patch through LiveView (`push_patch`) instead of causing a browser full-page reload; external links, downloads, new-tab clicks, fragments, absolute URLs, and non-World paths remain native/no-op. The Sessions table `Open` button now also follows the trusted access-point join flow: owner-rooted JIT join cap provision -> `session.join` dispatch -> participation cap mount -> `/sessions?session=...` patch.
- **Root cause of session-detail click failure:** `SessionsTable` used a button path (`onJoin` -> `world:dispatch` action `sessions.join`), not the `<a>` navigation bridge. `WorldLive.dispatch_session_join/2` dispatched `session.join` without calling `Membership.provision_join_authority/2`, so an already-member user whose login state did not preload a concrete join cap received `:unauthorized` and no `push_patch` happened.
- **Local verification:** `node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs` passed; `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/assets/world_navigation_test.exs` passed; `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/invariants/uri_canonicalization_invariant_test.exs` passed; `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs:105 --trace` passed; `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs --trace` passed with 14 tests, 0 failures.
- **CI status:** old CI on `af80077bc581693402097be556ec6f7a96704703` is red; new CI must rerun after pushing this return update and the `71efe1b9` fix.

## Gate status

- Implementation head: `71efe1b93db86b3f63a9a0eb7b0c2d51cce4eb9d`
- Rebase base: `fbe4caf8dba65c945448919ffd961b42b9f31c3d`
- PR: https://github.com/ezagent42/ezagent/pull/1083
- Latest observed CI run: https://github.com/ezagent42/ezagent/actions/runs/28363802856/job/84024599620
- Latest observed CI status: failed on older PR head `af80077bc581693402097be556ec6f7a96704703`
- Failed check: `precommit + check_invariants`
- Failure summary: the previous WorldLive PID JSON failure is fixed; the next observed failure was stdlib `URI.parse/1` in `WorldLive` (fixed locally by `d1dd4062`) plus two `Ezagent.Integration.PluginIsolationWorkspaceTest` failures in the CI merge ref. Local precommit also fails in this host on unrelated environment/baseline issues (`pg_dump` missing, DB schema workspace_uri checks, scanner timeouts, TTL boundary). Latest PR CI must be rechecked after push.

## Deferred / open decisions

- Decide whether the external `/Users/h2oslabs/Workspace/ezagent-design` shadcn migration is part of this FP4 return or a separate follow-up.
- Wait for the new PR CI run after the navigation follow-up push. If `PluginIsolationWorkspaceTest` remains red after the World URI parser fix, decide whether it is base/test flake or a required follow-up before merging.

## Merge request

Do not merge yet. The branch is ready for review as the FP4 app-surface implementation plus World navigation reload fix, but the machine return gate must be green on the latest PR head before merge.
