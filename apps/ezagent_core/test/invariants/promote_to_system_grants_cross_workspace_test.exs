defmodule Ezagent.Invariants.PromoteToSystemGrantsCrossWorkspaceTest do
  @moduledoc """
  Invariant gate — SPEC v2 PR-D (Allen 2026-05-24).

  Promoting a non-admin user to `workspace://system` membership MUST
  grant them cross-workspace authority via the existing
  `Ezagent.Capability.cross_workspace?/2` membership path
  (capability.ex:221-238). No NEW cap rows are created — membership
  IS the cap. This test locks that contract.

  Revoking the membership MUST also revoke the cross-workspace
  authority.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability

  defp uniq, do: System.unique_integer([:positive])

  setup do
    # Ensure system workspace EXISTS at the Store (Ecto) level. The
    # Workspace Kind process may already be alive from boot; we only
    # care about the DB row for membership writes.
    case Ezagent.Workspace.Store.get_by_name("system") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("system", %{visible: false})
      _ -> :ok
    end

    :ok
  end

  # Build a workspace-scoped cap (not `:any`) so the cross_workspace?
  # check exercises the membership path, NOT the trivial `:any` cap
  # path.
  defp ws_scoped_cap(workspace_uri) do
    %Capability{
      kind: :any,
      behavior: :any,
      instance: :any,
      workspace_uri: workspace_uri,
      granted_by: URI.parse("system://bootstrap/default"),
      granted_at: DateTime.utc_now()
    }
  end

  test "promote_to_system → user gains cross-workspace authority via membership" do
    user_uri = URI.parse("entity://user/acme/promoted-#{uniq()}")
    user_home_ws = URI.parse("workspace://acme")
    cap = ws_scoped_cap(user_home_ws)

    # Before promotion: workspace-scoped cap is NOT cross-workspace
    # (caller isn't a system member yet)
    refute Capability.cross_workspace?(cap, user_uri),
           "non-system-member should NOT bypass workspace scope on a scoped cap"

    # Promote
    {:ok, _} = add_to_system_directly(user_uri)

    # After promotion: workspace-scoped cap IS treated as cross-workspace
    # via the membership-based bypass (PR-D fix in capability.ex)
    assert Capability.cross_workspace?(cap, user_uri),
           "system member MUST get cross-workspace authority " <>
             "(via Capability.cross_workspace?/2 membership path — PR-D fix)"
  end

  test "revoke_system → cross-workspace authority gone" do
    user_uri = URI.parse("entity://user/acme/revoked-#{uniq()}")
    cap = ws_scoped_cap(URI.parse("workspace://acme"))

    {:ok, _} = add_to_system_directly(user_uri)
    assert Capability.cross_workspace?(cap, user_uri)

    {:ok, _} = remove_from_system_directly(user_uri)

    refute Capability.cross_workspace?(cap, user_uri),
           "revoked user MUST lose cross-workspace authority"
  end

  test "non-system membership does NOT grant cross-workspace authority" do
    # Sanity: only `system` membership confers cross-workspace
    # authority. Membership in some other workspace (e.g. acme) is
    # tenant-scoped.
    user_uri = URI.parse("entity://user/acme/regular-#{uniq()}")
    cap = ws_scoped_cap(URI.parse("workspace://acme"))

    ws_name = "acme-#{uniq()}"
    {:ok, _} = Ezagent.Workspace.Store.create(ws_name, %{})
    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [user_uri])

    refute Capability.cross_workspace?(cap, user_uri),
           "membership in `acme` (non-system) workspace must not grant " <>
             "cross-workspace authority"
  end

  # --- direct Store helpers (bypass Workspace.add_member's Kind dispatch) ---

  defp add_to_system_directly(user_uri) do
    %{members: existing} = Ezagent.Workspace.Store.get_by_name("system")
    Ezagent.Workspace.Store.update_members("system", Enum.uniq([user_uri | existing]))
  end

  defp remove_from_system_directly(user_uri) do
    %{members: existing} = Ezagent.Workspace.Store.get_by_name("system")
    target = URI.to_string(user_uri)
    remaining = Enum.reject(existing, fn m -> URI.to_string(m) == target end)
    Ezagent.Workspace.Store.update_members("system", remaining)
  end
end
