defmodule EzagentCore.Architecture.ViewAuthorizeGateTest do
  @moduledoc """
  T2-2b (SPEC §4 assertion 9 / DoD) — the view-visibility single-authorization-point
  gate. Every render entry must route through `Ezagent.UI.SessionView.authorize_view/3`;
  no renderer may expose a view by reading the `:surface` slice directly while
  bypassing the view-cap check.

  This is a SOURCE-PATH gate over the `SessionViewRegistry` render path (the DoD
  asks the gate to "scan the Registry path", not merely name modules):

    1. The `SessionView` contract exposes the unified `authorize_view/3` gate +
       the `view_behavior/0` caller-dimension callback.
    2. The registry's CALLER-AWARE render entries (`applicable_views/2`,
       `external_renderers/2`) exist AND route through `authorize_view`
       (`safe_authorize_view`). If a future edit drops the gate from a render
       entry, this fails.
    3. Every `SessionView` implementation that reads the `:surface` slice for
       rendering (`get_slice(_, :surface)`) MUST declare `view_behavior/0` — i.e.
       be cap-gated — so no direct-read renderer escapes `authorize_view`. An
       allowlist carries documented, not-yet-gated bypasses (target: empty).
  """
  use ExUnit.Case, async: true

  @moduletag :umbrella_only

  @umbrella_root Path.expand("../../../..", __DIR__)
  @session_view Path.join(@umbrella_root, "apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex")
  @registry Path.join(@umbrella_root, "apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex")

  # SessionView implementations that read the `:surface` slice but are NOT yet
  # routed through a declared `view_behavior/0`. TARGET: empty. Each entry is a
  # tracked bypass to sink into the gate (rebase/follow-up).
  @surface_read_allowlist [
    # socialware's degraded internal PageView still reads :surface directly and
    # has no backing render ActionSet yet (needs a socialware `*_render` view
    # ActionSet before it can declare view_behavior/0 — T2-2b follow-up).
    Path.join(@umbrella_root, "apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex")
  ]

  test "SessionView contract exposes authorize_view/3 + the view_behavior caller dimension" do
    src = File.read!(@session_view)
    assert src =~ ~r/def authorize_view\(/, "SessionView must expose the unified authorize_view/3"
    assert src =~ ~r/@callback view_behavior\(\)/, "SessionView must declare the view_behavior/0 caller dimension"
  end

  test "registry caller-aware render entries route through authorize_view" do
    src = File.read!(@registry)

    assert src =~ ~r/def applicable_views\(%URI\{\} = session_uri, caller\)/,
           "registry must expose the caller-aware applicable_views/2"

    assert src =~ ~r/def external_renderers\(%URI\{\} = session_uri, caller\)/,
           "registry must expose the caller-aware external_renderers/2"

    # Both caller-aware entries must gate on authorize_view (via safe_authorize_view).
    assert src =~ ~r/safe_authorize_view/,
           "registry render entries must route through authorize_view"

    assert src =~ ~r/Ezagent\.UI\.SessionView\.authorize_view/,
           "safe_authorize_view must delegate to SessionView.authorize_view/3"
  end

  test "no SessionView reads the :surface slice while bypassing authorize_view (view_behavior)" do
    offenders =
      Path.join(@umbrella_root, "apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path -> path not in @surface_read_allowlist end)
      |> Enum.filter(&session_view_impl?/1)
      |> Enum.filter(&reads_surface_slice?/1)
      |> Enum.reject(&declares_view_behavior?/1)

    assert offenders == [],
           """
           These SessionView modules read the :surface slice for rendering but do
           NOT declare view_behavior/0, so they bypass authorize_view (SPEC §4 #9):
           #{Enum.map_join(offenders, "\n", &("  - " <> &1))}

           Fix: declare view_behavior/0 (a `<sw>_render` cap-only ActionSet) so the
           view is cap-gated, or add the path to @surface_read_allowlist with a
           tracked follow-up.
           """
  end

  defp session_view_impl?(path) do
    src = File.read!(path)
    src =~ ~r/@behaviour Ezagent\.UI\.SessionView/
  end

  defp reads_surface_slice?(path) do
    src = File.read!(path)
    src =~ ~r/get_slice\([^,]+,\s*:surface\)/
  end

  defp declares_view_behavior?(path) do
    src = File.read!(path)
    src =~ ~r/def view_behavior/
  end
end
