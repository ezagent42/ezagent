defmodule EzagentPluginAutoservice.Roles do
  @moduledoc """
  Role -> capability bundles for the autoservice vertical.

  ezagent has no "role" primitive -- authority is CapBAC (P15). The
  four customer-service roles are therefore just named cap bundles
  layered on top of the workspace-scoped `User.default_caps/1` that
  `Ezagent.Users.create/3` already prepends to every new user:

  - **customer** -- session send/receive within the workspace.
    (v1 caveat: isolation between customers is enforced at the UI layer,
    not structurally.)
  - **operator** -- session join/send/receive within the workspace.
  - **admin** -- workspace-scoped management caps: Workspace behavior
    (add_member / create_agent / set_routing_rules / create_session)
    + WorkspaceUserAdmin (create_user).
  - **master_admin** -- cross-tenant super-admin: workspace:* across ALL
    workspaces, for platform-level operations (tenant provisioning,
    bootstrap, global config). NOT a `system://` wildcard -- bounded to
    workspace-scoped management across all tenants.
  """

  alias Ezagent.Capability

  @granted_by URI.new!("system://bootstrap/default")

  @type role :: :customer | :operator | :admin | :master_admin

  @doc "Extra caps (beyond `User.default_caps/1`) to grant a role in a workspace."
  @spec bundle(role(), URI.t()) :: [Capability.t()]
  def bundle(:customer, %URI{scheme: "workspace"} = workspace_uri) do
    now = DateTime.utc_now()
    [
      grantable_session_any(:send, workspace_uri, now),
      grantable_session_any(:receive, workspace_uri, now)
    ]
  end

  def bundle(:operator, %URI{scheme: "workspace"} = workspace_uri) do
    now = DateTime.utc_now()

    [
      grantable_session_any(:join, workspace_uri, now),
      grantable_session_any(:send, workspace_uri, now),
      grantable_session_any(:receive, workspace_uri, now)
    ] ++ operator_turn_caps(workspace_uri, now)
  end

  def bundle(:admin, %URI{scheme: "workspace"} = workspace_uri) do
    now = DateTime.utc_now()

    [
      grantable(:workspace, Ezagent.Behavior.Workspace, :any, workspace_uri, now),
      grantable(:workspace, Ezagent.Behavior.WorkspaceUserAdmin, :create_user, workspace_uri, now)
    ]
  end

  def bundle(:master_admin, _workspace_uri) do
    now = DateTime.utc_now()
    # Cross-tenant super-admin: workspace management across ALL workspaces.
    # Uses `instance: :any` to match any workspace URI.
    [
      %Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @granted_by,
        granted_at: now
      },
      %Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.WorkspaceUserAdmin,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @granted_by,
        granted_at: now
      }
    ]
  end

  defp grantable(kind, behavior, action, %URI{} = workspace_uri, %DateTime{} = now) do
    %Capability{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: @granted_by,
      granted_at: now
    }
  end

  defp grantable_session_any(action, %URI{} = workspace_uri, %DateTime{} = now) do
    %Capability{
      kind: :session,
      behavior: :any,
      action: action,
      instance: :any,
      workspace_uri: workspace_uri,
      granted_by: @granted_by,
      granted_at: now
    }
  end

  # Operator gets Turn caps (open/compose/claim/settle) so TurnAdapter
  # can drive the Turn lifecycle with the operator's own authority.
  # `kind: :session` + `behavior: Ezagent.Behavior.Turn` matches the
  # SocialwareSession Kind (type_name = :session) and Turn Behavior.
  # Adapted from PR #740.
  defp operator_turn_caps(%URI{} = workspace_uri, %DateTime{} = now) do
    for action <- [:open, :compose, :claim, :settle] do
      %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.Turn,
        action: action,
        instance: :any,
        workspace_uri: workspace_uri,
        granted_by: @granted_by,
        granted_at: now
      }
    end
  end
end
