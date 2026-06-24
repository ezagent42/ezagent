defmodule Ezagent.WorkspaceOwnerGateTest do
  use ExUnit.Case, async: false

  alias Ezagent.{RuntimeIdentity, WorkspacePlacement}

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "RuntimeIdentity.current/0 can be overridden in tests" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")

    assert RuntimeIdentity.current() == "test-node-a"
  end

  test "local WorkspacePlacement resolver owns every workspace by default" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:ok, "test-node-a"} = WorkspacePlacement.owner_of(workspace_uri)
    assert WorkspacePlacement.local_owner?(workspace_uri)
  end

  defp restore_env(module, nil), do: Application.delete_env(:ezagent_core, module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
