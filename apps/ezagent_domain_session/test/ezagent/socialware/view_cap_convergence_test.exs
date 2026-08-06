defmodule Ezagent.Socialware.ViewCapConvergenceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.ViewCapConvergence

  defmodule TestRender do
    @moduledoc false
    def actions, do: [:test_render]
  end

  test "a strict roster read failure is loud" do
    session = session_uri("roster-failure")

    assert {:error, {:member_roster_read_failed, ^session, :database_busy}} =
             ViewCapConvergence.converge(session,
               roster_reader: fn ^session -> {:error, :database_busy} end
             )
  end

  test "a member grant failure retains its exact missing postcondition" do
    session = session_uri("grant-failure")
    member = confirmed_user("grant-member")

    assert {:error, {:member_view_cap_failed, ^member, TestRender, :test_render, :timeout}} =
             ViewCapConvergence.converge(session,
               roster_reader: fn ^session -> {:ok, [member]} end,
               grant_member: fn ^session, ^member ->
                 {:error, {:member_view_cap_failed, member, TestRender, :test_render, :timeout}}
               end
             )
  end

  test "only confirmed ordinary users reach the grant operation" do
    session = session_uri("eligibility")
    confirmed = confirmed_user("confirmed")
    unconfirmed = unconfirmed_user("unconfirmed")
    agent = Ezagent.URI.agent("system", "codex-agent-#{unique()}")
    absent_user = Ezagent.URI.user("system", "absent-#{unique()}")
    parent = self()

    assert :ok =
             ViewCapConvergence.converge(session,
               roster_reader: fn ^session ->
                 {:ok, [confirmed, unconfirmed, agent, absent_user]}
               end,
               grant_member: fn ^session, member ->
                 send(parent, {:granted, member})
                 :ok
               end
             )

    assert_receive {:granted, ^confirmed}
    refute_receive {:granted, _other}
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user("system", "#{prefix}-#{unique()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret", [])
    uri
  end

  defp unconfirmed_user(prefix) do
    uri = Ezagent.URI.user("system", "anon-#{prefix}-#{unique()}")
    {:ok, _row} = Ezagent.Users.create_read_only(uri)
    uri
  end

  defp session_uri(prefix), do: Ezagent.URI.session("system", "hello", "#{prefix}-#{unique()}")
  defp unique, do: System.unique_integer([:positive])
end
