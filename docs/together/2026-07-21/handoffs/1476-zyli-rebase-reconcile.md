# Handoff → zyli: #1476 needs a rebase + ONE semantic reconcile (2026-07-21)

**What lead found:** I rebased your `codex/plugin-ui-self-declaration-1472` (#1476) onto latest `main` to try to land it (you said it was ready). The rebase is **text-clean (zero git conflicts)**, but it does NOT compile — there's ONE **semantic** conflict the text-merge can't see, and it's yours to resolve because it's your de-hardcoding architecture. I did **not** force-push a broken rebase; your PR branch is untouched.

## The conflict
While you were on your branch, `main` added a new function **`view_switch_updates/3`** in `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:570` that does:

```elixir
|> Map.merge(EzagentPluginKanban.WorldData.board_state(board_uri, ctx))
```

That's a **direct cross-plugin call from `ezagent_plugin_world` into `EzagentPluginKanban`** — exactly the hardcoding your PR removes. After the rebase, `world` no longer compile-depends on `kanban` (your whole point: Kanban self-declares via the plugin surface), so this call fails:

```
warning: EzagentPluginKanban.WorldData.board_state/2 is undefined
(module EzagentPluginKanban.WorldData is not available or is yet to be defined)
Compilation failed due to warnings while using the --warnings-as-errors option
```

`board_state/2` still EXISTS (in `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_data.ex:193`) — the problem is purely that `world` isn't allowed to reach into `kanban` directly anymore under your new layering.

## What we need from you
1. **Rebase `codex/plugin-ui-self-declaration-1472` onto latest `main`** yourself (it's 38+ commits behind; the read-plane epic + #1477 landed under you).
2. **Re-plumb `view_switch_updates/3`** so it gets the board state **through your new plugin-declared surface** (the dynamic renderer / world-state provider mechanism #1476 introduces) instead of the direct `EzagentPluginKanban.WorldData.board_state` call — i.e. fold main's `view_switch_updates` into your de-hardcoded model. You know the surface API; a wrong guess by me would defeat the layering.
3. `mix compile --warnings-as-errors` clean + your frontend 33/33 + `gate` green → then it's mergeable.

## Context / good news
- **#1477 (`fix/g5-cap-reconciliation`) is already rebased + merged to main by lead** (it was clean). That's the presenter-cap fix that unblocked ruihua's G5 E2E.
- **Heads-up on the concurrent-dev window:** lead is landing an **anti-bypass ratchet gate** (authorization sites must route through the unified `authorize/3`) to protect main while the #195 revocation program lands. If your re-plumb adds/moves any authority-use or cap-read call, make sure it goes through the chokepoint, or the new gate will (correctly) red you.

Questions → ping lead. Only thing lead touched was the trial rebase (discarded); all logic is yours.
