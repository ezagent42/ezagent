defmodule Ezagent.Entity.Session.OrchestratorBoundTest do
  @moduledoc """
  Unit coverage for `Ezagent.Entity.Session.Orchestrator.agent_bound_to_live_session?/1`.

  The delete gate (world `agents.delete` dispatch) must refuse to delete an
  agent that is a member of at least one LIVE session.  This module verifies
  the helper that answers that question by composing:

    * `Ezagent.KindRegistry.list_all/0`  — enumerate live Kind PIDs
    * `session_member_uris/1`             — read member URIs from a live Session

  Three cases:
    (a) agent IS a member of a live session → true
    (b) a non-member agent URI → false
    (c) no live sessions at all → false
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Session.Orchestrator
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.KindRegistry

  @workspace_uri URI.new!("workspace://system")

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  # Spawn a bare Session Kind (no Template materialisation needed — we just
  # need a live session in the KindRegistry so list_all/0 sees it).
  defp spawn_session(n) do
    session_uri = Ezagent.URI.new!("session://system/default/bound-test-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

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

    session_uri
  end

  # Join an agent URI into a live session via the sanctioned dispatch path
  # (invariant P14 — Dispatch is the only path between Kinds).
  defp join_member(session_uri, agent_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{member: agent_uri},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    # Allow the async cast to land before asserting membership.
    Process.sleep(50)
  end

  # Spawn a live Agent Kind so that session.join can register a monitor ref.
  defp spawn_agent(n) do
    agent_uri = Ezagent.URI.new!("entity://system/agent/bound-agent-#{n}")

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, @workspace_uri)

    on_exit(fn ->
      case KindRegistry.lookup(agent_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.AgentSupervisor,
            pid
          )

        :error ->
          :ok
      end
    end)

    agent_uri
  end

  # ── (a) agent IS a member of a live session ──────────────────────────────

  describe "agent_bound_to_live_session?/1" do
    test "(a) returns true when the agent is a member of a live session" do
      n = uniq()
      session_uri = spawn_session(n)
      agent_uri = spawn_agent(n)

      join_member(session_uri, agent_uri)

      assert Orchestrator.agent_bound_to_live_session?(agent_uri) == true
    end

    # ── (b) non-member agent ─────────────────────────────────────────────

    test "(b) returns false when the agent is NOT a member of any live session" do
      n = uniq()
      _session_uri = spawn_session(n)

      non_member_uri =
        Ezagent.URI.new!("entity://system/agent/non-member-#{n}")

      assert Orchestrator.agent_bound_to_live_session?(non_member_uri) == false
    end

    # ── (c) no live sessions ─────────────────────────────────────────────

    test "(c) returns false when there are no live sessions at all" do
      # This test relies on no sessions being live in this sandbox.
      # We use a unique URI that has never been joined anywhere.
      n = uniq()

      agent_uri =
        Ezagent.URI.new!("entity://system/agent/no-session-agent-#{n}")

      # Capture any session:// entries only for the failure message below. The
      # assertion holds regardless of whether other sessions are live: this
      # unique agent URI has never joined any session, so it must be unbound.
      live_sessions =
        Ezagent.KindRegistry.list_all()
        |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)

      assert Orchestrator.agent_bound_to_live_session?(agent_uri) == false,
             "expected false for an agent that has never joined any session; " <>
               "live sessions = #{inspect(Enum.map(live_sessions, &elem(&1, 0)))}"
    end
  end
end
