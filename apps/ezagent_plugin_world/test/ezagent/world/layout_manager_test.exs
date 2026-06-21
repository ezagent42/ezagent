defmodule Ezagent.World.LayoutManagerTest do
  use ExUnit.Case, async: false

  alias Ezagent.World.LayoutManager

  setup do
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

    {:ok, workspace_uri: Ezagent.URI.workspace(:system)}
  end

  test "writes and reads a validated layout under EZAGENT_HOME", %{workspace_uri: workspace_uri} do
    layout =
      workspace_uri
      |> LayoutManager.default_layout()
      |> move_sessions_first()

    assert {:ok, saved} = LayoutManager.write_layout(workspace_uri, layout)
    assert saved == LayoutManager.read_layout(workspace_uri)
    assert File.exists?(LayoutManager.layout_path(workspace_uri))

    assert ["sessions_table", "layout_editor"] =
             saved["components"] |> Enum.map(& &1["type"])
  end

  test "rejects unknown component types fail-closed", %{workspace_uri: workspace_uri} do
    layout =
      workspace_uri
      |> LayoutManager.default_layout()
      |> put_in(["components", Access.at!(0), "type"], "not_registered")

    assert {:error, {:unknown_component_type, "not_registered"}} =
             LayoutManager.write_layout(workspace_uri, layout)

    refute File.exists?(LayoutManager.layout_path(workspace_uri))
  end

  test "registers the PTY terminal component type" do
    assert MapSet.member?(LayoutManager.registered_component_types(), "pty_terminal")
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
