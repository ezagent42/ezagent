defmodule EzagentDomainInstanceMessage.Behavior.SupervisorApprovalTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.SupervisorApproval
  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.Workspace.ResponsibilityAssignment

  defp ctx(session_uri, caller, slice) do
    %{
      self_uri: session_uri,
      caller: caller,
      authenticated_principal: caller,
      read: fn key, default -> Map.get(slice, key, default) end
    }
  end

  defp spawn_session(session_uri) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        owner_uri: User.admin_uri(),
        behaviors: Ezagent.Entity.Session.behaviors()
      })
  end

  defp spawn_user(uri, caps \\ []) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
  end

  defp member_cap(session_uri, workspace_uri, holder) do
    requested =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        workspace_uri
      )

    Ezagent.Test.CapHelper.signed_cap!(session_uri, holder, requested)
  end

  defp apply_effects({:ok, result, effects}, slice) do
    {:ok, %{state: new_slice}} = Ezagent.ActionSet.apply_effects(effects, slice)
    {:ok, result, new_slice}
  end

  test "majority conflict escalates to arbiter and stale holders are rejected" do
    ws = "p9-approval-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :default, "support")
    a = Ezagent.URI.user(ws, "supervisor-a")
    b = Ezagent.URI.user(ws, "supervisor-b")
    assigned_nonmember = Ezagent.URI.user(ws, "assigned-nonmember")
    stale = Ezagent.URI.user(ws, "stale-supervisor")

    spawn_session(session_uri)
    spawn_user(a, [member_cap(session_uri, workspace_uri, a)])
    spawn_user(b, [member_cap(session_uri, workspace_uri, b)])
    spawn_user(assigned_nonmember)

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    {:ok, _} = ResponsibilityAssignment.assign(workspace_uri, "supervisor", a, nil, %{})
    {:ok, _} = ResponsibilityAssignment.assign(workspace_uri, "supervisor", b, nil, %{})

    {:ok, _} =
      ResponsibilityAssignment.assign(
        workspace_uri,
        "supervisor",
        assigned_nonmember,
        nil,
        %{}
      )

    {:ok, slice} = SupervisorApproval.create(%{})

    {:ok, %{status: :pending}, slice} =
      SupervisorApproval.handle_submit_verdict(
        %{
          turn_id: "turn-1",
          responsibility: "supervisor",
          verdict: :approve,
          quorum_policy: %{type: :majority},
          arbiter: "arbiter"
        },
        ctx(session_uri, a, slice)
      )
      |> apply_effects(slice)

    {:ok, %{status: :escalated, receiver: {:role, "arbiter"}}, _slice} =
      SupervisorApproval.handle_submit_verdict(
        %{
          turn_id: "turn-1",
          responsibility: "supervisor",
          verdict: :reject,
          quorum_policy: %{type: :majority},
          arbiter: "arbiter"
        },
        ctx(session_uri, b, slice)
      )
      |> apply_effects(slice)

    assert {:error, :not_session_member} =
             SupervisorApproval.handle_submit_verdict(
               %{
                 turn_id: "turn-2",
                 responsibility: "supervisor",
                 verdict: :approve,
                 quorum_policy: %{type: :any_one},
                 arbiter: nil
               },
               ctx(session_uri, assigned_nonmember, slice)
             )

    assert {:error, :stale_holder} =
             SupervisorApproval.handle_submit_verdict(
               %{
                 turn_id: "turn-1",
                 responsibility: "supervisor",
                 verdict: :approve,
                 quorum_policy: %{type: :any_one},
                 arbiter: nil
               },
               ctx(session_uri, stale, slice)
             )
  end
end
