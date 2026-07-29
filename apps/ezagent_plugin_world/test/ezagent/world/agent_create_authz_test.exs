defmodule Ezagent.World.AgentCreateAuthzTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.AgentActions`'s `agents.create` handler
  (`dispatch_agent_create/2`) had no authz behavior test: only `agents.delete`
  was pinned (`agent_delete_authz_leak_test.exs`). Mirrors
  `user_actions_test.exs`'s `users.create` authz coverage on the agent side —
  `Ezagent.Workspace.create_agent/3` is the SAME CapBAC-gated facade shape as
  `Ezagent.Workspace.create_user/3`.

    * a caller with ZERO caps in the target workspace is denied — no agent
      row is created (fail-closed, no partial state).
    * an operator holding the workspace's signed action-wildcard context
      (the same `signed_workspace_ctx!` shape `agent_delete_authz_leak_test`
      uses to set up a legitimate agent) succeeds.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.World.AgentActions

  defp uniq, do: System.unique_integer([:positive])

  defp socket_for(caller, workspace_uri) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
    |> assign(:last_dispatch_status, "idle")
  end

  test "a caller with zero caps cannot create an agent (no partial state)" do
    ws = "wagentcreate-#{uniq()}"
    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    workspace_uri = URI.new!("workspace://#{ws}")
    caller = URI.new!("entity://#{ws}/user/plain-#{uniq()}")
    agent_name = "shouldnotexist-#{uniq()}"

    {:noreply, out} =
      AgentActions.handle_dispatch(socket_for(caller, workspace_uri), "agents.create", %{
        "agent" => %{"flavor" => "curl", "name" => agent_name, "cwd" => ""}
      })

    assert out.assigns.last_dispatch_status =~ "error:"

    created = URI.new!("entity://#{ws}/agent/#{agent_name}")
    assert :error = Ezagent.KindRegistry.lookup(created)
  end

  test "an operator holding the workspace's signed context CAN create an agent" do
    # A FRESH, test-created operator (never the canonical admin) — the signed
    # workspace context is granted DURABLY to this disposable identity, never
    # to `Ezagent.Entity.User.admin_uri/0`'s shared live Identity slice.
    ws = "wagentcreate-ok-#{uniq()}"
    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    workspace_uri = URI.new!("workspace://#{ws}")
    operator = URI.new!("entity://#{ws}/user/operator-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(operator, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(operator)

    operator_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, operator)

    Enum.each(operator_ctx.caps, fn cap ->
      :ok = Ezagent.EntityCaps.grant(operator, cap)
    end)

    agent_name = "created-#{uniq()}"
    socket = socket_for(operator, workspace_uri)

    {:noreply, out} =
      AgentActions.handle_dispatch(socket, "agents.create", %{
        "agent" => %{"flavor" => "curl", "name" => agent_name, "cwd" => ""}
      })

    assert out.assigns.last_dispatch_status == "ok"

    created = URI.new!("entity://#{ws}/agent/#{agent_name}")
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(created)
  end
end
