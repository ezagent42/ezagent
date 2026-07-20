defmodule EzagentCore.Invariants.WorkspaceLocalityGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, RuntimeIdentity, SpawnRegistry, WorkspacePlacement}

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement

    @impl true
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  setup do
    previous_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    previous_placement = Application.get_env(:ezagent_core, WorkspacePlacement)

    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "local-node")

    Application.put_env(:ezagent_core, WorkspacePlacement,
      resolver: RemoteResolver,
      mode: :enforce
    )

    on_exit(fn ->
      restore_env(RuntimeIdentity, previous_identity)
      restore_env(WorkspacePlacement, previous_placement)
    end)

    :ok
  end

  test "dispatch fails before local lookup or lazy spawn when workspace is owned remotely" do
    target = Ezagent.URI.new!("session://team-alpha/default/main?action=session.send")

    inv = %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: Ezagent.URI.new!("entity://team-alpha/user/alice"),
        caps: MapSet.new(),
        reply: :ignore
      }
    }

    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node",
             {:dispatch, ^target}}} = Invocation.dispatch(inv)
  end

  test "spawn fails before local materialization when workspace is owned remotely" do
    uri =
      Ezagent.URI.new!(
        "session://team-alpha/default/locality-spawn-#{System.unique_integer([:positive])}"
      )

    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    assert {:error,
            {:not_workspace_owner, ^workspace_uri, "remote-node", "local-node", {:spawn, ^uri}}} =
             SpawnRegistry.spawn(uri)

    assert :error = Ezagent.KindRegistry.lookup(uri)
  end

  defp restore_env(module, nil), do: Application.delete_env(:ezagent_core, module)
  defp restore_env(module, value), do: Application.put_env(:ezagent_core, module, value)
end
