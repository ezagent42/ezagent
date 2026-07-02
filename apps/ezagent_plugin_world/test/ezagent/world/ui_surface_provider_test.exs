defmodule Ezagent.World.UiSurfaceProviderTest do
  @moduledoc """
  Pins the World-side plugin-UI-surface contract `Ezagent.World.UiSurfaceProvider`
  — the read-time shape predicates moved OUT of core's
  `Ezagent.Plugin.SurfaceValidator` / `:ezagent_plugin_check` gate (2026-06-30,
  decision (a): nav_surfaces/0 + session_tabs/0 are World-UI concepts, not core
  `Ezagent.Plugin` callbacks).
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.UiSurfaceProvider

  describe "valid_nav_surface?/1" do
    test "accepts %{label, path} of binaries" do
      assert UiSurfaceProvider.valid_nav_surface?(%{label: "看板", path: "/plugins/kanban"})
    end

    test "accepts an optional binary :icon" do
      assert UiSurfaceProvider.valid_nav_surface?(%{label: "I", path: "/p", icon: "folder"})
    end

    test "rejects a non-binary :icon" do
      refute UiSurfaceProvider.valid_nav_surface?(%{label: "I", path: "/p", icon: :folder})
    end

    test "rejects a missing path / non-binary label / non-map" do
      refute UiSurfaceProvider.valid_nav_surface?(%{label: "看板"})
      refute UiSurfaceProvider.valid_nav_surface?(%{label: :看板, path: "/p"})
      refute UiSurfaceProvider.valid_nav_surface?(:not_a_map)
    end
  end

  describe "valid_session_tab?/1" do
    test "accepts %{id, label} with no condition (defaults always-visible)" do
      assert UiSurfaceProvider.valid_session_tab?(%{id: "kanban", label: "看板"})
    end

    test "accepts :always and a 1-arity condition" do
      assert UiSurfaceProvider.valid_session_tab?(%{id: "k", label: "看板", condition: :always})

      assert UiSurfaceProvider.valid_session_tab?(%{
               id: "k",
               label: "看板",
               condition: fn _ -> true end
             })
    end

    test "rejects a missing id/label, a non-binary label, a wrong-arity condition" do
      refute UiSurfaceProvider.valid_session_tab?(%{label: "看板"})
      refute UiSurfaceProvider.valid_session_tab?(%{id: "k", label: :看板})

      refute UiSurfaceProvider.valid_session_tab?(%{
               id: "k",
               label: "看板",
               condition: fn _a, _b -> true end
             })

      refute UiSurfaceProvider.valid_session_tab?(%{id: "k", label: "看板", condition: :nope})
      refute UiSurfaceProvider.valid_session_tab?(:not_a_map)
    end
  end
end
