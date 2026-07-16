defmodule Ezagent.Socialware.ReuseBindTest do
  @moduledoc """
  P1 role-slot reuse path: existing agent reuse must enter through the
  operator-caller `session.join` path, so the Part C admission gate can pend a
  foreign agent instead of mounting it under an admin materializer caller.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Identity.Authority
  alias Ezagent.Orchestrator.Tools.Participants
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws, do: "reuse-bind-#{uniq()}"

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp agent_member(ws, prefix) do
    uri = URI.new!("entity://#{ws}/agent/#{prefix}-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Capability.workspace_of(uri))
    uri
  end

  defp grant_manage(granter, target) do
    cap =
      Ezagent.CreatorGrant.manage_cap(:agent, target, Capability.workspace_of(target), granter)

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        granter,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )
  end

  defp within_session_caps(session_uri, caller) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    MapSet.new([signed_action_cap!(target, caller)])
  end

  defp add_participant(session_uri, operator, member_uri, role_name) do
    Participants.add_participant(member_uri, role_name,
      caller: operator,
      caps: within_session_caps(session_uri, operator),
      workspace_uri: Capability.workspace_of(session_uri),
      session_uri: session_uri
    )
  end

  defp session_state(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: state}} when is_map(state) -> state
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  end

  defp read_pending(session_uri), do: session_state(session_uri) |> Map.get(:pending_members, %{})
  defp read_members(session_uri), do: session_state(session_uri) |> Map.get(:members, %{})

  defp member_cap_over?(%Capability{} = cap, session_uri) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Capability.action_of(cap) == :receive and cap.instance == session_uri
  end

  defp member_cap_over?(_, _), do: false

  defp member_cap(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.find(&member_cap_over?(&1, session_uri))
  end

  defp wait_member_cap(entity_uri, session_uri, retries \\ 100) do
    cond do
      member_cap(entity_uri, session_uri) ->
        member_cap(entity_uri, session_uri)

      retries > 0 ->
        Process.sleep(10)
        wait_member_cap(entity_uri, session_uri, retries - 1)

      true ->
        nil
    end
  end

  test "operator reuse-binds their own agent and the role facet mounts on the edge" do
    ws = new_ws()
    operator = confirmed_user(ws, "operator")
    session_uri = new_session("own", operator)
    agent_uri = agent_member(ws, "owned-agent")
    grant_manage(operator, agent_uri)

    assert Authority.manages?(operator, agent_uri)

    assert {:ok, ^agent_uri} = add_participant(session_uri, operator, agent_uri, "bot")

    assert wait_member_cap(agent_uri, session_uri)
    assert %{^agent_uri => %{role_name: "bot"}} = read_members(session_uri)
    refute Map.has_key?(read_pending(session_uri), agent_uri)
  end

  test "operator reuse-bind of a foreign agent pends through session.join" do
    ws = new_ws()
    operator = confirmed_user(ws, "operator")
    owner = confirmed_user(ws, "owner")
    session_uri = new_session("foreign", operator)
    foreign_agent_uri = agent_member(ws, "foreign-agent")
    grant_manage(owner, foreign_agent_uri)

    refute Authority.manages?(operator, foreign_agent_uri)
    assert Authority.manages?(owner, foreign_agent_uri)

    assert {:ok, ^foreign_agent_uri} =
             add_participant(session_uri, operator, foreign_agent_uri, "bot")

    assert Map.has_key?(read_pending(session_uri), foreign_agent_uri)
    refute Map.has_key?(read_members(session_uri), foreign_agent_uri)
    refute member_cap(foreign_agent_uri, session_uri)

    entry = Map.fetch!(read_pending(session_uri), foreign_agent_uri)
    assert entry.requested_by == operator
  end
end
