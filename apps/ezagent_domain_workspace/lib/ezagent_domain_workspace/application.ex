defmodule EzagentDomainWorkspace.Application do
  @moduledoc """
  Workspace domain OTP application — Phase 6 PR 2.

  Owns:
  - `Ezagent.ActionSet.Workspace` registration on `Ezagent.Entity.Workspace`
  - `Ezagent.Workspace.Supervisor` DynamicSupervisor for `workspace://*` Kinds
  - `Ezagent.Workspace.Loader.load_all/0` invocation (deferred to last
    boot site — see notes)

  ## load_all timing

  Loader needs every plugin's spawn fn already registered (e.g.
  `agent`, `session`, `user`, `pty` schemes). Those registrations
  happen at each plugin's Application.start. The umbrella's child app
  start order is alphabetical, so ezagent_domain_workspace starts before
  most plugins.

  Solution: domain_workspace does NOT call load_all here. Instead it
  exposes `EzagentDomainWorkspace.boot_complete/0` which the LAST app to
  boot invokes after all spawn fns are registered. PR 3+ will move this call
  site to an explicit "registry-ready" gate.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.ActionSet.Workspace, as: WB
  alias Ezagent.Entity.Workspace, as: WK

  @impl true
  def start(_type, _args) do
    children =
      [
        Ezagent.Workspace.TaskWorkspace.LaunchAuthority,
        {Registry, keys: :unique, name: Ezagent.Workspace.TaskWorkspace.CacheLockRegistry},
        {DynamicSupervisor, name: Ezagent.Workspace.Supervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Ezagent.Workspace.CapGrantSupervisor}
      ] ++
        recovery_children() ++
        Application.get_env(:ezagent_domain_workspace, :later_boot_children, [])

    result = Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)

    if test_env?() and Code.ensure_loaded?(EzagentCore.DataCase) and
         function_exported?(EzagentCore.DataCase, :register_async_drain_supervisor, 1) do
      EzagentCore.DataCase.register_async_drain_supervisor(
        Ezagent.Workspace.CapGrantSupervisor
      )
    end

    :ok = register_task_workspace_infrastructure()
    :ok = register_workspace_behavior()

    result
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  defp recovery_children do
    if test_env?(),
      do: [],
      else: [{Ezagent.Workspace.TaskWorkspace.ReconcilerBoot, []}]
  end

  defp register_task_workspace_infrastructure do
    :ok =
      Ezagent.Agent.LaunchAuthority.register(Ezagent.Workspace.TaskWorkspace.LaunchAuthority)

    :ok =
      Ezagent.Kind.Template.PreStart.register(Ezagent.Workspace.TaskWorkspace.PreStart)

    :ok =
      Ezagent.Resource.FsResolver.Registry.register_all([
        Ezagent.Workspace.TaskWorkspace.Paths.resource_type()
      ])

    :ok =
      Ezagent.DomainGit.WorkspaceProvisionRegistry.register(
        Ezagent.Workspace.TaskWorkspace.Provisioner
      )
    :ok
  end

  defp register_workspace_behavior do
    Enum.each(WB.actions(), fn action ->
      :ok = CapabilityRegistry.register(WK, action, WB)
    end)

    # PR #146 (SPEC v2 §5.7) — workspace-scoped routing rule mutations
    # dispatch to `workspace://<name>?action=routing.<action>` against
    # the Workspace Kind. CapBAC scopes naturally to the workspace
    # instance.
    alias Ezagent.ActionSet.Routing, as: RB

    Enum.each(RB.actions(), fn action ->
      :ok = CapabilityRegistry.register(WK, action, RB)
    end)

    :ok
  end

  @doc """
  Called by the last-booting app once all spawn fns are registered.
  Idempotent — multiple callers OK (Loader handles "already spawned").
  """
  def boot_complete do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok
  end
end
