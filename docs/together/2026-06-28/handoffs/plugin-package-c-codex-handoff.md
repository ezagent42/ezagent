# Handoff — Q1-C: full plugin-package (manifest + hot-load + assets + unload/swap) + E2E (codex)

**To:** codex  ·  **From:** coordinator (Claude)  ·  **Date:** 2026-06-28
**SPECs to read first (authoritative):**
- `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` — the 4-layer carrier taxonomy + Q1 plugin-package target form + red lines (business concepts in layer-2 DATA, never layer-1 code; blob never inline Postgres).
- `docs/together/2026-06-26/specs/socialware-unification.md` — the unified socialware model (base/socialware/fixture; socialware = installable config-as-data; install relation replaces public_view).

## Mission
Implement the **full plugin-package** form (the Q1 target, "C 档"): a developer's socialware ships as a **manifest + code + assets + seed-definitions** bundle that is **uploaded and hot-loaded WITHOUT restart**, including **assets hot-load** and **unload/swap**. Design + land a **codex-runnable E2E gate** for the plugin-package lifecycle. Then **stop and hand the target branch back** to the coordinator for acceptance + merge. **Do NOT self-merge to main, do NOT open a PR.**

## Skills to load (required)
`Skill: ezagent-developer`, `Skill: ezagent-socialware`, `Skill: elixir-phoenix-helper`. Elixir/BEAM umbrella.

## What already exists (reuse, don't rebuild)
- **Hot-load of compiled OTP app** — `mix ezagent.plugin.install <path>` (`apps/ezagent_core/lib/mix/tasks/ezagent.plugin.install.ex`): `:code.add_paths/1` + `:application.load/1` + `:application.ensure_all_started/1` → registration hooks fire (`BehaviorRegistry/KindRegistry/TemplateRegistry/RoutingRegistry`). "Hot-load + start an OTP plugin app into a running Ezagent (no phx.restart)". **No restart needed for code.**
- **Plugin contract** — `Ezagent.Plugin` (`apps/ezagent_core/lib/ezagent/plugin.ex`): `use Ezagent.Plugin`, declare `plugin_info` + what it ships (Kinds/Behaviors/spawn fns/Template Classes/flavors/routing); `Plugin.boot/1` does registration. Declarative.
- **Runtime behavior mount/detach** — `Ezagent.Kind.MountDetach` + `BehaviorSet.effective_set/2` (declared ++ captured-undeclared; survives cold restart).
- **Definition data substrate** — ConfigStore ConfigObject (recipe key `"recipe"`, socialware key `"socialware"`); seed_recipe_if_absent.
- **Assets** — vite-built islands into `priv/static` (compile-time today; #1065 fixed hello island build). **Assets hot-load is the GAP.**
- **Unload/swap** — **DEFERRED (D7-8)** — the GAP to close.

## Target branch + workflow
- Create `implement/plugin-package-c` off `origin/main` (fresh `git fetch origin`). Worktree under `.worktrees/`.
- **Self-merge all commits onto `implement/plugin-package-c`** (commit per logical step, push incrementally). **Do NOT merge to main, do NOT open a PR.** Return the target branch to the coordinator.
- **Goal: full gates green + the new plugin-package E2E gate green.** Self-drive to that goal.
- Full gate suite per change: `mix compile --warnings-as-errors` → `mix ezagent.arch.scan` → `mix ezagent.check_invariants`(+`.lifecycle`) → `mix ezagent.uri_query.scan` → `mix ezagent.doc.scan` → touched apps' `mix test` + the **socialware P10 E2E gate** (`apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs`) still green.
- Known flakes (PluginIsolation/AnonUserGC/PresenceReadReceipts/WorldHostRouting/AgentReadTest/DefaultSessionTemplateSeed) — note-only, don't chase. Any OTHER failure = real = fix.

## Scope (the 4 pieces + E2E)

### 1. Plugin-package form (manifest + bundle)
- Define a **package manifest** (declarative, like the existing `plugin_info` but richer): name, version, bases composed, shape, adapters exposed, config schema, asset entry points, seed-definition refs. A plugin package = a versioned archive (zip/tar) = `manifest + ebin/(compiled .beam/.app) + priv/(assets bundle + seed definitions) + manifest.json`.
- An author builds a plugin (`mix compile` + `assets.build`) → packages into the archive. The host accepts the archive.
- Reuse the existing `Ezagent.Plugin` contract; the manifest is the declarative extension.

### 2. Hot-load the package (no restart) — extend `plugin.install`
- Upload package → host unpacks to a plugin dir under EZAGENT_HOME (or a plugins dir) → `:code.add_paths` + `:application.load` + `:application.ensure_all_started` (existing path) → **+ seed the package's seed-definitions into ConfigStore** (recipe/socialware-def) → **+ register the package's assets** (see #3).
- No restart. The operator uploads and the socialware is live.

### 3. Assets hot-load (the #1065-class systematic fix)
- A plugin's frontend island bundle (vite-built JS/CSS in its `priv/`) must be **served after hot-load without a web rebuild**. Design a runtime asset-serving path: plugins serve their `priv/static` (or a per-plugin asset route) via the web endpoint; the web asset manifest/cache_manifest is **augmented at hot-load** (register the plugin's digested assets) rather than only at compile-time `assets.deploy`.
- A newly hot-loaded plugin's island must be reachable at its route immediately. Verify with a real fetch in the E2E.

### 4. Unload/swap (close the D7-8 deferral)
- **Unload**: stop the plugin OTP app (`:application.stop`/`stop_and_unregister`), unregister its Behaviors/Kinds/TemplateClasses/routing (`BehaviorRegistry.unregister` etc. — add the unregister APIs if missing), remove from code path (`:code.del_paths` + `:code.purge` modules), delete/retire its seeded definitions (or mark uninstalled). Live agents/sessions using the plugin's behaviors must be handled gracefully (deny new, drain existing — define the policy; let-it-crash if a live instance loses its behavior, but don't corrupt).
- **Swap**: unload v1 + load v2 atomically (or load-v2-then-unload-v1). BEAM hot-code-reloading semantics for the modules.
- This is the hardest piece — design the Kind/Behavior lifecycle for unload carefully (a session with an installed socialware whose plugin unloads).

### 5. E2E gate (codex-runnable, the completion gate)
Design + land a codex-runnable E2E (sibling of `socialware_p10_codex_gate_test.exs`, in-process via `EzagentCli.Exec.exec`/`Invocation.dispatch` — NOT `mix ezagent` shell). Asserts the full plugin-package lifecycle:
- **Build** a test plugin package (manifest + tiny Behavior + tiny island asset + seed recipe) in the test (or a fixture).
- **Install** (hot-load, no restart): upload/unpack → `plugin.install` → its Behavior/Kind reachable + its island asset served (assert a fetch of the asset route returns 200/the bundle) + its seed recipe in ConfigStore.
- **Use** it: a session installs the socialware → a round-trip through its behavior works (e.g. an action dispatches to its Behavior).
- **Unload**: after unload, the Behavior/Kind is gone (new dispatch fails cleanly), the asset route 404s, the seed recipe retired.
- **Swap**: install v2 (changed behavior) → the round-trip now reflects v2.
- **Anti-stub rule**: assertions observe state via PUBLIC entrypoints (the install/unload APIs + dispatch + HTTP fetch of the asset), NOT hand-inserted registry stubs. The invariant FAILS if any piece (manifest/hot-load/assets/unload/swap) is missing/broken.
- A live agent-browser screenshot by the coordinator is SECONDARY; the GATE is the codex-runnable automated suite.

## Red lines (hold)
- Business concepts in layer-2 data, never layer-1 code (don't bake business into the new packaging code).
- Blob never inline Postgres.
- No new `Behavior.Orchestrator`/`Behavior.Template` refit (OQ-1=(a)).
- The plugin-package code itself is layer-1 (generic mechanism, no business words).
- Credentials: self-generate (bootstrap admin token / mint temp users / self-mint test codex creds). NEVER ask the lead for passwords/tokens.

## Hand-back (when done)
1. Push `implement/plugin-package-c`.
2. Report: branch + a step-by-step summary (manifest form, hot-load extension, assets hot-load design, unload/swap design + lifecycle policy, the E2E gate + its assertions) + gate results (esp. the new E2E + P10 E2E still green) + any OQ (esp. the unload-vs-live-instance policy) + residual known-flake-only reds.
3. **STOP.** Do not merge, do not open a PR. The coordinator accepts + merges (and runs a live agent-browser E2E as secondary confirmation).

## If you stall (transient API)
Commit-before-every-step. The coordinator will re-dispatch fresh against your pushed commits.
