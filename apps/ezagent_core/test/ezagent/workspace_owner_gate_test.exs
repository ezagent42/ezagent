defmodule Ezagent.WorkspaceOwnerGateTest do
  use ExUnit.Case, async: false

  alias Ezagent.{RuntimeIdentity, WorkspacePlacement}

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement

    @impl true
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  defmodule UnknownResolver do
    @behaviour Ezagent.WorkspacePlacement

    @impl true
    def owner_of(%URI{scheme: "workspace"}), do: {:error, :not_found}
  end

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

  test "assert_local_owner/2 returns :ok when current runtime owns workspace" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    target_uri = Ezagent.URI.new!("session://team-alpha/default/main")

    assert :ok =
             Ezagent.WorkspaceOwnerGate.assert_local_owner(
               workspace_uri,
               {:dispatch, target_uri}
             )
  end

  test "assert_local_owner/2 fails closed for a remote owner in enforce mode" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")
    Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver)
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    target_uri = Ezagent.URI.new!("session://team-alpha/default/main")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "test-node-a",
             {:dispatch, ^target_uri}}} =
             Ezagent.WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:dispatch, target_uri})
  end

  test "assert_local_owner/2 emits violation but continues in observe mode" do
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")

    Application.put_env(:ezagent_core, WorkspacePlacement,
      resolver: RemoteResolver,
      mode: :observe
    )

    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    target_uri = Ezagent.URI.new!("session://team-alpha/default/main")
    handler_id = {__MODULE__, self(), :owner_gate_violation}

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :workspace_owner_gate, :violation],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:owner_gate_violation, event, measurements, metadata})
        end,
        self()
      )

    try do
      assert :ok =
               Ezagent.WorkspaceOwnerGate.assert_local_owner(
                 workspace_uri,
                 {:dispatch, target_uri}
               )
    after
      :telemetry.detach(handler_id)
    end

    assert_receive {:owner_gate_violation, [:ezagent, :workspace_owner_gate, :violation], %{},
                    %{
                      workspace_uri: ^workspace_uri,
                      expected_owner: "remote-node",
                      current_runtime: "test-node-a"
                    }}
  end

  test "assert_local_owner/2 fails closed when owner is unknown" do
    Application.put_env(:ezagent_core, WorkspacePlacement, resolver: UnknownResolver)
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:error, {:workspace_owner_unknown, ^workspace_uri, {:spawn, ^workspace_uri}}} =
             Ezagent.WorkspaceOwnerGate.assert_local_owner(workspace_uri, {:spawn, workspace_uri})
  end

  defp restore_env(module, nil), do: Application.delete_env(:ezagent_core, module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
