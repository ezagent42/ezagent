> **Task:** plugin-ui-surface
> **Branch:** `codex/plugin-ui-self-declaration-1472`
> **PR:** https://github.com/ezagent42/ezagent/pull/1476
> **Dev:** codex / zyli line
> **returned_at:** 2026-07-20 14:58 +0800
> **deadline:** 2026-07-20 23:59 +0800
> **deadline_status:** deferred

## What's done

- Added strict plugin page/action/renderer declaration validation and runtime enumeration.
- Replaced the World-owned page/action registry truth source with plugin declarations.
- Replaced compile-time page state clauses with generic runtime lookup.
- Moved the board data/actions and React implementation into its plugin.
- Added build-time static renderer-manifest generation and wired the World entrypoint to it.
- Added focused declaration, registry, and manifest tests (26 tests, 0 failures locally).

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | UI declaration protocol covers page, action, nav, tab, and renderer metadata with fail-closed validation | deferred | Page/action/renderer validation is implemented and tested; nav/tab still use the earlier loose enumeration and need integration into the strict declaration diagnostic path. |
| 2 | World page/action registry dynamically enumerates registered plugin declarations | met | `Ezagent.World.PluginPageRegistry` and `plugin_page_registry_test.exs`. |
| 3 | World page state uses generic runtime routing | met | `EzagentPluginWorld.WorldLive.state_for_route/3` resolves through `PluginPageRegistry`. |
| 4 | Board and Hello implementation/special cases live in their plugins | deferred | Board files moved; `Conversation.tsx` and `ConversationActions` still contain session-specific branches, and Hello migration remains open. |
| 5 | Mix generates static renderer imports/manifest and React contains no plugin-specific renderer map | met | `Mix.Tasks.World.Renderers.Manifest`, checked-in generated manifest, and manifest tests. |
| 6 | Drift gate fails on an injected plugin name and finishes with an empty allowlist | not-met | Gate has not yet been implemented; lead decision: continue on this Draft PR before review. |
| 7 | Formatting, focused tests, frontend checks, and `mix precommit` are green | deferred | Focused backend tests: 26/26. Frontend build blocked locally by Node 20 vs pnpm requirement >=22.13. Full precommit not run because known compile warnings and remaining migration work make this checkpoint non-mergeable. |

**Method friction:** The handoff split World read-side and concrete plugin migration across two developer lines, but the implementation arrived as one branch. Session-tab data loading and rendering cross both ownership areas, so its declaration shape needed to be designed before either half could independently reach the machine return gate.

## Branch and gate status

- PR head: `da46e3f10742b3c939e403d0370f19e320f817a0`
- Rebase base: `fe290643133cf3f8e9de932236c5d64623748122` (`origin/main`)
- GitHub CI: no checks reported on the Draft PR head at return time.
- Local focused test: 26 tests, 0 failures.
- This return is a deferred checkpoint and is **not READY TO MERGE**.

## Open decisions / deferred follow-ups

1. Finish generic session-tab renderer/data-builder declarations and remove World session plugin branches.
2. Move the remaining Hello renderer/session behavior into the Hello plugin.
3. Add and prove the zero-allowlist World drift gate.
4. Regenerate slot manifests, remove compile warnings, run frontend checks under supported Node, then run `mix precommit` and invariant gates.

## Merge request

Keep PR #1476 as Draft and continue implementation on the same branch. Do not stack or merge until the deferred DoD lines and machine return gate are green.
