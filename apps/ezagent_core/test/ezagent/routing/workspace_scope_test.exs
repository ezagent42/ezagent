defmodule Ezagent.Routing.WorkspaceScopeTest do
  @moduledoc """
  Phase 6 PR 8 — per-rule workspace scope coverage.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}

  @session_uri URI.new!("session://default/team-alpha/test")
  @user_a URI.new!("entity://user/team-alpha/alice")
  @recv URI.new!("entity://user/team-alpha/recv")
  @ws_alpha URI.new!("workspace://alpha")
  @ws_beta URI.new!("workspace://beta")

  setup do
    table = :"phase6_ws_routing_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)
    Application.put_env(:ezagent_core, :routing_tables, [table])
    on_exit(fn -> Application.delete_env(:ezagent_core, :routing_tables) end)
    {:ok, table: table}
  end

  test "nil workspace_uri = applies globally (BC)", %{table: table} do
    {:ok, _} =
      RuleStore.add(table, Matcher.always(), [@recv], @user_a, workspace_uri: nil)

    :ok = RuleStore.load_into_registry(table)

    msg = Message.new(@user_a, %{text: "hi"})

    # no workspace context — global rule applies
    assert [%URI{}] = Resolver.resolve(msg, @session_uri, [], [])
    # alpha context — global rule still applies
    assert [%URI{}] =
             Resolver.resolve(msg, @session_uri, [], workspace_uri: @ws_alpha)
  end

  test "non-nil workspace_uri scopes the rule", %{table: table} do
    {:ok, _} =
      RuleStore.add(table, Matcher.always(), [@recv], @user_a, workspace_uri: @ws_alpha)

    :ok = RuleStore.load_into_registry(table)

    msg = Message.new(@user_a, %{text: "hi"})

    # alpha context — scoped rule fires
    assert [%URI{}] =
             Resolver.resolve(msg, @session_uri, [], workspace_uri: @ws_alpha)

    # beta context — scoped rule does NOT fire
    assert [] = Resolver.resolve(msg, @session_uri, [], workspace_uri: @ws_beta)

    # nil context — scoped rule does NOT fire
    assert [] = Resolver.resolve(msg, @session_uri, [], [])
  end

  test "mix: global + scoped rules combine sensibly", %{table: table} do
    # Global rule routing to recv_global
    {:ok, _} =
      RuleStore.add(
        table,
        Matcher.always(),
        [URI.new!("entity://user/team-alpha/recv-global")],
        @user_a,
        workspace_uri: nil
      )

    # alpha-scoped rule routing to recv_alpha
    {:ok, _} =
      RuleStore.add(
        table,
        Matcher.always(),
        [URI.new!("entity://user/team-alpha/recv-alpha")],
        @user_a,
        workspace_uri: @ws_alpha
      )

    :ok = RuleStore.load_into_registry(table)

    msg = Message.new(@user_a, %{text: "hi"})

    in_alpha = Resolver.resolve(msg, @session_uri, [], workspace_uri: @ws_alpha)
    in_alpha_strs = Enum.map(in_alpha, &URI.to_string/1)

    assert "entity://user/team-alpha/recv-global" in in_alpha_strs
    assert "entity://user/team-alpha/recv-alpha" in in_alpha_strs

    in_no_ws = Resolver.resolve(msg, @session_uri, [], [])
    in_no_ws_strs = Enum.map(in_no_ws, &URI.to_string/1)

    assert "entity://user/team-alpha/recv-global" in in_no_ws_strs
    refute "entity://user/team-alpha/recv-alpha" in in_no_ws_strs
  end
end
