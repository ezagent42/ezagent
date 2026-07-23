defmodule Ezagent.Workspace.OffboardingTransferTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.Offboarding.RevocationFence
  alias Ezagent.Provenance.DerivationEdges
  alias Ezagent.Workspace.Store

  test "delete_user re-owns an owned workspace to admin instead of revoking it" do
    suffix = System.unique_integer([:positive])
    deleted_user = Ezagent.URI.user("offboarding-workspace", "owner-#{suffix}")
    workspace_name = "offboarding-owned-#{suffix}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    admin = Ezagent.Entity.User.admin_uri()

    assert {:ok, _user} = Ezagent.Users.create(deleted_user, nil, [])
    assert {:ok, _workspace} = Store.create(workspace_name, %{created_by: deleted_user})

    assert :ok =
             DerivationEdges.record_derivation_edge(
               workspace_uri,
               deleted_user,
               :workspace_ownership,
               DerivationEdges.new_attempt_id()
             )

    assert :ok = Ezagent.Users.delete(deleted_user)

    assert %{created_by: ^admin} = Store.get_by_name(workspace_name)
    refute RevocationFence.fenced?(workspace_uri)
    assert workspace_uri in DerivationEdges.descendants(admin)
  end
end
