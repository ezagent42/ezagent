defmodule Ezagent.World.PluginSessionTabsTest do
  @moduledoc """
  Pins the Layer-3 modular-UI backend serializer
  (`WorkspacePluginData.plugin_session_tabs/1`) — board-entry-and-modular-ui
  §1/§2.

  The serializer reuses the same `PluginRegistry.list_all/0` traversal as
  `plugin_nav_surfaces/0`: it reads every INSTALLED plugin that DECLARES
  `session_tabs/0` (the World-side `Ezagent.World.UiSurfaceProvider` convention,
  duck-typed via `function_exported?/3`), keeps the tabs whose `:condition` holds
  for the given session URI, and serializes to JSON-safe `[%{"id", "label"}]`. An
  uninstalled plugin contributes nothing — "没插件就没 tab". The fixtures define a
  PLAIN `session_tabs/0` (no core `@impl Ezagent.Plugin`), pinning the duck-typed
  mechanism.
  """
  use ExUnit.Case, async: false

  alias Ezagent.World.WorkspacePluginData

  @bound "session://system/default/bound"

  defmodule TabFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-tab-fixture", name: "Tab Fixture", description: "test", version: "1.0.0"}

    # condition: visible only for the one bound session URI.
    @impl Ezagent.World.UiSurfaceProvider
    def session_tabs,
      do: [%{id: "kanban", label: "看板", condition: &__MODULE__.bound?/1}]

    def bound?(session_uri), do: session_uri == "session://system/default/bound"
  end

  defmodule AlwaysTabFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-tab-always", name: "Always Tab", description: "test", version: "1.0.0"}

    @impl Ezagent.World.UiSurfaceProvider
    def session_tabs, do: [%{id: "always", label: "Always", condition: :always}]
  end

  # A plugin that does NOT define session_tabs/0 — the duck-typed
  # `function_exported?/3` guard must skip it, not raise.
  defmodule NoTabFixturePlugin do
    use Ezagent.Plugin

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-tab-none", name: "No Tab", description: "test", version: "1.0.0"}
  end

  # A plugin whose session_tabs/0 mixes a good tab with a malformed one —
  # read-time `valid_session_tab?/1` filtering must drop only the bad entry.
  defmodule MalformedTabFixturePlugin do
    use Ezagent.Plugin
    @behaviour Ezagent.World.UiSurfaceProvider

    @impl Ezagent.Plugin
    def plugin_info,
      do: %{slug: "world-tab-bad", name: "Malformed Tab", description: "test", version: "1.0.0"}

    @impl Ezagent.World.UiSurfaceProvider
    def session_tabs,
      do: [%{id: "good", label: "Good", condition: :always}, %{label: "NoId", condition: :always}]
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    :ok
  end

  test "includes a conditional tab ONLY for a session whose condition holds" do
    :ok = Ezagent.PluginRegistry.register(TabFixturePlugin)

    bound = WorkspacePluginData.plugin_session_tabs(@bound)
    assert %{"id" => "kanban", "label" => "看板"} in bound

    other = WorkspacePluginData.plugin_session_tabs("session://system/default/other")
    refute Enum.any?(other, &(&1["id"] == "kanban"))
  end

  test "an :always condition tab shows for any session" do
    :ok = Ezagent.PluginRegistry.register(AlwaysTabFixturePlugin)

    rows = WorkspacePluginData.plugin_session_tabs("session://system/default/whatever")
    assert %{"id" => "always", "label" => "Always"} in rows
  end

  test "accepts a %URI{} session and serializes JSON-safe string-keyed rows" do
    :ok = Ezagent.PluginRegistry.register(TabFixturePlugin)

    rows = WorkspacePluginData.plugin_session_tabs(URI.new!(@bound))
    entry = Enum.find(rows, &(&1["id"] == "kanban"))
    assert Map.keys(entry) |> Enum.sort() == ["id", "label"]
  end

  test "returns a list of string-keyed maps (contract)" do
    rows = WorkspacePluginData.plugin_session_tabs(@bound)
    assert is_list(rows)
    assert Enum.all?(rows, fn r -> is_map(r) and is_binary(r["id"]) and is_binary(r["label"]) end)
  end

  test "a plugin that does NOT define session_tabs/0 contributes nothing (no crash)" do
    :ok = Ezagent.PluginRegistry.register(NoTabFixturePlugin)

    rows = WorkspacePluginData.plugin_session_tabs(@bound)
    assert is_list(rows)
    refute Enum.any?(rows, &(&1["label"] == "No Tab"))
  end

  test "read-time validation drops only a malformed tab, keeps the good one" do
    :ok = Ezagent.PluginRegistry.register(MalformedTabFixturePlugin)

    rows = WorkspacePluginData.plugin_session_tabs("session://system/default/whatever")
    assert %{"id" => "good", "label" => "Good"} in rows
    # the malformed `%{label: "NoId"}` (no :id) is filtered out
    refute Enum.any?(rows, &(&1["label"] == "NoId"))
  end
end
