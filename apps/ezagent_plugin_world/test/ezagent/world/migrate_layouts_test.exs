defmodule Ezagent.World.MigrateLayoutsTest do
  @moduledoc """
  One-shot migration (plugin-resource SPEC §4.4 / HIGH-8): a legacy
  `world/layouts/<stem>.json` is re-keyed to `world-layouts/<ws>/<stem>` and the
  runtime resolver read returns the PRESERVED custom layout (no abandonment).

  Lives in the world suite (not core) because it round-trips through
  `Ezagent.World.LayoutManager.read_layout/2`, which requires the world plugin's
  `world-layouts` resource type to be registered (the world app is booted here).
  """
  use ExUnit.Case, async: false

  alias Ezagent.World.LayoutManager

  setup do
    # Self-contained registration of `world-layouts` — the runtime read below
    # resolves through it, and a full umbrella sweep can have wiped the boot
    # registration (see Ezagent.World.ResourceTypeCase / docs/futures/todo.md).
    :ok = Ezagent.World.ResourceTypeCase.ensure_world_layouts!()

    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(System.tmp_dir!(), "ezagent_world_migrate_#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf!(home)
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    :ok
  end

  test "moves a legacy layout file and the runtime read returns the preserved layout" do
    workspace_uri = Ezagent.URI.workspace(:system)
    scope = %{workspace: "system"}

    # A CUSTOM (non-default) layout, written into the LEGACY tree directly,
    # under the legacy filename scheme `<stem>.json`.
    custom =
      workspace_uri
      |> LayoutManager.default_layout()
      |> move_sessions_first()

    {:ok, validated} = LayoutManager.validate_layout(workspace_uri, custom)
    refute validated == LayoutManager.default_layout(workspace_uri)

    stem = LayoutManager.scope_key(workspace_uri)
    legacy_dir = Ezagent.Home.path("world/layouts")
    File.mkdir_p!(legacy_dir)
    File.write!(Path.join(legacy_dir, stem <> ".json"), Jason.encode!(validated))

    # Run the one-shot migration.
    Mix.Tasks.Ezagent.World.MigrateLayouts.run([])

    # New resolver path holds the preserved layout; old tree is gone.
    new_path = Path.join([Ezagent.Home.path("world-layouts"), "system", stem])
    assert File.exists?(new_path)
    refute File.exists?(legacy_dir)

    # The runtime read (resolver-only, no Home.path) returns the PRESERVED custom
    # layout — not the default.
    read_back = LayoutManager.read_layout(workspace_uri, scope)
    assert read_back == validated
    refute read_back == LayoutManager.default_layout(workspace_uri)
  end

  test "no legacy tree is a no-op" do
    # Nothing under world/layouts → the task reports and does not crash.
    assert :ok == Mix.Tasks.Ezagent.World.MigrateLayouts.run([])
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
