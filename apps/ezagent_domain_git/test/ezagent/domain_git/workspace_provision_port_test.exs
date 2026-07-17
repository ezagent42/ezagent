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

  test "authorized constructor carries a validated policy outside caller attributes" do
    attrs = %{
      task_access_uri: URI.parse("resource://ws/git-task-access/a"),
      task_uri: URI.parse("resource://ws/kanban-task/t"),
      generation: 1,
      operation: :prepare,
      provision_id: "provision"
    }

    policy = valid_policy()
    assert {:ok, request} = WorkspaceProvisionPort.Request.new_authorized(attrs, policy)
    assert request.task_policy == policy

    assert {:error, :invalid_task_policy} =
             WorkspaceProvisionPort.Request.new_authorized(attrs, :forged)

    assert {:error, :unknown_fields} =
             WorkspaceProvisionPort.Request.new(Map.put(attrs, :task_policy, :forged))
  end

  defp valid_policy do
    workspace = Ezagent.URI.workspace("ws")

    {:ok, repository} =
      Ezagent.DomainGit.RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("ws", "git-repository", "repo"),
        provider_adapter: :fixture,
        provider_host: "git.example.test",
        external_id: "repo",
        owner_path: "acme/repo",
        base_ref: "main",
        visibility: :public
      })

    {:ok, policy} =
      Ezagent.Entity.GitTaskAccess.new(%{
        id: "a",
        task_id: "t",
        generation: 1,
        workspace_uri: workspace,
        credential_owner_uri: Ezagent.URI.user("ws", "owner"),
        grantee_uri: Ezagent.URI.agent("ws", "worker"),
        repository: repository,
        provider_adapter: :fixture,
        allowed_head_ref: "task/head",
        allowed_actions: [:provision_workspace],
        idempotency_inputs: %{task_id: "t", generation: 1}
      })

    policy
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
