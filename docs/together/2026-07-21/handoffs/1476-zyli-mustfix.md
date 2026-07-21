# Handoff → zyli: #1476 — 2 must-fixes before merge-to-main (2026-07-21)

Your reconcile is **confirmed correct + safe** (lead's adversarial review, tests reproduced): World no longer compile-depends on Kanban, `view_switch_updates/3` routes through `PluginPageRegistry`, `mix compile --warnings-as-errors` is clean, ctx parity is byte-identical (no CBAC/read-plane regression), runtime-lookup has no race, rebase is clean. Declaration/registry 27/0, session-switch 15/0, kanban 92/0, read-plane 12/0.

**But the full `apps/ezagent_plugin_world/test` suite is 272 tests / 2 FAILURES — both PR-introduced arch-test regressions. Fix these 2 before merge; both make `mix precommit` red.**

## MUST-FIX 1 — slot manifest is stale AND its regen tool crashes (coupled)
- `apps/ezagent_plugin_world/assets/src/slots.manifest.json:69` still has `"data_source": "Ezagent.World.KanbanData"` — a module this PR deleted (moved to `EzagentPluginKanban.WorldData`). This fails `SlotRegistryTest` "checked-in slot manifest is in sync". The ONLY diff vs a fresh regen is that one line — pure staleness.
- **The documented regen command is broken by this very PR:** `mix world.slots.manifest` (and `--check`) crash with `(ArgumentError) the table identifier does not refer to an existing ETS table` at `:ets.match_object(:ezagent_plugin_registry, ...)` via `PluginPageRegistry.load/0`. Root cause: your PR made `SlotRegistry.families/0` a **runtime** function that reads the plugin-registry ETS (`slot_registry.ex:91` — it was a compile-time `@families` on main), but the mix task only runs `Mix.Task.run("app.config")` (config, not app boot), so the ETS table isn't populated.
- **Fix:** make `world.slots.manifest` boot the app before reading the registry — add `@requirements ["app.start"]` or `Mix.Task.run("app.start")` (mirror the sibling `world.renderers.manifest` task, which was written to avoid exactly this and whose `--check` passes). Then regenerate the manifest and commit it (the KanbanData line becomes the new module path).

## MUST-FIX 2 — family-parity gate test is stale (not updated for the renderer refactor)
- `slot_mount_gate_test.exs` "Check 3 — family parity" fails: renderer families (8, no kanban) != manifest families (9, incl kanban). Root cause: the helper `plugin_page_renderer_keys/0` parses `main.tsx` for the inline `const PLUGIN_PAGE_RENDERERS` object (present on main at ~line 1042). Your PR replaced that inline object with an **import of the generated `pluginPageRenderers` map** (`main.tsx:19`, used at ~:1133), so the helper now returns empty.
- **The underlying parity is actually INTACT (9 == 9)** — `kanban` is in both the generated `plugin-page-renderers.tsx` and the manifest, and the render path is wired (`world_page.tsx` exports `KanbanWorldPage`, imported+used in main.tsx). So this is a **test-helper update, not a rendering fix**: update `plugin_page_renderer_keys/0` to read the generated `plugin-page-renderers.tsx` map keys instead of parsing the (now-removed) inline object.

## How to verify without full precommit
`mix precommit` exceeds the 124s local command limit (that's why these slipped past you — see below), and CI is currently down (billing). So run the failing arch tests DIRECTLY:
```
mix test apps/ezagent_plugin_world/test   # confirm the 272 go green (was 272/2)
# or target the two: SlotRegistryTest + slot_mount_gate_test "family parity"
```

## Non-blocking (acknowledged deferrals — your call whether to fold in now)
- **De-hardcode is Kanban-only** — Hello still hardcoded (World mix.exs declares `ezagent_plugin_hello`; `conversation_data.ex:193` special-cases `:page/:hello_page`). DoD #4 not fully met.
- **Drift gate (DoD #6) absent** — for a "de-hardcode ALL World→plugin" task, the zero-allowlist enumerator gate IS the completeness guarantee (per "Replacement gate = parity audit"). Lead's grep proves Kanban is severed *now*, but nothing structurally prevents re-hardcoding, and Hello proves the surface isn't clean yet.
- **Reverse Kanban→World undeclared dep (latent):** `kanban world_actions.ex` now references `Ezagent.World.PresenterCaps` without declaring `ezagent_plugin_world` in its mix.exs — an undeclared cross-app compile dep masked by umbrella build order. Worth a follow-up.

Fix MUST-FIX 1+2 → world suite green → ping lead; CI's down so lead verifies + admin-merges when the dockerized runner is back.
