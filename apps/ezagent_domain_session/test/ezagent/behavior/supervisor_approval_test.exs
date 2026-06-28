defmodule EzagentDomainInstanceMessage.Behavior.SupervisorApprovalTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.SupervisorApproval
  alias Ezagent.Workspace.ResponsibilityAssignment

  defp ctx(session_uri, caller, slice) do
    %{
      self_uri: session_uri,
      caller: caller,
      read: fn key, default -> Map.get(slice, key, default) end
    }
  end

  defp apply_effects({:ok, result, effects}, slice) do
    {:ok, %{state: new_slice}} = Ezagent.Behavior.apply_effects(effects, slice)
    {:ok, result, new_slice}
  end

  test "majority conflict escalates to arbiter and stale holders are rejected" do
    ws = "p9-approval-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :default, "support")
    a = Ezagent.URI.user(ws, "supervisor-a")
    b = Ezagent.URI.user(ws, "supervisor-b")
    stale = Ezagent.URI.user(ws, "stale-supervisor")

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    {:ok, _} = ResponsibilityAssignment.assign(workspace_uri, "supervisor", a, nil, %{})
    {:ok, _} = ResponsibilityAssignment.assign(workspace_uri, "supervisor", b, nil, %{})

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
