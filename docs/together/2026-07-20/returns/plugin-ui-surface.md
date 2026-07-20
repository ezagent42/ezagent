> **Task:** plugin-ui-surface
> **Branch:** `codex/plugin-ui-self-declaration-1472`
> **PR:** https://github.com/ezagent42/ezagent/pull/1476
> **Dev:** codex / zyli line
> **returned_at:** 2026-07-20 16:05 +0800
> **deadline:** 2026-07-20 23:59 +0800
> **deadline_status:** deferred

## What's done

- Added strict plugin page/action/renderer declaration validation and runtime enumeration.
- Replaced the World-owned page/action registry truth source with plugin declarations.
- Replaced compile-time page state clauses with generic runtime lookup.
- Moved the board data/actions and React implementation into its plugin.
- Added build-time static renderer-manifest generation and wired the World entrypoint to it.
- Added focused declaration, registry, and manifest tests (26 tests, 0 failures locally).
- Fixed the Template builder to enumerate registered agent flavors as required
  selects instead of accepting free-form flavor text.
- Added visible and semantic required-field markers for template name, fresh-agent
  flavor, and reused-agent selection.
- Changed successful template creation to return to `/workspaces` and browser-proved
  the Kanban selection, default `cc-headless` flavors, save, and redirect flow.
- Made Bindings a true in-session view: the tab and session-tools entry dispatch
  `session.view.switch`, the backend returns the current session's bindings, and
  React renders the existing External Mirror form inside the Conversation island.
  The `/sessions?session=...` URL and surrounding shell remain mounted.
- Removed the redundant Routing shortcut beside Bindings in the session header;
  routing management remains available from the members panel.
- Made Bindings the only navigation entry for session external-mirror bindings by
  removing the duplicate legacy shortcut from both the session tools menu and the
  sessions detail actions. The underlying actions and compatibility route remain.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | UI declaration protocol covers page, action, nav, tab, and renderer metadata with fail-closed validation | deferred | Page/action/renderer validation is implemented and tested; nav/tab still use the earlier loose enumeration and need integration into the strict declaration diagnostic path. |
| 2 | World page/action registry dynamically enumerates registered plugin declarations | met | `Ezagent.World.PluginPageRegistry` and `plugin_page_registry_test.exs`. |
| 3 | World page state uses generic runtime routing | met | `EzagentPluginWorld.WorldLive.state_for_route/3` resolves through `PluginPageRegistry`. |
| 4 | Board and Hello implementation/special cases live in their plugins | deferred | Board files moved; `Conversation.tsx` and `ConversationActions` still contain session-specific branches, and Hello migration remains open. |
| 5 | Mix generates static renderer imports/manifest and React contains no plugin-specific renderer map | met | `Mix.Tasks.World.Renderers.Manifest`, checked-in generated manifest, and manifest tests. |
| 6 | Drift gate fails on an injected plugin name and finishes with an empty allowlist | not-met | Gate has not yet been implemented; lead decision: continue on this Draft PR before review. |
| 7 | Formatting, focused tests, frontend checks, and `mix precommit` are green | deferred | Focused backend tests: 26/26 architecture tests plus 8/8 template-form tests. Frontend lint, typecheck, build, and 29/29 unit tests pass using the repository-compatible pnpm 10.20.0. Browser canary passes. `mix precommit` was run and fails at warnings-as-errors on the already-deferred World session-specific Kanban references and `state_for_route/3` clause grouping. |

**Method friction:** The handoff split World read-side and concrete plugin migration across two developer lines, but the implementation arrived as one branch. Session-tab data loading and rendering cross both ownership areas, so its declaration shape needed to be designed before either half could independently reach the machine return gate.

## Branch and gate status

- Implementation head: `5f5a968d1` (duplicate External Mirror links removed)
- Rebase base: `fe290643133cf3f8e9de932236c5d64623748122` (`origin/main`)
- GitHub CI: frontend regression gate, return advisory, skill ownership gate, and
  gitleaks are green; deterministic gate is pending at update time:
  https://github.com/ezagent42/ezagent/actions/runs/29725114841
- Local focused tests: 26/26 architecture tests, 8/8 template-form backend tests,
  and 31/31 frontend tests.
- Local frontend gates: lint, typecheck, and Vite production build pass.
- Browser canary: Kanban exposes two required flavor selects populated from the
  runtime registry, defaults both to `cc-headless`, and a successful save navigates
  to `/workspaces` with no browser errors.
- Browser canary: clicking a session's Bindings tab keeps the exact
  `/sessions?session=...` URL, preserves the session rail/shell, and locally renders
  the External Mirror form without browser errors. The session header exposes only
  Conversation and Bindings (no Routing shortcut); routing remains in the members
  panel. Conversation/navigation backend tests pass 21/21 and frontend tests pass
  31/31.
- Browser canary: the sessions detail actions contain only Open, and the session
  tools menu contains Restart agent runner and Debug info with no External Mirror
  shortcut. Bindings still renders the form in place. Frontend tests pass 33/33.
- Local `mix precommit`: failed at compile warnings-as-errors on the deferred
  session-specific World/Kanban references and existing `state_for_route/3`
  grouping warning.
- This return is a deferred checkpoint and is **not READY TO MERGE**.

## Open decisions / deferred follow-ups

1. Finish generic session-tab renderer/data-builder declarations and remove World session plugin branches.
2. Move the remaining Hello renderer/session behavior into the Hello plugin.
3. Add and prove the zero-allowlist World drift gate.
4. Regenerate slot manifests, remove compile warnings, run frontend checks under supported Node, then run `mix precommit` and invariant gates.

## Merge request

Keep PR #1476 as Draft and continue implementation on the same branch. Do not stack or merge until the deferred DoD lines and machine return gate are green.
