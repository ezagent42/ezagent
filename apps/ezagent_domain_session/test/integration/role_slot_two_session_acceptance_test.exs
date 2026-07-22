defmodule EzagentDomainInstanceMessage.Integration.RoleSlotTwoSessionAcceptanceTest do
  @moduledoc """
  P2 acceptance (socialware role-slot, spec §10): ROLE IS ON THE EDGE, NOT THE
  AGENT.

  One materialized, role-agnostic agent is joined to TWO sessions and holds a
  DISTINCT `role_name` on each (entity × session) membership edge:

    * `{:role, "advisor"}` @ session A  → the agent
    * `{:role, "reviewer"}` @ session B → the SAME agent

  and its identity URI carries NO role or session segment (`entity://<ws>/agent/
  <uuid>`, Gate B / spec §4.3). This is impossible under the pre-P2 model where
  role was baked globally onto the agent (URI segment + `AgentRoleAttributes`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.KindRegistry
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  @workspace_uri URI.new!("workspace://system")

  defp uniq, do: System.unique_integer([:positive])

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end

  defp live_session(tag) do
    session_uri = Ezagent.URI.session("system", "generic", "p2-#{tag}-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  # A role-AGNOSTIC materialized agent: a fresh uuid URI (no role/session
  # segment), live as a real Entity.Agent Kind so it can be a session member.
  defp materialize_role_agnostic_agent do
    agent_uri = Ezagent.URI.agent("system", Ecto.UUID.generate())

    {:ok, _pid} =
      Ezagent.Kind.spawn(Agent, %{uri: agent_uri, behaviors: Agent.base_behaviors()})

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, @workspace_uri)
    on_exit(fn -> terminate(agent_uri) end)
    agent_uri
  end

  defp join_member(session_uri, member_uri, role_name) do
    caller = User.admin_uri()
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{member: member_uri, role_name: role_name},
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: MapSet.new([signed_action_cap!(target, caller)]),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> await_member(session_uri, member_uri)
      {:ok, _} -> await_member(session_uri, member_uri)
      other -> other
    end
  end

  defp await_member(session_uri, member_uri, attempts \\ 100)
  defp await_member(_session_uri, _member_uri, 0), do: flunk("member projection did not converge")

  defp await_member(session_uri, member_uri, attempts) do
    if Map.has_key?(members_of(session_uri), member_uri) do
      :ok
    else
      Process.sleep(10)
      await_member(session_uri, member_uri, attempts - 1)
    end
  end

  defp members_of(%URI{} = session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: chat}} = :sys.get_state(pid)
    persistent = Map.get(chat, :state, chat)
    Map.get(persistent, :members, %{})
  end

  test "one agent, two sessions, distinct edge roles both resolving to the same agent" do
    session_a = live_session("advisor")
    session_b = live_session("reviewer")
    agent_uri = materialize_role_agnostic_agent()

    # (0) role-agnostic identity — no role or session segment baked into the URI
    assert URI.to_string(agent_uri) =~ ~r"^entity://system/agent/[0-9a-f-]{36}$"

    # (1) join the SAME agent to two sessions with DIFFERENT role_names
    assert :ok = join_member(session_a, agent_uri, "advisor")
    assert :ok = join_member(session_b, agent_uri, "reviewer")

    members_a = members_of(session_a)
    members_b = members_of(session_b)

    # (2) {:role, name} resolves against EACH session's edges to the same agent
    assert SessionBehavior.role_name_to_uri(members_a, "advisor") == agent_uri
    assert SessionBehavior.role_name_to_uri(members_b, "reviewer") == agent_uri

    # (3) the two edges carry DISTINCT role_names for the one agent
    assert members_a[agent_uri].role_name == "advisor"
    assert members_b[agent_uri].role_name == "reviewer"
    refute members_a[agent_uri].role_name == members_b[agent_uri].role_name

    # (4) cross-session role names do NOT leak: advisor is unknown in B, etc.
    assert SessionBehavior.role_name_to_uri(members_a, "reviewer") == nil
    assert SessionBehavior.role_name_to_uri(members_b, "advisor") == nil
  end
end
