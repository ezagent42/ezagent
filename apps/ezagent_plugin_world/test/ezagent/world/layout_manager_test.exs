defmodule Ezagent.World.LayoutManagerTest do
  use ExUnit.Case, async: false

  alias Ezagent.World.LayoutManager

  setup do
    # Make the suite self-contained w.r.t. `world-layouts` rather than depending
    # on the boot registration surviving a full umbrella sweep (a sibling core
    # suite restarts the resolver Registry, which does NOT replay plugin types —
    # see Ezagent.World.ResourceTypeCase / docs/futures/todo.md).
    :ok = Ezagent.World.ResourceTypeCase.ensure_world_layouts!()

    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(System.tmp_dir!(), "ezagent_world_layout_#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf!(home)
    end)

    workspace_uri = Ezagent.URI.workspace(:system)
    # The caller scope is the AUTHENTICATED context, threaded SEPARATELY from the
    # target URI (R-3). For a same-workspace caller it matches; foreign-ws cases
    # below deliberately supply a DIFFERENT scope.
    scope = %{workspace: "system"}

    {:ok, workspace_uri: workspace_uri, scope: scope}
  end

  test "write → read round-trips through the resolver under the caller scope", %{
    workspace_uri: workspace_uri,
    scope: scope
  } do
    layout =
      workspace_uri
      |> LayoutManager.default_layout()
      |> move_sessions_first()

    assert {:ok, saved} = LayoutManager.write_layout(workspace_uri, layout, scope)
    assert saved == LayoutManager.read_layout(workspace_uri, scope)

    assert ["sessions_table", "layout_editor"] =
             saved["components"] |> Enum.map(& &1["type"])
  end

  test "rejects unknown component types fail-closed (no write)", %{
    workspace_uri: workspace_uri,
    scope: scope
  } do
    layout =
      workspace_uri
      |> LayoutManager.default_layout()
      |> put_in(["components", Access.at!(0), "type"], "not_registered")

    assert {:error, {:unknown_component_type, "not_registered"}} =
             LayoutManager.write_layout(workspace_uri, layout, scope)

    # Nothing persisted → a read falls back to the default layout.
    assert LayoutManager.read_layout(workspace_uri, scope) ==
             LayoutManager.default_layout(workspace_uri)
  end

  test "both-miss read falls back to default_layout", %{
    workspace_uri: workspace_uri,
    scope: scope
  } do
    # No file written → read returns the default.
    assert LayoutManager.read_layout(workspace_uri, scope) ==
             LayoutManager.default_layout(workspace_uri)
  end

  describe "R-3 (codex HIGH-4) — caller scope is independent of the target URI" do
    test "a FOREIGN-workspace target read under a different caller scope is NOT resolved" do
      victim_uri = Ezagent.URI.workspace("victim")
      victim_scope = %{workspace: "victim"}

      # 1. Plant the victim's CUSTOM layout under the MATCHING caller scope.
      custom =
        victim_uri
        |> LayoutManager.default_layout()
        |> move_sessions_first()

      assert {:ok, saved_custom} = LayoutManager.write_layout(victim_uri, custom, victim_scope)
      # confirm the custom layout really differs from the default (load-bearing).
      refute saved_custom == LayoutManager.default_layout(victim_uri)

      # 2. Read the SAME target under an ATTACKER caller scope. The resolver's
      #    authority sees uri-ws "victim" ≠ scope "attacker" → reject → fall to
      #    default_layout. The foreign bytes must NOT be returned.
      attacker_scope = %{workspace: "attacker"}
      result = LayoutManager.read_layout(victim_uri, attacker_scope)

      assert result == LayoutManager.default_layout(victim_uri)
      refute result == saved_custom
    end

    test "a FOREIGN-workspace target write under a different caller scope is rejected (no write)" do
      victim_uri = Ezagent.URI.workspace("victim")
      attacker_scope = %{workspace: "attacker"}

      layout = LayoutManager.default_layout(victim_uri)

      assert {:error, {:foreign_workspace, _}} =
               LayoutManager.write_layout(victim_uri, layout, attacker_scope)

      # And nothing leaked under victim's path — a legitimate victim read still
      # returns the default (no file written).
      assert LayoutManager.read_layout(victim_uri, %{workspace: "victim"}) ==
               LayoutManager.default_layout(victim_uri)
    end
  end

  defp move_sessions_first(layout) do
    [editor, sessions] = layout["components"]

    %{
      layout
      | "components" => [
          %{sessions | "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 6}},
          %{editor | "placement" => %{"x" => 0, "y" => 6, "w" => 12, "h" => 2}}
        ]
    }
  end
end
