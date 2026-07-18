defmodule Ezagent.World.AgentDeleteAuthzLeakTest do
  @moduledoc """
  Security regression for the `agents.delete` preflight (HIGH, codex-flagged).

  BUG: `dispatch_agent_delete/2` called
  `EzagentDomainInstanceMessage.agent_live_sessions/1` with the CALLER-SUPPLIED
  agent URI BEFORE any authorization. `agent_live_sessions/1` resolves the
  workspace from the PASSED URI and lists sessions there, so a forged /
  cross-workspace agent URI leaked another tenant's live-session NAMES + COUNT
  through the `{:agent_bound_to_live_session, sessions}` error banner —
  cross-workspace session enumeration with zero caps.

  This test drives the REAL public handler `AgentActions.handle_dispatch/3`
  (NOT a replicated copy of the gate), so it fails on the pre-fix code and
  passes once the `Ezagent.Agent.Config.read_cascade/4` authz gate runs before
  the live-sessions preflight.

  Two cases:
  (leak) an unauthorized caller in workspace A forges a workspace-B agent URI
         that is bound to a live B session → the banner must NOT contain the B
         session name/count; status must be an authz error. FAILS on old code.
  (legit) an AUTHORIZED same-workspace caller (holding the agent's manage-cap)
          still gets the bound-session banner WITH the session name — proves the
          gate does not over-block legitimate same-workspace listing.
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.KindRegistry
  alias Ezagent.Workspace
  alias Ezagent.World.AgentActions

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered — test environment bootstrap is incomplete"

    # Two isolated tenants: A = the attacker's own workspace, B = the victim.
    ws_a = "authz-leak-a-#{System.unique_integer([:positive])}"
    ws_b = "authz-leak-b-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws_a, %{})
    {:ok, _} = Workspace.create(ws_b, %{})

    {:ok, ws_a: ws_a, ws_b: ws_b}
  end

  # Create a real agent in the given workspace and bind it into a live session
  # in that same workspace. Returns {agent_uri, session_name} so the test can
  # assert on the leaked/allowed session NAME.
  defp bound_agent_in(ws_name) do
    agent_name = "leak-probe-#{System.unique_integer([:positive])}"
    workspace_uri = URI.new!("workspace://#{ws_name}")
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, %{agent_uri: agent_uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
        admin_ctx
      )

    n = System.unique_integer([:positive])
    session_short = "victim-conv-#{n}"
    session_uri = Ezagent.URI.new!("session://#{ws_name}/default/#{session_short}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://#{ws_name}"))

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.SessionSupervisor,
            pid
          )

        :error ->
          :ok
      end
    end)

    join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    join_cap = Ezagent.Test.CapHelper.signed_action_cap!(join_target, User.admin_uri())

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: join_target,
        mode: :cast,
        args: %{member: agent_uri},
        ctx: %{caller: User.admin_uri(), caps: MapSet.new([join_cap]), reply: :ignore}
      })

    Process.sleep(50)

    # Confirm the agent is genuinely bound, so the leak channel is real.
    assert {:ok, live} = EzagentDomainInstanceMessage.agent_live_sessions(agent_uri)
    assert live != [], "setup failed: agent is not bound to a live session"

    {agent_uri, session_short}
  end

  # Build the minimal WorldLive socket the AgentActions handler reads.
  defp socket_for(workspace_name, caller_uri, caps) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_workspace_uri, URI.new!("workspace://#{workspace_name}"))
    |> assign(:current_entity_uri, caller_uri)
    |> assign(:current_caps, caps)
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
    |> assign(:last_dispatch_status, "idle")
  end

  test "forged cross-workspace agent URI does NOT leak the victim tenant's session name/count",
       %{ws_a: ws_a, ws_b: ws_b} do
    {victim_agent_uri, victim_session_name} = bound_agent_in(ws_b)

    # Attacker operates in workspace A, holds NO caps, forges the workspace-B
    # agent URI. current_workspace_uri (A) is server-derived from the signed
    # session — only the agent URI in the dispatch args is attacker-controlled.
    attacker = URI.new!("entity://#{ws_a}/user/attacker")
    socket = socket_for(ws_a, attacker, MapSet.new())

    {:noreply, out} =
      AgentActions.handle_dispatch(socket, "agents.delete", %{
        "agent_uri" => URI.to_string(victim_agent_uri)
      })

    action_error = out.assigns.world_state["action_error"] || ""
    status = out.assigns.last_dispatch_status

    refute action_error =~ victim_session_name,
           "LEAK: cross-workspace delete banner exposed victim session name #{inspect(victim_session_name)} " <>
             "— banner: #{inspect(action_error)}"

    # A count leak is just as bad — the pre-fix banner read "正在 N 个对话中".
    refute action_error =~ "个对话中",
           "LEAK: banner exposed the victim's live-session COUNT — banner: #{inspect(action_error)}"

    assert status in [
             "error:unauthorized",
             "error:cross_workspace_denied",
             "error:invalid_agent_uri"
           ],
           "forged cross-workspace delete must fail closed with an authz error, got: #{inspect(status)}"
  end

  test "same-workspace caller holding a Manage cap for a DIFFERENT agent is still denied (no leak)",
       %{ws_b: ws_b} do
    {victim_agent_uri, victim_session_name} = bound_agent_in(ws_b)
    workspace_uri = URI.new!("workspace://#{ws_b}")
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    # A second, unrelated agent in the SAME workspace. The caller holds only
    # THIS agent's concrete instance-scoped Manage cap — not the victim's.
    {:ok, %{agent_uri: other_agent_uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{
          flavor: "curl",
          name: "other-#{System.unique_integer([:positive])}",
          cwd: "",
          with_pty: false
        },
        admin_ctx
      )

    caller = URI.new!("entity://#{ws_b}/user/member")

    wrong_target = Ezagent.URI.with_action(other_agent_uri, :manage, :delete)
    wrong_cap = Ezagent.Test.CapHelper.signed_action_cap!(wrong_target, caller)

    socket = socket_for(ws_b, caller, MapSet.new([wrong_cap]))

    {:noreply, out} =
      AgentActions.handle_dispatch(socket, "agents.delete", %{
        "agent_uri" => URI.to_string(victim_agent_uri)
      })

    action_error = out.assigns.world_state["action_error"] || ""

    refute action_error =~ victim_session_name,
           "LEAK: a caller holding a DIFFERENT agent's manage-cap saw the victim session name; banner: #{inspect(action_error)}"

    refute action_error =~ "个对话中",
           "LEAK: banner exposed the victim's live-session COUNT; banner: #{inspect(action_error)}"

    assert out.assigns.last_dispatch_status == "error:unauthorized",
           "wrong-agent-cap delete must fail closed with :unauthorized, got: #{inspect(out.assigns.last_dispatch_status)}"
  end

  test "authorized same-workspace caller still sees the bound-session banner (no over-block)",
       %{ws_b: ws_b} do
    {agent_uri, session_name} = bound_agent_in(ws_b)

    # Legitimate operator: same workspace as the agent, holds the agent's
    # manage-cap (admin genesis authorizes it).
    delete_target = Ezagent.URI.with_action(agent_uri, :manage, :delete)
    delete_cap = Ezagent.Test.CapHelper.signed_action_cap!(delete_target, User.admin_uri())
    socket = socket_for(ws_b, User.admin_uri(), MapSet.new([delete_cap]))

    {:noreply, out} =
      AgentActions.handle_dispatch(socket, "agents.delete", %{
        "agent_uri" => URI.to_string(agent_uri)
      })

    action_error = out.assigns.world_state["action_error"] || ""

    assert action_error =~ session_name,
           "authorized same-workspace listing must still surface the bound session name; banner: #{inspect(action_error)}"

    assert out.assigns.last_dispatch_status =~ "agent_bound_to_live_session",
           "expected the bound-session status for a legitimate blocked delete, got: #{inspect(out.assigns.last_dispatch_status)}"
  end
end
