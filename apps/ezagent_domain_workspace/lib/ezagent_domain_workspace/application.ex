defmodule EzagentDomainWorkspace.Application do
  @moduledoc """
  Workspace domain OTP application — Phase 6 PR 2.

  Owns:
  - `Ezagent.Behavior.Workspace` registration on `Ezagent.Entity.Workspace`
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
  alias Ezagent.Behavior.Workspace, as: WB
  alias Ezagent.Entity.Workspace, as: WK

  @impl true
  def start(_type, _args) do
    :ok = register_workspace_behavior()
    :ok = register_resource_spawn_fn()

    children = [
      {DynamicSupervisor, name: Ezagent.Workspace.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # df-tech (kanban-clean) — own the single `resource://<ws>/<type>/<name>`
  # SpawnRegistry dispatcher. This is the EXACT analogue of the session
  # domain's `entity` dispatcher (`EzagentDomainInstanceMessage` registers
  # one `entity` spawn fn that switches on `Ezagent.URI.type/1` to spawn
  # user/agent Kinds, consulting `AgentFlavorRegistry` for agent flavors).
  #
  # Here we switch on the resource URI's type segment and look up the
  # backing Kind module in `Ezagent.ResourceKindRegistry` — which each
  # plugin populates declaratively via `Ezagent.Plugin.resource_kinds/0`
  # (the kanban plugin declares `{"kanban", EzagentPluginKanban.Kanban}`).
  # The plugin never touches `SpawnRegistry` (invariant 8); the domain
  # owns the scheme dispatcher and never compile-depends on the plugin's
  # Kind module (resolved at runtime through the registry).
  #
  # A `resource://` URI with no registered type → `{:error,
  # {:no_resource_kind, type}}`. A fresh URI with no snapshot still only
  # surfaces on explicit `SpawnRegistry.spawn`, never auto-spawned by a
  # bare dispatch (same as `entity`).
  defp register_resource_spawn_fn do
    :ok =
      Ezagent.SpawnRegistry.register("resource", fn %URI{} = uri ->
        case Ezagent.URI.type(uri) do
          {:ok, type} ->
            case Ezagent.ResourceKindRegistry.lookup(type) do
              {:ok, kind_module} -> Ezagent.Kind.spawn(kind_module, %{uri: uri})
              :error -> {:error, {:no_resource_kind, type}}
            end

          :error ->
            {:error, {:resource_uri_has_no_type, URI.to_string(uri)}}
        end
      end)

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
    alias Ezagent.Behavior.Routing, as: RB

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
