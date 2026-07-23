defmodule Ezagent.Session.SupervisorIsMemberTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.SupervisorApproval
  alias Ezagent.Entity.User
  alias Ezagent.Session.Membership

  test "an assigned supervisor is a real member and a non-member cannot moderate" do
    workspace_name = "s2-supervisor-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})

    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :default, "reviewed")
    supervisor = Ezagent.URI.user(workspace_name, "reviewer")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        owner_uri: User.admin_uri(),
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{uri: supervisor, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    {:ok, slice} = SupervisorApproval.create(%{})

    refute Membership.authorize(%{}, supervisor, session_uri, supervisor) == :ok

    assert {:ok, _assignment} =
             Ezagent.Workspace.assign_role(
               workspace_uri,
               "supervisor",
               supervisor,
               %{quorum_policy: "any_one"},
               Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())
             )

    assert :ok = Membership.authorize(%{}, supervisor, session_uri, supervisor)

    assert {:ok, %{status: :approved}, _effects} =
             SupervisorApproval.handle_submit_verdict(
               %{
                 turn_id: "turn-1",
                 responsibility: "supervisor",
                 verdict: :approve,
                 quorum_policy: %{type: :any_one},
                 arbiter: nil
               },
               %{
                 self_uri: session_uri,
                 caller: supervisor,
                 authenticated_principal: supervisor,
                 read: fn key, default -> Map.get(slice, key, default) end
               }
             )
  end
end
