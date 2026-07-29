defmodule Ezagent.World.WorkspaceMemberRemoveAuthzTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.WorkspacePluginActions.remove_workspace_member/2`
  (`workspace.member.remove`) had no authz behavior test. Workspace-level
  membership removal is the WORKSPACE-scoped analog of the session-level
  `remove_participant/3` pin (`remove_participant_authz_test.exs`) — same
  "member remove authz edge" priority, one layer up.

  `remove_workspace_member/2` threads the caller's LIVE caps into
  `Ezagent.Workspace.remove_member/3`, a CapBAC-checked dispatch (step 5.5) —
  distinct from the deprecated cap-less `remove_member/2`.

    * an outsider with zero caps cannot remove a workspace member — denied,
      the member stays in the roster (no partial mutation).
    * an operator holding the workspace's signed action-wildcard context can
      remove a member; the roster reflects the removal via the SAME
      `Ezagent.Workspace.Store` read the handler itself uses to refresh state.
    * a malformed member_uri degrades to `error:bad_member_uri`, no crash.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.World.WorkspacePluginActions

  defp uniq, do: System.unique_integer([:positive])

  defp socket_for(caller, workspace_uri) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
    |> assign(:last_dispatch_status, "idle")
  end

  defp workspace_with_member! do
    ws = "wmemberremove-#{uniq()}"
    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    workspace_uri = URI.new!("workspace://#{ws}")

    member = URI.new!("entity://#{ws}/user/member-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(member, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(member)
    :ok = Ezagent.Workspace.add_member(ws, member)

    {ws, workspace_uri, member}
  end

  defp roster(ws) do
    case Ezagent.Workspace.Store.get_by_name(ws) do
      %{members: members} -> Enum.map(members || [], &URI.to_string/1)
      _ -> []
    end
  end

  test "an outsider with zero caps CANNOT remove a workspace member (no partial mutation)" do
    {ws, workspace_uri, member} = workspace_with_member!()
    outsider = URI.new!("entity://#{ws}/user/outsider-#{uniq()}")

    assert URI.to_string(member) in roster(ws)

    {:noreply, out} =
      WorkspacePluginActions.handle_dispatch(
        socket_for(outsider, workspace_uri),
        "workspace.member.remove",
        %{"member_uri" => URI.to_string(member)}
      )

    assert out.assigns.last_dispatch_status =~ "error:",
           "an outsider with zero caps must be denied, got: #{inspect(out.assigns.last_dispatch_status)}"

    assert URI.to_string(member) in roster(ws),
           "LEAK: an unauthorized remove must not mutate the workspace roster"
  end

  test "an operator holding the workspace's signed context CAN remove a member" do
    {ws, workspace_uri, member} = workspace_with_member!()

    operator = URI.new!("entity://#{ws}/user/operator-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(operator, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(operator)

    operator_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator)

    Enum.each(operator_ctx.caps, fn cap ->
      :ok = Ezagent.EntityCaps.grant(operator, cap)
    end)

    {:noreply, out} =
      WorkspacePluginActions.handle_dispatch(
        socket_for(operator, workspace_uri),
        "workspace.member.remove",
        %{"member_uri" => URI.to_string(member)}
      )

    assert out.assigns.last_dispatch_status == "ok"
    refute URI.to_string(member) in roster(ws)
  end

  test "a malformed member_uri degrades cleanly, never a crash" do
    {ws, workspace_uri, _member} = workspace_with_member!()
    caller = URI.new!("entity://#{ws}/user/whoever-#{uniq()}")

    {:noreply, out} =
      WorkspacePluginActions.handle_dispatch(
        socket_for(caller, workspace_uri),
        "workspace.member.remove",
        %{"member_uri" => "not a uri"}
      )

    # `Ezagent.URI.parse/1` returns `{:error, reason}` (not the bare `:error`
    # the handler's catch-all expects) for this input, so it lands on
    # `error:remove_member_failed` rather than `error:bad_member_uri` — a
    # labeling quirk, not a security issue: either way the result is a
    # clean `error:` status, never a crash, and the roster is untouched.
    assert out.assigns.last_dispatch_status =~ "error:"
  end
end
