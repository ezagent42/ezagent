# Plugin UI self-declaration (UiSurfaceProvider) — world read-side de-hardcoding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **STATUS: PROVISIONAL — pending a codex adversarial-review pass (coordinator will run it before zyli starts). Two boundary decisions are flagged inline as `⚠️ DECISION FOR CODEX`. Treat those as recommendations, not settled, until the review lands.**

**Goal:** Reverse world's plugin-page + action-allowlist data source from world-hardcoded compile-time constants to **runtime enumeration of each plugin's `UiSurfaceProvider` declarations**, add a build-time codegen mix task that generates the frontend renderer wiring, dissolve the `isHelloSession` session-page special-case into the generic session-tab mechanism, and add a drift-prevention gate whose empty-allowlist red build names every remaining hardcoded plugin touch-point in world.

**Architecture:** Extend the existing #1117 substrate (`Ezagent.World.UiSurfaceProvider` / `PluginPageRegistry` / `SlotRegistry`) — which already self-declares **nav** and **session-tabs** by enumerating `Ezagent.PluginRegistry.list_all/0` — to also cover the **`page`** surface and its **renderer face**. `world` is itself a registered plugin (`slug: "world"`, `use Ezagent.Plugin`), so it enumerates through the *same* path a real plugin uses: the reader becomes **pure enumeration**, and world declares its own (transitional, allowlisted) kanban page via its own `page/0` until jjkysy's track moves that declaration onto `ezagent_plugin_kanban`. The strangler here (Allen decision 1) is **demote world in place**, not a new shell app.

**Tech Stack:** Elixir umbrella (`apps/ezagent_plugin_world`, `apps/ezagent_core`), ExUnit, `mix` tasks for build-time codegen, React/TSX + esbuild frontend (`assets/src`), `pnpm` dev-facing mirror scripts.

## Global Constraints

- **Allen decision 1 — Shell = demote `world` in place (Option 1, strangler).** No new `ezagent_plugin_shell` app. World *becomes* the thin enumerator; the generic machinery strengthens in place.
- **Allen decision 2 — Composition model = HYBRID.** Data-described assembly with "slot/anchor" as a node kind; the shell owns no closed position enum. In practice for this read-side: `SlotRegistry` renderer families = the fill vocabulary; a page declaration names its family; positions stay data.
- **Allen decision 3 — Renderer bundle-loading v1 = build-time codegen enumeration.** A `mix` task enumerates `PluginRegistry.list_all/0` and generates the frontend imports / `PLUGIN_PAGE_RENDERERS` / `FULL_BLEED_FAMILIES` / merged `slots.manifest.json`. **No runtime loader, no iframe, no import maps in v1.**
- **Fail-closed everywhere.** Unknown/undeclared key/route/action/anchor ⇒ `nil`/nothing/throw — never a permissive default. Every new read-time predicate mirrors the existing `valid_nav_surface?/1` skip-not-crash discipline.
- **Main stays green after zyli's PR alone.** Kanban and hello must keep rendering end-to-end at every commit. Zyli does **not** edit `ezagent_plugin_kanban` or `ezagent_plugin_hello`; the plugin-migration + final literal deletion is jjkysy's separate track. Kanban's declaration lives transitionally on **world's own** `page/0`, tracked by the drift-gate allowlist.
- **`uv run`, not `python`.** (Repo hook.) Elixir work is `mix`; run from the umbrella root or `apps/ezagent_plugin_world`.
- **Zero behavior change to the kanban action allowlist** except by explicit decision — the `plugin_page_registry_test.exs` verbatim/`declared_actions` equivalence locks must stay green (they move with the declaration, they do not weaken).

**Design of record (read both before starting — NOTE: neither is on `main` yet):**
- Handoff (Allen's decisions + scope split): `docs/together/2026-07-20/handoffs/plugin-ui-surface-handoff.md` — currently on branch **`origin/docs/plugin-ui-surface-handoff`** (commit `e07624eef`), landing separately.
- Research + full design: `docs/superpowers/specs/2026-07-19-plugin-ui-surface-architecture-research.md` — code-verified `file:line` grounding, landing separately.

---

## Scope boundary (read this first)

**IN scope (zyli — world read-side, this plan):**
1. Extend `UiSurfaceProvider` with the `page` surface + its shape gate.
2. Flip `PluginPageRegistry.pages/0` from a compile-time `@pages` constant to **runtime enumeration** of installed plugins' `page/0`.
3. Convert the **two compile-time consumers** of `pages/0` (`world_live.ex` route-state clauses; `SlotRegistry` plugin families) to runtime — **this is mandatory, not optional** (`PluginRegistry` is a runtime ETS table, empty at compile time).
4. The **build-time codegen mix task** that generates the frontend renderer wiring from `page/0`.
5. Dissolve the `isHelloSession` special-case *structure* into the generic session-tab render path.
6. The **drift-prevention gate** (new plugin-name-literal tooth + fail-closed admission + non-vacuous detectors + enumeration-derivability).

**OUT of scope (jjkysy — plugin-migration track, separate PR):**
- Physically moving `Kanban.tsx` / `KanbanCanvas.tsx` and hello's `WorldHello.tsx` out of world's asset tree into their own plugins.
- Adding `page/0` / `session_tabs/0` declarations onto `ezagent_plugin_kanban` / `ezagent_plugin_hello` and deleting world's transitional declarations.
- Deleting the final `isHelloSession` literal + the `WorldHello` fallthrough import.
- Shrinking the drift-gate allowlist to `[]` (each migrated touch-point removes one allowlist entry — that is jjkysy's definition of done).

**Why this split keeps main green:** zyli builds the *reader/mechanism* and proves it against **fixture plugins** (the exact `plugin_nav_surfaces_test.exs` fixture pattern). Kanban keeps working because **world declares kanban's page via its own `page/0`** during the transition — routed through the *same* enumeration path a real plugin uses. That world-side kanban literal is the drift-gate allowlist's seed entry; jjkysy retires it.

---

## File structure

**Modify (Elixir, world read-side):**
- `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex` — add `page/0` callback + `valid_page?/1` (Task 1).
- `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex` — `pages/0` → runtime enumeration; delete `@pages` + `@kanban_actions` (Task 2).
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex` — world declares its transitional `page/0` (Task 2).
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` — compile-time `for`-generated `state_for_route/3` clauses → one runtime clause (Task 3).
- `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex` — `@plugin_page_families`/`@families` compile-time attrs → runtime resolution (Task 4).

**Create (Elixir):**
- `apps/ezagent_plugin_world/lib/mix/tasks/world.ui.codegen.ex` — build-time frontend codegen (Task 5).
- `apps/ezagent_plugin_world/test/ezagent/world/plugin_ui_self_declaration_gate_test.exs` — the drift gate (Task 7).

**Modify (frontend):**
- `apps/ezagent_plugin_world/assets/src/main.tsx` — replace hand-edited `PLUGIN_PAGE_RENDERERS` / `import {Kanban}` / `FULL_BLEED_FAMILIES` literals with generated includes (Task 5).
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` — replace `isHelloSession` branch with generic enumerated-session-tab rendering (Task 6).

**Test fixtures / consumers touched:**
- `apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs` — assertions re-sourced through enumeration; equivalence locks preserved (Task 2).
- Reference-only (do not break): `slot_registry_test.exs`, `slot_mount_gate_test.exs`, `routes_test.exs`, `plugin_nav_surfaces_test.exs`, `plugin_session_tabs_test.exs`.

---

## ⚠️ DECISION FOR CODEX (2) — resolve before/at review, defaults chosen for green-main

**D1 — `page/0` row shape: embed `actions` in the page row (v1 default) vs a separate `actions/0` callback (research §5.1 ideal).**
Research §5.1 lists `page/0` and `actions/0` as distinct surfaces. This plan's default **embeds `actions` + `action_prefixes` in the page row** (identical to today's `@pages` row shape, merely relocated to the plugin) — the *minimal delta* from #1117 and the smallest thing that keeps the `by_action/1` admission + the equivalence lock unchanged. Splitting `actions/0` out is a clean follow-up but adds a second callback + a second shape gate for no v1 behavior gain. **Recommendation: embed in v1.** Codex to confirm or split.

**D2 — Task 6 (session-page) boundary.** Zyli replaces the `isHelloSession` *branch structure* in `Conversation.tsx` with a generic loop over the already-serialized `plugin_session_tabs/1` output (proved against a **fixture** session-tab), so "add a session page tab" = "a plugin declares a `session_tab`," never "edit Conversation.tsx." The **final deletion of the `isHelloSession` literal + `WorldHello` move** is jjkysy (hello's components move with it). If codex judges the two are inseparable, Task 6 collapses entirely into jjkysy's track and zyli's scope is Tasks 1–5 + 7. **Recommendation: keep the generic mechanism in zyli (Task 6), literal-deletion in jjkysy.**

---

## Task 1: Extend `UiSurfaceProvider` with the `page` surface + shape gate

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex` (add `@type page_surface`, `@callback page/0`, `@optional_callbacks page: 0`, `valid_page?/1`)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_test.exs` (extend)

**Interfaces:**
- Produces: `Ezagent.World.UiSurfaceProvider.valid_page?/1 :: (term() -> boolean())`; the `page_surface` type `%{key, route, detail_route, nav, data_builder, renderer_families, action_prefixes, actions, actions_module}` (verbatim the existing `PluginPageRegistry.page` type at `plugin_page_registry.ex:45-55`, plus an optional `component_import :: String.t()` used by Task 5 codegen). `@callback page() :: [page_surface()]`, default `[]` by convention.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test** — append to `ui_surface_provider_test.exs`:

```elixir
describe "valid_page?/1 (read-time shape gate, fail-closed)" do
  @good %{
    key: "kanban",
    route: {"/plugins/kanban", :index},
    detail_route: {"/plugins/kanban/:id", :detail},
    nav: %{label: "看板", path: "/plugins/kanban"},
    data_builder: Ezagent.World.KanbanData,
    renderer_families: [{"kanban", "看板"}],
    action_prefixes: ["kanban."],
    actions: ["kanban.add_node"],
    actions_module: Ezagent.World.KanbanActions
  }

  test "accepts a fully-shaped page" do
    assert Ezagent.World.UiSurfaceProvider.valid_page?(@good)
  end

  test "accepts an optional string :component_import" do
    assert Ezagent.World.UiSurfaceProvider.valid_page?(Map.put(@good, :component_import, "./components/Kanban"))
  end

  test "rejects a page missing a required field (fail-closed skip, no crash)" do
    for missing <- [:key, :route, :data_builder, :action_prefixes, :actions, :actions_module] do
      refute Ezagent.World.UiSurfaceProvider.valid_page?(Map.delete(@good, missing)),
             "a page missing #{missing} must be rejected"
    end
  end

  test "rejects non-map / empty-string key / non-atom module" do
    refute Ezagent.World.UiSurfaceProvider.valid_page?(%{})
    refute Ezagent.World.UiSurfaceProvider.valid_page?(Map.put(@good, :key, ""))
    refute Ezagent.World.UiSurfaceProvider.valid_page?(Map.put(@good, :data_builder, "nope"))
    refute Ezagent.World.UiSurfaceProvider.valid_page?(nil)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_test.exs -o "valid_page"`
Expected: FAIL — `UndefinedFunctionError: Ezagent.World.UiSurfaceProvider.valid_page?/1 is undefined`

- [ ] **Step 3: Write minimal implementation** — in `ui_surface_provider.ex`, after `valid_session_tab?/1` (currently ends `:124`), add the callback + gate. Mirror the `valid_nav_surface?/1` style exactly (required-key match in the head, optional field via `Map.get`):

```elixir
@typedoc """
Layer-1 full-page operating surface a plugin contributes — the row that was
world-hardcoded in `PluginPageRegistry.@pages`, now self-declared. Verbatim the
`PluginPageRegistry.page` shape, plus an optional `:component_import` (the
frontend entrypoint the build-time codegen imports; absent ⇒ world hosts it).
"""
@type page_surface :: %{
        required(:key) => String.t(),
        required(:route) => {String.t(), :index},
        required(:detail_route) => {String.t(), :detail},
        required(:nav) => %{label: String.t(), path: String.t()},
        required(:data_builder) => module(),
        required(:renderer_families) => [{String.t(), String.t()}],
        required(:action_prefixes) => [String.t()],
        required(:actions) => [String.t()],
        required(:actions_module) => module(),
        optional(:component_import) => String.t()
      }

@doc """
Layer-1 full-page surfaces this plugin contributes. Default `[]` by convention
(absent function ⇒ no page). World reads it via `function_exported?/3` and
filters each entry through `valid_page?/1`.
"""
@callback page() :: [page_surface()]

@doc """
Read-time shape predicate for one `page/0` entry (fail-closed — a malformed
entry is skipped, never crashes the enumerator). `true` iff the entry carries
the full page shape; `:component_import`, when present, must be a binary.
"""
@spec valid_page?(term()) :: boolean()
def valid_page?(
      %{
        key: key,
        route: {ir, :index},
        detail_route: {dr, :detail},
        nav: %{label: nl, path: np},
        data_builder: db,
        renderer_families: rf,
        action_prefixes: ap,
        actions: actions,
        actions_module: am
      } = page
    )
    when is_binary(key) and key != "" and is_binary(ir) and is_binary(dr) and
           is_binary(nl) and is_binary(np) and is_atom(db) and is_list(rf) and
           is_list(ap) and ap != [] and is_list(actions) and actions != [] and is_atom(am) do
  case Map.get(page, :component_import) do
    nil -> true
    ci -> is_binary(ci)
  end
end

def valid_page?(_), do: false
```

Also add `page: 0` to `@optional_callbacks` (currently `nav_surfaces: 0, session_tabs: 0` at `:86`).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_test.exs`
Expected: PASS (all, including the pre-existing nav/tab gate tests)

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex \
        apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_test.exs
git commit -m "feat(world/ui): add page surface + valid_page?/1 to UiSurfaceProvider"
```

---

## Task 2: Flip `PluginPageRegistry.pages/0` to runtime enumeration; world declares its transitional kanban page

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex` (delete `@kanban_actions` `:28`, `@pages` `:30-43`; rewrite `pages/0` `:59` as an enumerator; keep `by_key/1`/`by_route/1`/`by_action/1` reading `pages()`)
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex` (add world's transitional `page/0`)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs` (re-source through enumeration; keep equivalence locks)
- New test: `apps/ezagent_plugin_world/test/ezagent/world/plugin_page_enumeration_test.exs` (fixture-plugin enumeration)

**Interfaces:**
- Consumes: `Ezagent.PluginRegistry.list_all/0` (`apps/ezagent_core/lib/ezagent/plugin_registry.ex:58`), `UiSurfaceProvider.valid_page?/1` (Task 1). Mirrors `WorkspacePluginData.plugin_nav_surfaces/0` (`workspace_plugin_data.ex:454`) traversal verbatim.
- Produces: `PluginPageRegistry.pages/0 :: [UiSurfaceProvider.page_surface()]` (now runtime, order = sort by plugin slug then declaration order). `by_key/1`, `by_route/1`, `by_action/1` signatures unchanged.

- [ ] **Step 1: Write the failing test** — new file `plugin_page_enumeration_test.exs`, using the `plugin_nav_surfaces_test.exs` fixture pattern (verified at `test/ezagent/world/plugin_nav_surfaces_test.exs:20-83`):

```elixir
defmodule Ezagent.World.PluginPageEnumerationTest do
  @moduledoc "pages/0 is runtime-enumerated from installed plugins' page/0 (no world @pages constant)."
  use ExUnit.Case, async: false
  alias Ezagent.World.PluginPageRegistry

  defmodule PageFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider
    @impl Ezagent.Plugin
    def plugin_info, do: %{slug: "world-page-fixture", name: "Page Fixture", description: "t", version: "1.0.0"}
    @impl Ezagent.World.UiSurfaceProvider
    def page do
      [%{
        key: "fixturepage",
        route: {"/plugins/fixturepage", :index},
        detail_route: {"/plugins/fixturepage/:id", :detail},
        nav: %{label: "Fixture", path: "/plugins/fixturepage"},
        data_builder: Ezagent.World.KanbanData,
        renderer_families: [{"fixturepage", "Fixture"}],
        action_prefixes: ["fixturepage."],
        actions: ["fixturepage.ping"],
        actions_module: Ezagent.World.KanbanActions
      }]
    end
  end

  defmodule NoPagePlugin do
    use Ezagent.Plugin
    @impl Ezagent.Plugin
    def plugin_info, do: %{slug: "world-page-none", name: "No Page", description: "t", version: "1.0.0"}
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    :ok
  end

  test "an installed plugin's page/0 appears in pages/0 (enumeration-derivable)" do
    :ok = Ezagent.PluginRegistry.register(PageFixturePlugin)
    assert %{key: "fixturepage"} = PluginPageRegistry.by_key("fixturepage")
    assert {%{key: "fixturepage"}, %{}} = PluginPageRegistry.by_route("/plugins/fixturepage")
    assert %{key: "fixturepage", actions_module: Ezagent.World.KanbanActions} =
             PluginPageRegistry.by_action("fixturepage.ping")
  end

  test "a plugin without page/0 contributes nothing (no crash)" do
    :ok = Ezagent.PluginRegistry.register(NoPagePlugin)
    refute Enum.any?(PluginPageRegistry.pages(), &(&1.key == "world-page-none"))
  end

  test "no world-owned @pages constant remains — the module holds no page literal" do
    src = File.read!("apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex")
    refute src =~ "@pages ", "PluginPageRegistry must enumerate, not hold an @pages constant"
    refute src =~ "@kanban_actions", "the kanban allowlist must live in a plugin's page/0, not world's registry"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/plugin_page_enumeration_test.exs`
Expected: FAIL — the source-literal assertions fail (`@pages`/`@kanban_actions` still present); `by_key("fixturepage")` returns `nil` (registry still reads the constant).

- [ ] **Step 3: Write minimal implementation.**

(a) In `plugin_page_registry.ex`: delete `@kanban_actions` (`:28`) and `@pages` (`:30-43`); rewrite `pages/0` to enumerate. Keep the `@type page` and `by_key`/`by_route`/`by_action`/`match_page`/`match_pattern` bodies unchanged (they already read `pages()`):

```elixir
@doc "全部注册页面 = 枚举已安装插件的 page/0（fail-closed，读时 valid_page? 过滤）。"
@spec pages() :: [Ezagent.World.UiSurfaceProvider.page_surface()]
def pages do
  Ezagent.PluginRegistry.list_all()
  |> Enum.sort_by(fn plugin_module -> plugin_module.plugin_info().slug end)
  |> Enum.filter(&function_exported?(&1, :page, 0))
  |> Enum.flat_map(fn plugin_module ->
    plugin_module.page()
    |> Enum.filter(&Ezagent.World.UiSurfaceProvider.valid_page?/1)
  end)
rescue
  _ -> []
end
```

(b) In `application.ex`, make world declare its transitional kanban page. Add `@behaviour Ezagent.World.UiSurfaceProvider` and a `page/0` that returns the exact row deleted from `@pages` (⚠️ D1: `actions` embedded in the row). This is the **allowlisted** world-side kanban literal:

```elixir
@impl Ezagent.World.UiSurfaceProvider
# TRANSITIONAL (drift-gate allowlisted): kanban's page is declared here on
# `world` until the jjkysy plugin-migration track moves it onto
# `ezagent_plugin_kanban` and deletes this. World is a registered plugin
# (slug "world"), so it enumerates through the same page/0 path as any plugin.
def page do
  kanban_actions = ~w(kanban.add_node kanban.rename_node kanban.move_node kanban.remove_node kanban.set_stage kanban.claim_node kanban.unclaim_node kanban.set_status kanban.attach_artifact kanban.detach_artifact kanban.set_metric kanban.create kanban.sync_miro kanban.save_miro_creds kanban.select_board kanban.drop_subtree kanban.set_board_config kanban.attach_upload kanban.register_pr kanban.attach_code_file kanban.share_board)

  [%{
    key: "kanban",
    route: {"/plugins/kanban", :index},
    detail_route: {"/plugins/kanban/:id", :detail},
    nav: %{label: "看板", path: "/plugins/kanban"},
    data_builder: Ezagent.World.KanbanData,
    renderer_families: [{"kanban", "看板"}],
    action_prefixes: ["kanban."],
    actions: kanban_actions,
    actions_module: Ezagent.World.KanbanActions,
    component_import: "./components/Kanban"
  }]
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/plugin_page_enumeration_test.exs apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs`
Expected: PASS. The existing `plugin_page_registry_test.exs` (kanban `by_key`/`by_route`/`by_action` + the `@legacy_kanban_actions` verbatim lock + `declared_actions` equivalence) stays green because kanban's row is now sourced from world's `page/0`. If `plugin_page_registry_test.exs` has `async: true`, change to `async: false` (it now depends on the runtime registry) — verify and adjust.

- [ ] **Step 5: Run the world test suite to confirm no regression (compile-time consumers still on the constant will break here — that is expected and handled by Tasks 3–4; if the suite won't compile, do Steps of Task 3 and Task 4 before committing).**

Run: `mix test apps/ezagent_plugin_world`
Expected: `world_live.ex` and `slot_registry.ex` compile-time reads of `pages()` now evaluate against an empty compile-time registry. **This is the mandatory conversion in Tasks 3 + 4.** Commit Task 2 only once Tasks 3 + 4 land (they are one atomic "pages/0 goes runtime" move). See the note below.

> **ORDERING NOTE:** Tasks 2, 3, 4 form one atomic flip (`pages/0` runtime). Implement all three, then run `mix compile --warnings-as-errors` + `mix test apps/ezagent_plugin_world` once, then commit as one or three tightly-sequenced commits. Do not push a state where `pages/0` is runtime but its compile-time consumers still assume a constant.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex \
        apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex \
        apps/ezagent_plugin_world/test/ezagent/world/plugin_page_enumeration_test.exs \
        apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs
git commit -m "feat(world/ui): enumerate plugin pages at runtime; world declares kanban page transitionally"
```

---

## Task 3: Convert `world_live.ex` compile-time route-state clauses to a runtime clause

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:856-871` (the `for %{key, data_builder} <- PluginPageRegistry.pages()` block generating `state_for_route/3` clauses at compile time)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs` and/or a focused `world_live_plugin_page_state_test.exs`

**Interfaces:**
- Consumes: `PluginPageRegistry.by_key/1` (Task 2). The `state_for_route/3` private fn shape (`route`, `socket`, `layout`) is unchanged.
- Produces: one runtime `state_for_route` clause that resolves a plugin page by its `component` key at request time.

**Why:** `PluginRegistry` is a runtime ETS table (empty at compile time — plugins self-register in `Ezagent.Plugin.boot/1`, `plugin.ex:503`). The current `for ... <- PluginPageRegistry.pages()` (`:859`) unrolls one function clause **per page at compile time**; with `pages/0` now runtime that comprehension yields **zero clauses** and kanban's route stops resolving. It must become a single runtime lookup.

- [ ] **Step 1: Write the failing test** — focused test that a kanban route builds state via the plugin's `data_builder`:

```elixir
# apps/ezagent_plugin_world/test/ezagent/world/world_live_plugin_page_state_test.exs
defmodule Ezagent.World.WorldLivePluginPageStateTest do
  use ExUnit.Case, async: false
  # Drives the route → state_for_route path for a registered plugin page.
  # (Follow routes_test.exs' existing harness for building a %{component: "kanban"} route
  #  + a minimal socket; assert the returned state carries KanbanData's shape + "layout".)
  test "a registered plugin page resolves its data_builder state at runtime" do
    # ... arrange a kanban route + socket per routes_test.exs helpers ...
    # state = WorldLive.__state_for_route_for_test__(route, socket, layout)
    # assert Map.has_key?(state, "layout")
    # assert state["component"] == "kanban" or KanbanData-derived key present
    flunk("replace with the routes_test.exs harness call — see that file for the socket builder")
  end
end
```

> Implementer note: `routes_test.exs` already exercises route→state; prefer extending it over a new file if its harness is reusable. The failing assertion must be "kanban route yields KanbanData state," which fails the moment the compile-time `for` yields no clause.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs` (after Task 2's `pages/0` flip)
Expected: FAIL — kanban route falls through to the generic `state_for_route/3` clause (`:885`) and builds `IdentityData` state, not `KanbanData` state (or raises).

- [ ] **Step 3: Write minimal implementation** — replace the compile-time `for` block (`:856-871`) with one runtime clause placed **before** the `:workspace_plugins` clause (`:873`), preserving ordering:

```elixir
# 插件页面（`Ezagent.World.PluginPageRegistry`）：运行期按 component key 查注册表，
# 用该页 data_builder 读模型。pages/0 现为运行期枚举（编译期 registry 为空），
# 故此处从「编译期 per-page 子句」改为「运行期查表」。必须排在通用
# `:workspace_plugins` 子句之前——页面 route 同属该 group。
defp state_for_route(%{component: component} = route, socket, layout)
     when is_binary(component) do
  case Ezagent.World.PluginPageRegistry.by_key(component) do
    %{data_builder: data_builder} ->
      route
      |> data_builder.state_for(%{
        workspace_uri: socket.assigns.current_workspace_uri,
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new())
      })
      |> Map.put("layout", layout)
      |> Map.put("can_manage_layout", false)
      |> put_command_palette(socket)

    nil ->
      state_for_route_non_plugin(route, socket, layout)
  end
end
```

Rename the existing generic clauses (`:873` `:workspace_plugins`, `:885` catch-all) into a `state_for_route_non_plugin/3` fallback chain, OR — simpler — keep them as-is and let the new clause's `nil` branch fall through by pattern order. **Verify clause ordering with `mix compile --warnings-as-errors`** (an unreachable-clause warning means the guard is wrong). Preserve the exact `:workspace_plugins`-before-catch-all precedence.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs apps/ezagent_plugin_world/test/ezagent/world/world_live_plugin_page_state_test.exs`
Expected: PASS — kanban route builds `KanbanData` state at runtime.

- [ ] **Step 5: Commit** (with Task 2/4 per the ordering note)

```bash
git add apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex \
        apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs
git commit -m "refactor(world/ui): resolve plugin-page route state at runtime (not compile-time codegen)"
```

---

## Task 4: Convert `SlotRegistry` plugin-family derivation from compile-time attr to runtime

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex:37-43` (`@plugin_page_families`), `:100-105` (compile-time clash check), `:107` (`@families`), and the readers `layout_slots/0` `:134`, `manifest/0` `:183`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs` (existing manifest/route-slot gate — must stay green)

**Interfaces:**
- Consumes: `PluginPageRegistry.pages/0` (runtime, Task 2).
- Produces: `SlotRegistry.layout_slots/0`, `manifest/0`, `manifest_json/0` — signatures unchanged; plugin families now resolved at call time. Preserves the "plugin page key must not clash with a static family" fail-closed rule (moved from compile-time `raise` to a runtime raise inside the family merge).

**Why:** `@plugin_page_families` (`:37-43`) is a **module attribute** — evaluated at compile time, when the registry is empty. `@families = Map.merge(@static_families, @plugin_page_families)` (`:107`) bakes in zero plugin families. Every reader must compute the merged family map at runtime.

- [ ] **Step 1: Write the failing test** — assert a runtime-registered plugin page appears as a renderer family in the manifest:

```elixir
# append to slot_registry_test.exs (or a new slot_registry_runtime_families_test.exs, async: false)
test "a runtime-registered plugin page contributes a renderer family to the manifest" do
  {:ok, _} = Application.ensure_all_started(:ezagent_core)
  # kanban page is declared by world's page/0, registered at boot:
  families = Ezagent.World.SlotRegistry.manifest()["renderer_families"]
  assert Map.has_key?(families, "kanban"), "kanban family must be present at runtime"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs`
Expected: FAIL — after Task 2, `@plugin_page_families` is empty (compile-time registry), so `"kanban"` is missing from `renderer_families`.

- [ ] **Step 3: Write minimal implementation** — replace the compile-time attrs with a private runtime function; keep `@static_families` as the compile-time constant it is:

```elixir
# DELETE @plugin_page_families (:37-43), the compile-time clash `case` (:100-105),
# and @families (:107). Replace with a runtime family map:

# renderer families contributed by enumerated plugin pages (family atom = page key).
defp plugin_page_families do
  Map.new(Ezagent.World.PluginPageRegistry.pages(), fn page ->
    {String.to_atom(page.key), {page.data_builder, page.renderer_families}}
  end)
end

# merged families, runtime. Preserves the fail-closed no-clash rule (was compile-time).
defp families do
  plugin = plugin_page_families()

  case Map.keys(Map.take(@static_families, Map.keys(plugin))) do
    [] -> Map.merge(@static_families, plugin)
    clash -> raise "plugin page keys clash with static renderer families: #{inspect(clash)}"
  end
end
```

Then change `layout_slots/0` (`:135` `for {family, ...} <- @families`) and `manifest/0` (`:196` `for {family, ...} <- @families`) to call `families()` instead of `@families`. `String.to_atom` on page keys stays safe (keys come from validated `page/0` declarations, a bounded install-time set — same as before).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs`
Expected: PASS — `renderer_families` contains `kanban` at runtime; the family-parity gate (`slot_mount_gate_test.exs` Check 3) stays green.

- [ ] **Step 5: Regenerate + verify the manifest is in sync** (the checked-in JSON is a projection):

Run: `mix world.slots.manifest --check`
Expected: "world slot manifest in sync" — if stale, run `mix world.slots.manifest` and commit the regenerated `slots.manifest.json`. (Task 5 folds this into the unified codegen; for now keep the existing task green.)

- [ ] **Step 6: Commit** (with Task 2/3 per the ordering note)

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex \
        apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs \
        apps/ezagent_plugin_world/assets/src/slots.manifest.json
git commit -m "refactor(world/ui): resolve SlotRegistry plugin families at runtime"
```

**Checkpoint after Tasks 2–4:** `mix compile --warnings-as-errors && mix test apps/ezagent_plugin_world` must be fully green — `pages/0` is now runtime end-to-end with kanban still rendering.

---

## Task 5: Build-time codegen mix task — generate the frontend renderer wiring from `page/0`

**Files:**
- Create: `apps/ezagent_plugin_world/lib/mix/tasks/world.ui.codegen.ex`
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx` (replace hand-edited `import {Kanban}` `:11`, the `PLUGIN_PAGE_RENDERERS` literal `:1042-1060`, and the `"kanban"` member of `FULL_BLEED_FAMILIES` `:39` with a generated include)
- Create: `apps/ezagent_plugin_world/assets/src/plugin-pages.generated.tsx` (the generated barrel — imports + `PLUGIN_PAGE_RENDERERS` + generated `FULL_BLEED_FAMILIES` additions)
- Test: `apps/ezagent_plugin_world/test/mix/tasks/world_ui_codegen_test.exs`

**Interfaces:**
- Consumes: `PluginPageRegistry.pages/0` (Task 2), each page's `:key`, `:renderer_families`, and optional `:component_import`.
- Produces: `mix world.ui.codegen` (write) + `mix world.ui.codegen --check` (CI drift gate, raises on drift — mirrors `world.slots.manifest` `:25-34`). A generated `plugin-pages.generated.tsx` barrel imported by `main.tsx`.

**Model this on the existing `world.slots.manifest` task** (`lib/mix/tasks/world.slots.manifest.ex` — `Mix.Task.run("app.config")`, `--check` drift, `manifest_path/0` root-or-app resolution). Use `Mix.Task.run("app.start")` so plugins self-register before enumeration.

- [ ] **Step 1: Write the failing test:**

```elixir
# apps/ezagent_plugin_world/test/mix/tasks/world_ui_codegen_test.exs
defmodule Mix.Tasks.World.Ui.CodegenTest do
  use ExUnit.Case, async: false

  test "generated barrel contains one PLUGIN_PAGE_RENDERERS entry per enumerated page" do
    generated = Mix.Tasks.World.Ui.Codegen.render()   # pure string builder, no file IO
    assert generated =~ "PLUGIN_PAGE_RENDERERS"
    # kanban page (declared by world.page/0) must be wired from its component_import:
    assert generated =~ ~s|import {Kanban}|
    assert generated =~ "kanban:"
    # no plugin whose page/0 is absent leaks in:
    refute generated =~ "undefined_plugin"
  end

  test "--check raises when the on-disk barrel is stale" do
    # write a deliberately-wrong barrel to a tmp path, assert render/0 != it (drift detectable)
    assert Mix.Tasks.World.Ui.Codegen.render() != "// stale\n"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/mix/tasks/world_ui_codegen_test.exs`
Expected: FAIL — `Mix.Tasks.World.Ui.Codegen` is undefined.

- [ ] **Step 3: Write minimal implementation** — the task enumerates pages and renders a `.tsx` barrel. Keep the codegen string builder (`render/0`) pure and separately testable:

```elixir
defmodule Mix.Tasks.World.Ui.Codegen do
  @moduledoc """
  Generate the frontend plugin-page barrel from enumerated `page/0` declarations.

      mix world.ui.codegen          # write assets/src/plugin-pages.generated.tsx
      mix world.ui.codegen --check  # CI drift gate — raise if stale

  Enumerates `Ezagent.World.PluginPageRegistry.pages/0` (which enumerates
  `Ezagent.PluginRegistry.list_all/0`) and writes the imports +
  `PLUGIN_PAGE_RENDERERS` map that were hand-edited in `main.tsx` (edit #3 of the
  4-edit tax). Adding a plugin UI ⇒ 0 edits to world; the build enumerates.
  Build-time only — no runtime loader (Allen decision 3).
  """
  use Mix.Task
  @shortdoc "Regenerate (or --check) the world plugin-page renderer barrel"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])
    path = barrel_path()
    generated = render()

    if opts[:check] do
      on_disk = if File.exists?(path), do: File.read!(path), else: ""
      if on_disk == generated,
        do: Mix.shell().info("world plugin-page barrel in sync (#{Path.relative_to_cwd(path)})"),
        else: Mix.raise("world plugin-page barrel is stale — run `mix world.ui.codegen` and commit #{Path.relative_to_cwd(path)}")
    else
      File.write!(path, generated)
      Mix.shell().info("wrote #{Path.relative_to_cwd(path)}")
    end
  end

  @doc "Pure string builder — the barrel content for the enumerated pages."
  def render do
    pages = Ezagent.World.PluginPageRegistry.pages()
    # ... build: a header comment ("GENERATED by mix world.ui.codegen — do not edit"),
    #     one `import {<Component>} from "<component_import>"` per page that declares one,
    #     the `PLUGIN_PAGE_RENDERERS` map (family key = page key), and a
    #     `GENERATED_FULL_BLEED_FAMILIES` array from pages whose family is full-bleed.
    #     Keep the kanban render body (mode/ManageFrame/onWorkspacePluginAction) as the
    #     default template; a page may later ship its own renderer entry.
    # Return the assembled binary. (Deterministic order = pages/0 order.)
  end

  defp barrel_path do
    cond do
      File.dir?("apps/ezagent_plugin_world/assets/src") -> "apps/ezagent_plugin_world/assets/src/plugin-pages.generated.tsx"
      File.dir?("assets/src") -> "assets/src/plugin-pages.generated.tsx"
      true -> Mix.raise("cannot locate world assets/src")
    end
  end
end
```

Then in `main.tsx`: delete the literal `import {Kanban}` (`:11`) and the `PLUGIN_PAGE_RENDERERS` literal (`:1042-1060`); `import {PLUGIN_PAGE_RENDERERS, GENERATED_FULL_BLEED_FAMILIES} from "./plugin-pages.generated"`; and union `GENERATED_FULL_BLEED_FAMILIES` into `FULL_BLEED_FAMILIES` (`:39`) instead of the literal `"kanban"`.

> **D1/allowlist note:** the kanban render body still contains the string `"kanban"` — but it lives in the *generated* file, produced from world's transitional `page/0`. The drift gate (Task 7) allowlists the generated file's kanban entry the same way it allowlists world's `page/0`; both retire together in jjkysy's track.

- [ ] **Step 4: Run test + regenerate + build**

Run: `mix test apps/ezagent_plugin_world/test/mix/tasks/world_ui_codegen_test.exs && mix world.ui.codegen && mix world.ui.codegen --check`
Expected: tests PASS; barrel written; `--check` reports "in sync". Then `cd apps/ezagent_plugin_world/assets && pnpm build` (or the repo's esbuild command) succeeds — kanban still renders.

- [ ] **Step 5: Wire `--check` into the existing drift lane** — find where `mix world.slots.manifest --check` runs in CI (grep `world.slots.manifest` under `.github/` / `mix.exs` aliases) and add `world.ui.codegen --check` beside it.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_world/lib/mix/tasks/world.ui.codegen.ex \
        apps/ezagent_plugin_world/test/mix/tasks/world_ui_codegen_test.exs \
        apps/ezagent_plugin_world/assets/src/plugin-pages.generated.tsx \
        apps/ezagent_plugin_world/assets/src/main.tsx
git commit -m "feat(world/ui): build-time codegen of plugin-page renderer barrel from page/0"
```

---

## Task 6: Dissolve the `isHelloSession` special-case into the generic session-tab render path

> ⚠️ **See DECISION FOR CODEX D2.** Zyli delivers the *generic mechanism*; jjkysy deletes the final `isHelloSession` literal + moves `WorldHello`.

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:306` (the `isHelloSession = state.is_hello === true || sessionUri.includes("/hello/")` sniff and its two consumers at `:896`, `:1119`)
- Test: `apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx` (or the repo's TSX test harness)

**Interfaces:**
- Consumes: the already-serialized `WorkspacePluginData.plugin_session_tabs/1` output (`workspace_plugin_data.ex:498` — `[%{"id","label"}]`, condition-filtered per session), delivered in `state`. **No server change needed** — the mechanism exists; Task 6 makes the *frontend* consume it generically instead of sniffing.
- Produces: a generic "render the enumerated session tabs" path — `state.plugin_session_tabs` drives the tab bar + page pane, keyed to the codegen renderer map from Task 5.

- [ ] **Step 1: Write the failing test** — a Conversation render with a fixture `plugin_session_tabs` entry shows the tab generically; with none, no page tab:

```tsx
// Conversation.test.tsx (follow the repo's existing TSX render-test pattern)
it("renders a plugin-declared session tab generically (no isHelloSession sniff)", () => {
  const state = { plugin_session_tabs: [{ id: "page", label: "Page" }], /* ...minimal conv state... */ }
  render(<Conversation state={state} sessionUri="entity://acme/session/x" /* ... */ />)
  expect(screen.getByRole("tab", { name: "Page" })).toBeInTheDocument()
})

it("shows no page tab when no plugin declares a session tab for this session", () => {
  const state = { plugin_session_tabs: [], /* ... */ }
  render(<Conversation state={state} sessionUri="entity://acme/session/free" /* ... */ />)
  expect(screen.queryByRole("tab", { name: "Page" })).toBeNull()
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/ezagent_plugin_world/assets && pnpm test Conversation`
Expected: FAIL — the tab is currently gated by `isHelloSession`, not by `plugin_session_tabs`.

- [ ] **Step 3: Write minimal implementation** — replace the `isHelloSession` sniff (`:306`) and its two gates (`:896`, `:1119`) with rendering driven by `state.plugin_session_tabs` (an array from the server). The tab's page pane resolves its renderer via the Task-5 codegen map. Keep the `WorldHello` embed reachable **only** through a declared session tab (world/hello declares it; the transitional literal stays allowlisted until jjkysy moves it).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/ezagent_plugin_world/assets && pnpm test Conversation`
Expected: PASS — the tab is driven by the enumerated declaration.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_world/assets/src/components/Conversation.tsx \
        apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx
git commit -m "refactor(world/ui): drive session page tab from enumerated session_tabs (dissolve isHelloSession structure)"
```

---

## Task 7: Drift-prevention gate — `plugin_ui_self_declaration_gate_test.exs`

**Files:**
- Create: `apps/ezagent_plugin_world/test/ezagent/world/plugin_ui_self_declaration_gate_test.exs`

**Interfaces:**
- Consumes: `PluginPageRegistry.by_action/1` + `pages/0` (Tasks 2–4); the world source files as strings; `PluginRegistry` for the enumeration-derivability tooth.
- Produces: the four-tooth gate. Model the **positive-control + negative-carve-out** discipline verbatim from `apps/ezagent_core/test/invariants/no_surface_read_dispatch_detector_test.exs` (the detectors are proven to detect AND to not over-match) and the **source-enumerator** discipline from `slot_mount_gate_test.exs`.

**The allowlist is the migration tracker.** It starts non-empty (the world-side kanban `page/0` in `application.ex`, the generated barrel's kanban entry, the `isHelloSession` literal + `WorldHello` import) and shrinks to `[]` as jjkysy migrates each. The **empty-allowlist red build names every remaining hardcoded plugin touch-point** — the requested live debt inventory.

- [ ] **Step 1: Write the failing test** (the four teeth):

```elixir
defmodule Ezagent.World.PluginUiSelfDeclarationGateTest do
  @moduledoc """
  Drift gate: world holds NO plugin-specific truth. Extends the 3 existing
  enforcers (slot_mount_gate_test / by_action fail-closed / plugin_page_registry_test)
  with the NEW tooth — no plugin-name literal in world source. The allowlist is the
  migration tracker: red-with-inventory until world is a pure enumerator, then a
  permanent regression lock.
  """
  use ExUnit.Case, async: false

  @world_root Path.expand("../../..", __DIR__)
  # Source files that MUST end plugin-name-free (world's read-side + frontend host).
  @world_sources [
    "lib/ezagent/world/plugin_page_registry.ex",
    "lib/ezagent_plugin_world/world_live.ex",
    "assets/src/main.tsx",
    "assets/src/components/Conversation.tsx",
    "assets/src/slots.manifest.json"
  ]
  # Plugin-name literals that must not appear in world source.
  @plugin_literals ["kanban", "KanbanData", "KanbanActions", "isHelloSession", "WorldHello", "/hello/"]

  # ── NEW TOOTH allowlist — starts NON-EMPTY, shrinks to [] (jjkysy retires each) ──
  # Each entry: {relative_path, literal} known to still carry world-side plugin truth.
  @allowlist [
    {"lib/ezagent_plugin_world/application.ex", "kanban"},          # world's transitional page/0
    {"assets/src/plugin-pages.generated.tsx", "kanban"},            # generated barrel (from page/0)
    {"assets/src/plugin-pages.generated.tsx", "Kanban"},
    {"assets/src/components/Conversation.tsx", "WorldHello"},       # hello embed, pre-jjkysy move
    {"assets/src/main.tsx", "WorldHello"}                           # hello fallthrough import
  ]

  test "tooth 1 — no plugin-name literal in world source (outside the shrinking allowlist)" do
    offenders =
      for rel <- @world_sources,
          File.exists?(Path.join(@world_root, rel)),
          literal <- @plugin_literals,
          src = File.read!(Path.join(@world_root, rel)),
          String.contains?(src, literal),
          {rel, literal} not in @allowlist,
          do: "#{rel} still contains plugin literal #{inspect(literal)}"

    assert offenders == [],
           "world source carries plugin-specific truth (migrate it into the plugin's page/0 " <>
             "or add to @allowlist ONLY as a tracked transitional debt):\n" <> Enum.join(offenders, "\n")
  end

  test "tooth 2 — fail-closed admission: an undeclared action resolves to nil; a declared one resolves" do
    assert Ezagent.World.PluginPageRegistry.by_action("nonesuch.frobnicate") == nil
    assert Ezagent.World.PluginPageRegistry.by_action("kanban.drop_table") == nil  # prefix hit, not whitelisted
    assert %{key: _} = Ezagent.World.PluginPageRegistry.by_action("kanban.add_node")  # declared via page/0
  end

  test "tooth 3 — detectors are not vacuous (positive control + negative carve-out)" do
    # positive: the probe MATCHES a synthetic hardcoded fixture
    fixture = ~s|import {Kanban} from "./components/Kanban"|
    assert Enum.any?(@plugin_literals, &String.contains?(fixture, &1))
    # negative: world's own legitimate chrome is NOT a plugin literal
    chrome = ~s|import {WorkspaceSwitcher} from "./components/WorkspaceSwitcher"|
    refute Enum.any?(@plugin_literals, &String.contains?(chrome, &1))
  end

  test "tooth 4 — registration is enumeration-derivable (uninstalled ⇒ contributes nothing)" do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    keys = Enum.map(Ezagent.World.PluginPageRegistry.pages(), & &1.key)
    # every page key traces to an installed plugin that declares page/0:
    declared =
      Ezagent.PluginRegistry.list_all()
      |> Enum.filter(&function_exported?(&1, :page, 0))
      |> Enum.flat_map(& &1.page())
      |> Enum.map(& &1.key)
    assert Enum.sort(keys) == Enum.sort(declared),
           "pages/0 must be exactly the union of installed plugins' page/0 — no world-added extras"
  end
end
```

- [ ] **Step 2: Run test to verify it fails first, then passes** — tooth 1 fails if any un-allowlisted literal leaks (e.g. a stray `@kanban_actions` you missed); teeth 2/4 fail if Tasks 2–4 are incomplete. Fix until green.

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/plugin_ui_self_declaration_gate_test.exs`
Expected: PASS once world's only remaining kanban/hello literals are the allowlisted transitional ones.

- [ ] **Step 3: Add the dev-facing mirror note** — if `assets/scripts/check-mounts.mjs` is the dev mirror lane, add a sibling note or a `check-plugin-literals.mjs` mirror (optional; the ExUnit gate is authoritative — mirror only if the repo's convention requires it, per `slot_mount_gate_test.exs:33-51` lockstep discipline).

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_world/test/ezagent/world/plugin_ui_self_declaration_gate_test.exs
git commit -m "test(world/ui): drift gate — no plugin-name literal in world (shrinking allowlist inventory)"
```

---

## Final verification (before marking the branch ready-for-review)

- [ ] `mix compile --warnings-as-errors` (umbrella root) — no unreachable-clause / undefined warnings from the world_live clause reorder.
- [ ] `mix test apps/ezagent_plugin_world` — full world suite green (kanban renders end-to-end; nav/tab/page all enumeration-sourced).
- [ ] `mix world.slots.manifest --check` and `mix world.ui.codegen --check` — both "in sync".
- [ ] `cd apps/ezagent_plugin_world/assets && pnpm build && pnpm test` — frontend builds; Conversation + renderer tests green.
- [ ] Run the repo's invariant/gate lane (grep for how `slot_mount_gate_test` + `no_surface_read_dispatch` run in CI; e.g. `mix test --only invariants` or the `ci.local` equivalent) — the new drift gate participates.
- [ ] Confirm the drift-gate allowlist has **exactly** the transitional entries in Task 7 and nothing more — every non-allowlisted world source is plugin-literal-free.

---

## Self-review (spec coverage)

- Handoff "reverse the page-registry + action-allowlist data source (constants → runtime enumeration)" → **Task 2**.
- Handoff "the build-time codegen mix task enumerating `PluginRegistry.list_all/0`" → **Task 5** (+ the mandatory runtime conversions in Tasks 3–4 that the research glosses).
- Handoff "dissolve the session-page special-casing (isHelloSession)" → **Task 6** (mechanism; final literal = jjkysy, D2).
- Handoff "extend #1117 `UiSurfaceProvider`/`PluginPageRegistry`/`SlotRegistry` to cover the `page` surface + renderer face" → **Tasks 1, 2, 4, 5**.
- Handoff "drift gate — new tooth: world source contains no plugin-name literal; allowlist starts non-empty, shrinks to `[]`; fail-closed admission" → **Task 7** (4 teeth).
- Research §5.1 four-surface protocol (`page`/`actions`/`nav_surfaces`/`session_tabs`) → `nav_surfaces`/`session_tabs` pre-exist (#1117); `page` = Task 1; `actions` embedded in the page row per **D1**.
- Research §5.3 "world demotes to a thin enumerating shell" → world enumerates through its own `page/0` (Task 2), same path as any plugin (`slug: "world"`).

**Out of scope by design (jjkysy track, tracked by the shrinking allowlist):** moving `Kanban.tsx`/`WorldHello.tsx` into their plugins; declaring `page/0`/`session_tabs/0` on `ezagent_plugin_kanban`/`ezagent_plugin_hello`; deleting world's transitional declarations + the final `isHelloSession` literal; driving the allowlist to `[]`.
