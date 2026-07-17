defmodule Ezagent.DomainGit.WorkspaceProvisionPortTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.WorkspaceProvisionPort
  alias Ezagent.DomainGit.WorkspaceProvisionRegistry

  defmodule FakeProvisioner do
    @behaviour WorkspaceProvisionPort

    @impl true
    def prepare(request), do: {:ok, %{provision_id: request.provision_id, status: :ready}}

    @impl true
    def cleanup(request), do: {:ok, %{provision_id: request.provision_id, status: :cleaned}}
  end

  setup do
    original = WorkspaceProvisionRegistry.implementation()
    restart_registry()

    on_exit(fn ->
      restart_registry()

      case original do
        {:ok, implementation} -> :ok = WorkspaceProvisionRegistry.register(implementation)
        {:error, :workspace_provisioner_not_registered} -> :ok
      end
    end)
  end

  test "registers exactly one conforming implementation idempotently" do
    assert :ok = WorkspaceProvisionRegistry.register(FakeProvisioner)
    assert :ok = WorkspaceProvisionRegistry.register(FakeProvisioner)
    assert {:ok, FakeProvisioner} = WorkspaceProvisionRegistry.implementation()

    assert {:error, :conflicting_workspace_provisioner} =
             WorkspaceProvisionRegistry.register(__MODULE__)
  end

  test "request rejects caller-selected repository and path coordinates" do
    assert {:error, :unknown_fields} =
             WorkspaceProvisionPort.Request.new(%{
               task_access_uri: URI.parse("resource://ws/git-task-access/a"),
               task_uri: URI.parse("resource://ws/kanban-task/t"),
               generation: 1,
               operation: :prepare,
               local_path: "/tmp/forged"
             })
  end

  defp restart_registry do
    :ok =
      Supervisor.terminate_child(
        EzagentDomainGit.Application,
        WorkspaceProvisionRegistry
      )

    {:ok, _pid} =
      Supervisor.restart_child(
        EzagentDomainGit.Application,
        WorkspaceProvisionRegistry
      )

    :ok
  end
end
