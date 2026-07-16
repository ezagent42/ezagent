defmodule Ezagent.World.LayoutBootstrap do
  @moduledoc """
  Installs the default `world.layout.manage` grant for the system workspace.
  """

  @doc "Ensure the system workspace admin holds the explicit world layout manage cap."
  @spec ensure_system_admin_manage_cap() :: :ok | {:error, term()}
  def ensure_system_admin_manage_cap do
    admin_uri = Ezagent.Entity.User.admin_uri()
    workspace_uri = Ezagent.URI.workspace(:system)
    cap = manage_cap(admin_uri, workspace_uri)

    with :ok <- Ezagent.Entity.spawn_principal(admin_uri) do
      Ezagent.Identity.Grant.grant_cap(admin_uri, cap, {:admin, admin_uri})
    end
  end

  @doc "Build the explicit manage cap for a workspace-scoped world layout."
  @spec manage_cap(URI.t(), URI.t()) :: Ezagent.Capability.t()
  def manage_cap(%URI{} = granted_by, %URI{} = workspace_uri) do
    %Ezagent.Capability{
      kind: :workspace,
      behavior: Ezagent.World.Behavior.Layout,
      action: :manage,
      instance: Ezagent.URI.instance(workspace_uri),
      workspace_uri: Ezagent.Capability.workspace_of(workspace_uri),
      granted_by: granted_by,
      granted_at: DateTime.utc_now()
    }
  end
end
