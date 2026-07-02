defmodule Ezagent.World.PluginNavSurfacesTest do
  @moduledoc """
  Pins the Layer-2 modular-nav backend serializer
  (`WorkspacePluginData.plugin_nav_surfaces/0`) — board-entry-and-modular-ui
  §2/§7.

  The serializer reuses the same `PluginRegistry.list_all/0` traversal as
  `list_plugins/0`: it reads every INSTALLED plugin that DECLARES `nav_surfaces/0`
  (the World-side `Ezagent.World.UiSurfaceProvider` convention, duck-typed via
  `function_exported?/3`) and serializes to JSON-safe `[%{"label", "path"}]`
  (+ optional `"icon"`). An uninstalled plugin is not in the registry, so it
  contributes no entry — "没插件就没入口". This test also pins the duck-typed
  mechanism: the fixtures define a PLAIN `nav_surfaces/0` (no core
  `@impl Ezagent.Plugin`), implementing the world-side behaviour.
  """
  use ExUnit.Case, async: false

  alias Ezagent.World.WorkspacePluginData

  defmodule NavFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{
        slug: "world-nav-fixture",
        name: "Nav Fixture",
        description: "test",
        version: "1.0.0"
      }

    @impl Ezagent.World.UiSurfaceProvider
    def nav_surfaces, do: [%{label: "看板", path: "/plugins/kanban"}]
  end

  defmodule NavIconFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{
        slug: "world-nav-icon-fixture",
        name: "Nav Icon Fixture",
        description: "test",
        version: "1.0.0"
      }

    @impl Ezagent.World.UiSurfaceProvider
    def nav_surfaces, do: [%{label: "Icons", path: "/plugins/icons", icon: "folder"}]
  end

  # A plugin that does NOT define nav_surfaces/0 at all — under the duck-typed
  # model (no core `use Ezagent.Plugin` default), world's `function_exported?/3`
  # guard must skip it WITHOUT raising UndefinedFunctionError.
  defmodule NoSurfaceFixturePlugin do
    use Ezagent.Plugin

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-nav-none", name: "No Surface", description: "test", version: "1.0.0"}
  end

  # A plugin whose nav_surfaces/0 has ONE malformed entry mixed with a good one
  # — read-time `valid_nav_surface?/1` filtering must drop only the bad entry.
  defmodule MalformedNavFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-nav-bad", name: "Malformed Nav", description: "test", version: "1.0.0"}

    @impl Ezagent.World.UiSurfaceProvider
    def nav_surfaces,
      do: [%{label: "Good", path: "/plugins/good"}, %{label: "NoPath"}]
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    :ok
  end

  test "serializes an installed plugin's nav_surfaces into JSON-safe string-keyed rows" do
    :ok = Ezagent.PluginRegistry.register(NavFixturePlugin)

    rows = WorkspacePluginData.plugin_nav_surfaces()

    assert %{"label" => "看板", "path" => "/plugins/kanban"} in rows

    # JSON-safe: string keys, binary values, no extra keys when no icon
    entry = Enum.find(rows, &(&1["path"] == "/plugins/kanban" and &1["label"] == "看板"))
    assert Map.keys(entry) |> Enum.sort() == ["label", "path"]
  end

  test "carries an optional :icon through as a string key" do
    :ok = Ezagent.PluginRegistry.register(NavIconFixturePlugin)

    rows = WorkspacePluginData.plugin_nav_surfaces()

    assert %{"label" => "Icons", "path" => "/plugins/icons", "icon" => "folder"} in rows
  end

  test "returns a list (empty when no plugin declares nav_surfaces)" do
    # Whatever is registered, the contract is a list of string-keyed maps.
    rows = WorkspacePluginData.plugin_nav_surfaces()
    assert is_list(rows)
    assert Enum.all?(rows, fn row -> is_map(row) and is_binary(row["label"]) end)
  end

  test "a plugin that does NOT define nav_surfaces/0 contributes nothing (no crash)" do
    # Duck-typed guard: with the core `use Ezagent.Plugin` default gone, a plugin
    # absent the function must be skipped, not raise UndefinedFunctionError.
    :ok = Ezagent.PluginRegistry.register(NoSurfaceFixturePlugin)

    rows = WorkspacePluginData.plugin_nav_surfaces()
    assert is_list(rows)
    refute Enum.any?(rows, &(&1["label"] == "No Surface"))
  end

  test "read-time validation drops only a malformed entry, keeps the good one" do
    :ok = Ezagent.PluginRegistry.register(MalformedNavFixturePlugin)

    rows = WorkspacePluginData.plugin_nav_surfaces()
    assert %{"label" => "Good", "path" => "/plugins/good"} in rows
    # the malformed `%{label: "NoPath"}` (no :path) is filtered out
    refute Enum.any?(rows, &(&1["label"] == "NoPath"))
  end
end
