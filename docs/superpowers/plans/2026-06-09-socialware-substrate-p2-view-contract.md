# Socialware Substrate P2 — Unified View Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Unify the per-app *view* declaration so a single `Ezagent.UI.SessionView` contract can declare an **internal** LiveView render (as today) AND/OR an **external** render (the `customer_tree`/json-render projection consumed by the SPA via an ExternalAdapter), without changing how either render is produced for existing apps.

**Architecture:** Extend the existing `Ezagent.UI.SessionView` behaviour with two NEW **optional** callbacks — `external_render?/0` (declares the app has an external render target) and `external_render/1` (returns the json-render tree for a session). The internal `render/1` callback stays mandatory and unchanged. `@optional_callbacks` means internal-only views (ConversationView, TerminalView, RoutingView, ExternalMirror.View) implement neither and behave identically. `SessionViewRegistry` gains one query, `external_renderers/1`, returning the views that declare an external render for a session — the single registration point the future ExternalAdapter (P3) will consult instead of reaching into `Behavior.Surface` directly. `EzagentDomainSocialware.PageView` (which already produces the operator/internal tree via `Surface.operator_tree/1`) declares `external_render?/0 => true` and implements `external_render/1` by delegating to the **already-existing** `Ezagent.Behavior.Surface.customer_tree/1` — the exact function `Ezagent.Socialware.CustomerFeed` already calls. So the *declaration* of the two render targets is unified onto one contract while the *production* of each target is byte-for-byte the existing code path. The customer-delivery pipeline (CustomerFeed / CustomerChannel / customer_app.js) is **not touched** — that is P2.5/P3.

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_domain_ui`, `apps/ezagent_domain_socialware`, `apps/ezagent_plugin_liveview`), `Phoenix.Component`, `Ezagent.UI.SessionView` behaviour + `Ezagent.UI.SessionViewRegistry` (ETS), ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

---

## Background — grounded current state (the P2 surface)

The internal-view and external-render paths are **two disjoint code paths today**; P2 unifies only their *declaration*, additively.

**Internal-view path (the `SessionView` contract):**
- `Ezagent.UI.SessionView` (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`) — five mandatory `@callback`s: `id/0`, `label/0`, `icon/0`, `applies_to?/1`, `render/1`. No external-render concept exists.
- `Ezagent.UI.SessionViewRegistry` (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex`) — ETS-backed; `init/0`, `register/1`, `applicable_views/1` (filters by `applies_to?/1`), `lookup/1`, `all_ids/0`.
- Registered views: `EzagentPluginLiveview.Views.ConversationView` (`:conversation`, internal-only, `applies_to? => true`), `EzagentDomainSocialware.PageView` (`:page`), `EzagentDomainUi.Pty.TerminalView` (`:pty`), `EzagentDomainUi.Routing.RoutingView` (`:routing`), `EzagentDomainUi.ExternalMirror.View` (`:external_mirror`).
- Registration sites: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/application.ex:73-74` (Conversation + Page) and `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:86-90` (all five) and `apps/ezagent_domain_ui/lib/ezagent_domain_ui/application.ex:54-62` (Pty + Routing + ExternalMirror).
- Render dispatch: `AdminLive.resolve_view_render/1` → `SessionViewRegistry.lookup(view_id)` → `render_active_view/1` → `mod.render(assigns)` (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:872-894`).

**External-render path (NOT the view contract — ad-hoc on the Behavior):**
- `Ezagent.Behavior.Surface.customer_tree/1` (`apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex:99-106`) — renders the json-render tree from the **approved** surface version. `Surface.operator_tree/1` (`:92-97`) renders from the **latest** version.
- `EzagentDomainSocialware.PageView` (`apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex`) — its `render/1` (the SessionView internal callback) calls `Surface.operator_tree/1`. **It does NOT today expose `customer_tree` through any view contract** — that is the gap P2 closes.
- `Ezagent.Socialware.CustomerFeed.customer_page/1` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex:159`) calls `Surface.customer_tree/1` and is the SPA's source. **Not changed in P2.**

**Why "extend `SessionView`" over "new wrapper" (grounded in PageView).** PageView is already the one module that owns *both* the operator (internal) tree and knows the surface shape that produces the customer (external) tree — it sits next to `Surface` in the same app. The two targets already converge in one module; the only thing missing is a *contract* slot to declare the external one. Adding optional callbacks to the existing `SessionView` is the least-disruption realization of §3.4 "one declaration, two render targets": internal-only views need ZERO change (they simply don't implement the optional callbacks), and the registry/AdminLive paths for the internal render are untouched. A new wrapping contract would force re-registering all five views and re-pointing AdminLive — pure churn for no behavioral gain, and against project invariant `feedback_north_star_plugin_isolation` (keep plugin authors out of core boilerplate).

**Out of scope for P2 (explicit, per spec §6/§9):**
- P2 does **not** change the customer-delivery pipeline (CustomerFeed / CustomerChannel / Settlement / outbox) — that is **P2.5** (wire-schema + committed-delivery outbox) and **P3** (ExternalAdapter generalization). PageView's `external_render/1` reuses the existing `Surface.customer_tree/1`; it adds no new delivery, no PubSub, no cursor.
- P2 does **not** build `Behavior.ExternalAdapter` — that is P3. P2 only provides the *registration point* (`external_renderers/1`) the adapter will later consume.
- P2 does **not** do the maximal view collapse (internal LV rendering the same json-render tree) — explicitly deferred (§9). Internal LV render and external json-render stay two targets.
- The `auto_derive.ex` `build_detail/3` behavior-introspection display (flagged "DEFERRED to P2" as E11 in the P0/P1 plan) is **operator behavior-introspection display, not the render-target view contract of §3.4**, and is a P1-class instance-set-awareness concern. It is **NOT** part of this view-contract unification. See "Spec ambiguity resolved" at the end. P2 leaves it untouched.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex` | Modify | Add `external_render?/0` + `external_render/1` as `@optional_callbacks`; document the dual-target contract. |
| `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex` | Modify | Add `external_renderers/1` (views declaring an external render for a session) + `external_render?/1` helper that safely probes a module. |
| `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex` | Modify | Implement `external_render?/0 => true` + `external_render/1` delegating to `Ezagent.Behavior.Surface.customer_tree/1`. |
| `apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs` | Modify | Add a stub view declaring an external render + tests for `external_renderers/1` and `external_render?/1`; assert internal-only stubs are excluded. |
| `apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs` | Create | Test PageView declares + produces the external render via `customer_tree`, and that its internal `render/1` is unchanged. |

No new modules. The contract extension is two optional callbacks + one registry query + one PageView delegation.

---

## Task 1: Add optional external-render callbacks to the `SessionView` behaviour

**Files:**
- Modify: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`
- Test: `apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs` (covered in Task 2; Task 1 is a contract-only change verified by compile)

- [ ] **Step 1: Add the two optional callbacks + docs to the behaviour**

Edit `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`. After the existing `@callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()` (line 49) and before the closing `end`, insert:

```elixir
  @doc """
  P2 (unified view contract) — does this app declare an EXTERNAL render
  target (a `customer_tree`/json-render projection consumed by the SPA via
  an ExternalAdapter), in addition to (or instead of) the internal LiveView
  `render/1`?

  Optional. A view that does not implement this callback is INTERNAL-ONLY
  (the default, e.g. ConversationView) — the registry treats a missing
  callback as `false`. A view that returns `true` MUST implement
  `external_render/1`.

  The internal and external renders are two TARGETS behind ONE view
  declaration (spec §3.4, option A). This callback declares the external
  target exists; it does not change how the internal `render/1` works.
  """
  @callback external_render?() :: boolean()

  @doc """
  P2 — produce the EXTERNAL render for `session_uri`: the json-render tree
  (a plain map, the `customer_tree` shape) the SPA consumes. Returns `nil`
  when there is nothing to render externally yet (e.g. no approved/committed
  surface version).

  Optional — only views whose `external_render?/0` returns `true` need
  implement it. This is the json-render DATA tree, NOT a `Phoenix.Component`
  (the internal `render/1` returns the LiveView rendered struct; the external
  target is a serializable map rendered by the SPA / an ExternalAdapter).

  P2 NOTE: this is the per-app DECLARATION of the external render. It does
  NOT change the customer-delivery pipeline (CustomerFeed / CustomerChannel)
  — that is P2.5/P3. An implementation reuses the app's existing projection
  (e.g. socialware delegates to `Ezagent.Behavior.Surface.customer_tree/1`).
  """
  @callback external_render(session_uri :: URI.t()) :: map() | nil

  @optional_callbacks external_render?: 0, external_render: 1
```

- [ ] **Step 2: Compile to verify the behaviour is well-formed**

Run: `MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -20`
Expected: Compiles with no warnings. (No existing view implements the new callbacks; because they are in `@optional_callbacks`, the compiler does NOT warn about ConversationView/TerminalView/etc. missing them.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex
git commit -m "feat(socialware/p2): add optional external-render callbacks to SessionView contract

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `external_renderers/1` + `external_render?/1` to the registry

**Files:**
- Modify: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex`
- Test: `apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs`

- [ ] **Step 1: Write the failing tests**

In `apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs`, add a stub view that declares an external render. Insert this module after `CrashyView`'s `end` (line 69) and before `setup do` (line 71):

```elixir
  defmodule StubExternalView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_external

    @impl true
    def label, do: "External"

    @impl true
    def icon, do: "globe"

    @impl true
    def applies_to?(_session_uri), do: true

    @impl true
    def render(assigns), do: ~H"<div>stub external internal render</div>"

    @impl true
    def external_render?, do: true

    @impl true
    def external_render(_session_uri), do: %{type: "container", children: []}
  end

  # codex P2 review HIGH — a HALF-DECLARED view: declares `external_render?/0 =>
  # true` but OMITS `external_render/1`. The registry MUST NOT publish it as an
  # external renderer (else the future ExternalAdapter crashes invoking the
  # missing `external_render/1`).
  defmodule StubHalfDeclaredExternalView do
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :stub_half_declared

    @impl true
    def label, do: "Half"

    @impl true
    def icon, do: "globe"

    @impl true
    def applies_to?(_session_uri), do: true

    @impl true
    def render(assigns), do: ~H"<div>half-declared internal render</div>"

    @impl true
    def external_render?, do: true

    # external_render/1 intentionally NOT implemented.
  end
```

Then add this `describe` block immediately before the final `describe "all_ids/0"` block (currently line 163):

```elixir
  describe "external_render?/1" do
    test "is true for a view declaring external_render?/0 => true" do
      assert SessionViewRegistry.external_render?(StubExternalView) == true
    end

    test "is false for an internal-only view (no external_render?/0)" do
      assert SessionViewRegistry.external_render?(StubChatView) == false
    end

    test "is false for a HALF-DECLARED view: external_render?/0 true but no external_render/1 (codex P2 HIGH)" do
      assert SessionViewRegistry.external_render?(StubHalfDeclaredExternalView) == false
    end
  end

  describe "external_renderers/1" do
    test "returns only views that declare an external render for the session" do
      :ok = SessionViewRegistry.register(StubChatView)
      :ok = SessionViewRegistry.register(StubExternalView)

      uri = URI.new!("session://system/default/main")
      views = SessionViewRegistry.external_renderers(uri)
      ids = Enum.map(views, & &1.id)

      assert :stub_external in ids
      refute :stub_chat in ids
    end

    test "excludes an external view whose applies_to?/1 is false for the session" do
      defmodule StubExternalPtyOnly do
        @behaviour Ezagent.UI.SessionView
        use Phoenix.Component
        @impl true
        def id, do: :stub_external_pty
        @impl true
        def label, do: "ExtPty"
        @impl true
        def icon, do: "globe"
        @impl true
        def applies_to?(session_uri),
          do: String.contains?(URI.to_string(session_uri), "pty")
        @impl true
        def render(assigns), do: ~H"<div>x</div>"
        @impl true
        def external_render?, do: true
        @impl true
        def external_render(_uri), do: %{type: "container", children: []}
      end

      :ok = SessionViewRegistry.register(StubExternalPtyOnly)

      uri = URI.new!("session://system/default/main")
      ids = Enum.map(SessionViewRegistry.external_renderers(uri), & &1.id)
      refute :stub_external_pty in ids
    end

    test "each returned view exposes id, label, icon, module keys" do
      :ok = SessionViewRegistry.register(StubExternalView)
      uri = URI.new!("session://system/default/main")
      [view] = SessionViewRegistry.external_renderers(uri)

      assert %{id: :stub_external, label: "External", icon: "globe", module: StubExternalView} =
               view
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs -v 2>&1 | tail -30`
Expected: FAIL — `UndefinedFunctionError` / `function Ezagent.UI.SessionViewRegistry.external_render?/1 is undefined` and `.external_renderers/1 is undefined`.

- [ ] **Step 3: Implement `external_render?/1` + `external_renderers/1`**

Edit `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex`. Insert the two functions after `applicable_views/1`'s body and its `defp safe_applies_to/2` (i.e. after line 84, before `lookup/1` at line 86):

```elixir
  @doc """
  P2 — whether `view_module` declares a USABLE EXTERNAL render target.

  A view is an external renderer iff it exports BOTH `external_render?/0`
  AND `external_render/1` (both optional callbacks) AND `external_render?/0`
  returns `true`. Requiring `external_render/1` to ALSO be exported (codex
  P2 review HIGH) prevents publishing a half-declared view — one that says
  `external_render?/0 == true` but omits `external_render/1` — which would
  later crash the ExternalAdapter when it invokes the missing renderer.
  Internal-only views (neither callback) are `false`. The boolean probe is
  `function_exported?`-guarded + try/catch (same posture as
  `safe_applies_to/2`).
  """
  @spec external_render?(module()) :: boolean()
  def external_render?(view_module) when is_atom(view_module) do
    Code.ensure_loaded?(view_module) and
      function_exported?(view_module, :external_render?, 0) and
      function_exported?(view_module, :external_render, 1) and
      safe_external_render?(view_module)
  end

  defp safe_external_render?(mod) do
    mod.external_render?() == true
  catch
    _, _ -> false
  end

  @doc """
  P2 — all registered views that BOTH apply to `session_uri` AND declare an
  external render target. The single registration point the ExternalAdapter
  (P3) consults to discover a session's external render(s), instead of
  reaching into `Behavior.Surface` directly.

  Returns the same `%{id, label, icon, module}` shape as `applicable_views/1`,
  sorted by id.
  """
  @spec external_renderers(URI.t()) :: [
          %{id: atom(), label: String.t(), icon: String.t(), module: module()}
        ]
  def external_renderers(%URI{} = session_uri) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, mod} ->
      external_render?(mod) and safe_applies_to(mod, session_uri)
    end)
    |> Enum.map(fn {_id, mod} ->
      %{id: mod.id(), label: mod.label(), icon: mod.icon(), module: mod}
    end)
    |> Enum.sort_by(& &1.id)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs -v 2>&1 | tail -30`
Expected: PASS — all existing tests plus the new `external_render?/1` and `external_renderers/1` tests green.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs
git commit -m "feat(socialware/p2): SessionViewRegistry external_renderers/1 + external_render?/1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: PageView declares + produces the external render via `customer_tree`

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs`:

```elixir
defmodule EzagentDomainSocialware.PageViewExternalRenderTest do
  @moduledoc """
  P2 — PageView declares an external render target and produces it via the
  SAME projection the customer feed already uses (Surface.customer_tree/1).
  Internal render (operator_tree) is unaffected.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Surface
  alias EzagentDomainSocialware.PageView

  describe "external_render?/0" do
    test "PageView declares an external render target" do
      assert PageView.external_render?() == true
    end
  end

  describe "external_render/1" do
    test "returns nil when there is no approved version" do
      # Build a session with a surface slice that has versions but none approved.
      uri = put_surface(%{versions: %{1 => %{tree: %{type: "text", props: %{text: "draft"}}}}, approved: nil})

      assert PageView.external_render(uri) == nil
    end

    test "returns the APPROVED version tree (== Surface.customer_tree/1)" do
      tree = %{type: "text", props: %{text: "live page"}}
      surface = %{versions: %{1 => %{tree: tree}}, approved: 1}
      uri = put_surface(surface)

      assert PageView.external_render(uri) == Surface.customer_tree(surface)
      refute is_nil(PageView.external_render(uri))
    end
  end

  # Spawn a real socialware session and put the given surface slice on it so
  # PageView.external_render/1 reads it via Ezagent.Kind.get_slice/2 — the same
  # path PageView.render/1 uses for operator_tree.
  defp put_surface(surface) do
    uri = URI.new!("session://test-ext-render/default/" <> Ecto.UUID.generate())

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{uri: uri})

    :ok = Ezagent.Kind.put_slice(uri, :surface, surface)
    uri
  end
end
```

> **Bind-point note:** the test uses `Ezagent.Kind.spawn/2` (same call the existing socialware integration tests use to create a `SocialwareSession`) + `Ezagent.Kind.put_slice/3` + `Ezagent.Kind.get_slice/2` (the exact accessor PageView already calls in `load_surface/1` and `applies_to?/1`). If `put_slice/3` is not the available test-seeding accessor in this tree, fall back to dispatching `Ezagent.Behavior.Surface`'s `put_version`/`approve` actions via `Ezagent.Kind.dispatch/3` to reach `approved: 1` — confirm by reading `apps/ezagent_domain_socialware/test/integration/surface_dispatch_integration_test.exs` for the exact seeding idiom used there before writing the helper.

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs -v 2>&1 | tail -30`
Expected: FAIL — `function EzagentDomainSocialware.PageView.external_render?/0 is undefined` (and `.external_render/1 is undefined`).

- [ ] **Step 3: Implement the two callbacks on PageView**

Edit `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex`. After the existing `render/1` function's closing `"""` + `end` (line 60) and before `defp render_node/1` (line 62), insert:

```elixir
  @impl true
  def external_render?, do: true

  @impl true
  def external_render(%URI{} = session_uri) do
    session_uri
    |> load_surface()
    |> Surface.customer_tree()
  end

  def external_render(_), do: nil
```

(`load_surface/1` and the `alias Ezagent.Behavior.Surface` already exist in this module — reuse them; no new helper.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs -v 2>&1 | tail -30`
Expected: PASS — PageView declares `external_render? => true`, returns `nil` with no approved version, and returns exactly `Surface.customer_tree/1` for the approved version.

- [ ] **Step 5: Verify PageView's INTERNAL render is unchanged (behavior-preserving)**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -15`
Expected: PASS — the full socialware suite (including any existing PageView operator_tree tests + surface dispatch tests) is green; the additive callbacks did not change `render/1`.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex apps/ezagent_domain_socialware/test/ezagent_domain_socialware/page_view_external_render_test.exs
git commit -m "feat(socialware/p2): PageView declares external render via Surface.customer_tree

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Registry integration test — real registered views, dual-target discovery

**Files:**
- Test: `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/session_view_registry_integration_test.exs` (new file)

This proves the contract end-to-end with the REAL views: PageView is an external renderer; ConversationView is internal-only; both keep showing up in `applicable_views/1` (internal switcher) unchanged.

> **Why this test lives in `ezagent_plugin_liveview`, NOT `ezagent_domain_ui` (codex P2 review MEDIUM):** `Ezagent.UI.SessionView`/`SessionViewRegistry` live in `ezagent_domain_ui`, which the concrete views *depend on* — `ezagent_domain_ui` must NOT depend back on `EzagentDomainSocialware.PageView` or `EzagentPluginLiveview.Views.ConversationView` (that would invert the dependency and create a cycle). `apps/ezagent_plugin_liveview` already depends on both the socialware domain and the registry (it references both modules at `admin_live.ex:86-90`), so it is the one place where this integration assertion is a legal compile-time dependency. Do NOT add socialware/liveview to `ezagent_domain_ui`'s deps to work around this.

- [ ] **Step 1: Write the failing test**

Create `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/session_view_registry_integration_test.exs` with this content:

```elixir
defmodule EzagentPluginLiveview.SessionViewRegistryIntegrationTest do
  use ExUnit.Case, async: false

  alias Ezagent.UI.SessionViewRegistry

  describe "P2 contract — real views" do
    test "PageView is an external renderer; ConversationView is internal-only" do
      assert SessionViewRegistry.external_render?(EzagentDomainSocialware.PageView) == true

      assert SessionViewRegistry.external_render?(
               EzagentPluginLiveview.Views.ConversationView
             ) == false
    end

    test "registering both — applicable_views still lists both (internal switcher unchanged)" do
      :ok = SessionViewRegistry.register(EzagentPluginLiveview.Views.ConversationView)
      :ok = SessionViewRegistry.register(EzagentDomainSocialware.PageView)

      uri = URI.new!("session://system/default/main")
      internal_ids = Enum.map(SessionViewRegistry.applicable_views(uri), & &1.id)

      # ConversationView applies to every session; it must still appear.
      assert :conversation in internal_ids
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails (before, in a clean checkout) / passes (now)**

Run: `MIX_ENV=test mix test apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/session_view_registry_integration_test.exs -v 2>&1 | tail -25`
Expected: PASS — because Tasks 1–3 already implemented the contract. (This test is the *integration* assertion against the real modules; if Task 3 were reverted, the first assertion would FAIL with `external_render?(PageView) == false`, proving the test bites.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/session_view_registry_integration_test.exs
git commit -m "test(socialware/p2): registry contract integration with real PageView + ConversationView

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: E2E acceptance gate (§7) — arch fitness + regression suites green

**Files:** none (verification-only task). Per project invariant `feedback_completion_requires_invariant_test`, this gate is what proves P2 met its architectural goal (a unified declaration) without regressing existing behavior.

The customer-SPA agent-browser visual E2E (§7 "External adapters") is **author-owned and is NOT exercised by P2**, because P2 does not change the customer-delivery pipeline — it only adds the external-render *declaration* reusing `Surface.customer_tree/1`. The visual E2E becomes load-bearing at **P3** (when the ExternalAdapter consumes `external_renderers/1` instead of calling `Surface.customer_tree/1` directly) and **P2.5** (committed-delivery outbox). Flag this to the orchestrator. P2's gate is the arch fitness gates + the regression suites that exercise the view contract.

- [ ] **Step 1: Arch fitness gates**

Run (each must exit 0):
```bash
MIX_ENV=test mix compile --warnings-as-errors --force 2>&1 | tail -5
MIX_ENV=test mix ezagent.arch.scan 2>&1 | tail -10
MIX_ENV=test mix ezagent.check_invariants 2>&1 | tail -10
MIX_ENV=test mix ezagent.check_invariants.lifecycle 2>&1 | tail -10
```
Expected: all pass / exit 0. (P2 touches no `use Ezagent.Behavior`/`init_slice`/dispatch surface, so `.lifecycle` and `arch.scan` should be unaffected — confirm they stay green.)

- [ ] **Step 2: View-contract regression suites**

Run:
```bash
MIX_ENV=test mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/session_view_registry_test.exs 2>&1 | tail -10
MIX_ENV=test mix test apps/ezagent_plugin_liveview/test/admin_live_test.exs 2>&1 | tail -10
MIX_ENV=test mix test apps/ezagent_plugin_liveview/test/admin_live_routing_view_test.exs 2>&1 | tail -10
```
Expected: all PASS. `admin_live_test.exs` exercises the SessionView view-switcher (the `id="view-switcher"` + "Chat"/ConversationView assertions at lines 30-38, 160-165) — this is the §7 "the liveview AdminLive view-switcher tests that exercise SessionView" gate; it must be unchanged.

- [ ] **Step 3: Socialware + instance_message regression suites**

Run:
```bash
MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -10
MIX_ENV=test mix test apps/ezagent_domain_instance_message/test 2>&1 | tail -10
```
Expected: all PASS — the §7 "Socialware" + "instance_message" regression sets are green on the new contract (surface put_version→approve, settlement commit, customer-visibility gating unchanged; PageView operator_tree unchanged).

- [ ] **Step 4: Confirm no behavior change to internal-only views**

Run:
```bash
MIX_ENV=test mix test apps/ezagent_domain_ui/test apps/ezagent_plugin_liveview/test 2>&1 | tail -10
```
Expected: PASS — ConversationView / TerminalView / RoutingView / ExternalMirror.View (all internal-only, none implementing the optional callbacks) render and register identically.

- [ ] **Step 5: Record the gate result**

No commit (verification task). If any suite fails: per invariant `feedback_e2e_failure_earns_unit_test`, add a fast regression test reproducing the failure BEFORE fixing, then re-run this whole gate. Do not claim P2 complete until Steps 1–4 are all green.

---

## Self-Review

**1. Spec coverage (§3.4 / §6 P2):**
- §3.4 "one View declaration per app, declaring an internal render AND/OR an external render" → Task 1 (optional callbacks on `SessionView`) + Task 3 (PageView declares both). ✓
- §3.4 "internal-only (chat today), external-only, or both (socialware)" → ConversationView stays internal-only (Task 4 asserts `external_render?(ConversationView) == false`); PageView is both (Task 3). External-only is *expressible* (a view with `external_render? => true` whose internal `render/1` is a placeholder) — not built in P2 because no current app needs it (YAGNI); the contract supports it. ✓
- §3.4 "two render targets live behind one registration contract" → Task 2 `external_renderers/1` is that single registration point. ✓
- §6 P2 "Extend the View contract to declare internal-LV and/or external render targets; register existing views through it" → Tasks 1–4. ✓
- §6 P2 Gate "operator AdminLive renders all current views identically" → Task 5 Step 2 (admin_live_test view-switcher) + Step 4. ✓
- §9 "maximal view collapse deferred; P2 keeps internal LV + external render as two targets" → honored: `render/1` (LV) and `external_render/1` (json-render map) are distinct callbacks/return types. ✓
- §7 E2E gate → Task 5; customer-SPA visual E2E correctly flagged author-owned / P3-relevant. ✓
- Behavior-preserving (additive) → `@optional_callbacks`; Task 3 Step 5 + Task 5 Step 4 assert internal-only views unchanged. ✓
- "P2 does NOT change customer-delivery pipeline" → Task 3 reuses existing `Surface.customer_tree/1`; no CustomerFeed/Channel/Settlement edits in any task. ✓

**2. Placeholder scan:** No "TBD"/"implement later"/"add validation"/"similar to Task N". Every code step shows real Elixir; every run step shows the exact `mix` command + expected outcome. Two bind-point notes (Task 3 test-seeding idiom, Task 4 cross-app dep) name the EXACT module/function/file to confirm against (`surface_dispatch_integration_test.exs`, `apps/ezagent_domain_ui/mix.exs deps/0`, `admin_live.ex:86-90`) rather than leaving a vague placeholder — these are unavoidable env-specific bindings the implementer must verify, not design gaps. ✓

**3. Type/signature consistency:**
- `external_render?/0 :: boolean()` — defined Task 1, implemented Task 3 (`def external_render?, do: true`), probed Task 2 (`function_exported?(mod, :external_render?, 0)` + `mod.external_render?() == true`). Consistent. ✓
- `external_render/1 :: (URI.t()) -> map() | nil` — defined Task 1, implemented Task 3 (returns `Surface.customer_tree/1` result, which is `map() | nil` per `surface.ex:99-106`). Consistent. ✓
- `external_renderers/1 :: (URI.t()) -> [%{id, label, icon, module}]` — defined + implemented Task 2, asserted Task 2 + Task 4. Same map shape as `applicable_views/1`. Consistent. ✓
- `external_render?/1` (registry, takes a module) vs `external_render?/0` (behaviour callback, no args) — distinct arities, distinct callers; the registry's `external_render?/1` wraps the module's `external_render?/0`. Intentional + consistent. ✓

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-09-socialware-substrate-p2-view-contract.md`.** This plan is codex-reviewed by the orchestrator before execution (project policy `feedback_codex_review_every_pr` / `feedback_spec_codex_adversarial_review`). After review, two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task (each loading `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`), two-stage review between tasks.
2. **Inline Execution** — execute tasks in-session with checkpoints.
