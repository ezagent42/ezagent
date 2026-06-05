defmodule EzagentPluginAutoservice.Roles do
  @moduledoc """
  Role → capability bundles for the autoservice vertical.

  ezagent has no "role" primitive — authority is CapBAC (P15). The
  three customer-service roles are therefore just named cap bundles
  layered on top of the workspace-scoped `User.default_caps/1` that
  `Ezagent.Users.create/3` already prepends to every new user:

  - **customer** — no extra caps. The default workspace-scoped `:session`
    participation cap lets them chat in their own session. (v1 caveat:
    the default cap is workspace-scoped, so isolation between customers
    is enforced at the UI layer, not structurally. A strict
    `{:within_session, _}` customer cap is a documented follow-up.)
  - **operator** — no extra caps in v1. Seeing the workspace's session
    list + joining a session is gated by the operator console LiveView,
    not by a distinct cap (workspace-scoped `:session` already permits
    joining any session in the tenant). A dedicated operator cap is a
    follow-up alongside the customer session-scoping work.
  - **admin** — workspace-scoped management caps: the generic `Workspace`
    behavior (add_member / create_agent / set_routing_rules /
    create_session) + the carved-out `WorkspaceUserAdmin` (create_user).
    NOT a `system://` wildcard — admin authority is bounded to its own
    workspace.

  Returned caps are the EXTRA caps to grant beyond `default_caps/1`.
  """

  alias Ezagent.Capability

  # SPEC 2026-05-27-uri-canonicalization §3.5 — compile-time constant
  # URI (ETS SchemeRegistry not available at compile time). The granting
  # authority recorded on seeded admin caps; mirrors `User.default_caps/1`
  # which records the same bootstrap principal.
  @granted_by URI.new!("system://bootstrap/default")

  @type role :: :customer | :operator | :admin

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
    ]
  end

  def bundle(:admin, %URI{scheme: "workspace"} = workspace_uri) do
    now = DateTime.utc_now()

    [
      # Workspace management within this tenant: add_member, create_agent,
      # set_routing_rules, create_session — all actions of the generic
      # Workspace behavior, scoped to this workspace instance.
      grantable(:workspace, Ezagent.Behavior.Workspace, :any, workspace_uri, now),
      # Privileged user provisioning (carved out per PR #356) — create new
      # users in this workspace.
      grantable(:workspace, Ezagent.Behavior.WorkspaceUserAdmin, :create_user, workspace_uri, now)
    ]
  end

  # A grantable (serializable) cap — `cap/3,5` are DECLARATION
  # constructors (`granted_by: :plugin_declared`, `granted_at:
  # :compile_time`) that `Capability.to_map/1` cannot serialize for the
  # users table. A cap stored on a user needs a real granting principal
  # + timestamp, mirroring `User.default_caps/1`.
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

  # Session-scoped cap with `instance: :any` (matches any session in the
  # workspace). Matches `User.default_caps/1` pattern — the workspace_uri
  # scoping is already on the `workspace_uri` field.
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
end
