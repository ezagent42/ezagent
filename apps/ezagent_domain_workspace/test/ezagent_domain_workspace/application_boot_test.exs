defmodule EzagentDomainWorkspace.ApplicationBootTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.WorkspaceProvisionRegistry
  alias Ezagent.Resource.FsResolver
  alias Ezagent.Workspace.TaskWorkspace.{Paths, Provisioner}
  alias EzagentDomainWorkspace.TestSupport.FailingBootChild

  test "production boot registers the task path authority and provision port" do
    assert {:ok, Provisioner} = WorkspaceProvisionRegistry.implementation()

    workspace = Ezagent.URI.workspace("workspace-boot-registration")
    repository = Ezagent.URI.resource("workspace-boot-registration", "git-repository", "widgets")

    assert {:ok, paths} =
             Paths.derive(%{
               workspace_uri: workspace,
               repository_uri: repository,
               base_ref: "main",
               provision_id: "boot-provision",
               generation: 1,
               allowed_head_ref: "task/boot"
             })

    resource =
      Ezagent.URI.resource(
        "workspace-boot-registration",
        "git-task-workspaces",
        paths.cache_identity
      )

    cache_path = paths.cache_path

    assert {:ok, ^cache_path} =
             FsResolver.resolve(resource, %{workspace: "workspace-boot-registration"})
  end

  test "a later child boot failure rolls back the Workspace supervisor and restart succeeds" do
    assert :ok = Application.stop(:ezagent_domain_workspace)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :later_boot_children)
      Application.ensure_all_started(:ezagent_domain_workspace)
    end)

    Application.put_env(:ezagent_domain_workspace, :later_boot_children, [FailingBootChild])

    assert {:error, _reason} = Application.ensure_all_started(:ezagent_domain_workspace)
    refute Process.whereis(EzagentDomainWorkspace.Application)
    refute Process.whereis(Ezagent.Workspace.TaskWorkspace.CacheLockRegistry)

    Application.delete_env(:ezagent_domain_workspace, :later_boot_children)
    assert {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_workspace)
    assert Process.whereis(EzagentDomainWorkspace.Application)
    assert {:ok, Provisioner} = WorkspaceProvisionRegistry.implementation()
  end
end
