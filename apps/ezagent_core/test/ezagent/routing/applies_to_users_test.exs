defmodule Ezagent.Routing.AppliesToUsersTest do
  @moduledoc """
  Phase 6 PR 5 — per-rule sender filter coverage.

  Validates:
  1. RuleStore.add accepts :applies_to_users opt + persists JSON
  2. load_into_registry wraps as `%{receivers:, applies_to_users:}`
  3. Resolver filters by sender against the list (empty = applies to all)
  4. Legacy `[receiver]` ETS shape still passes Resolver (back-compat)
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}

  @session_uri URI.new!("session://default/team-alpha/test")
  @user_a URI.new!("entity://user/team-alpha/alice")
  @user_b URI.new!("entity://user/team-alpha/bob")
  @recv_a URI.new!("entity://user/team-alpha/recv-a")
  @recv_b URI.new!("entity://user/team-alpha/recv-b")

  # Per-test unique table — declared by the test pid (owner), so puts
  # in this test succeed. Table dies with test pid — no cross-test
  # pollution.
  setup do
    table = :"phase6_test_routing_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    Application.put_env(:ezagent_core, :routing_tables, [table])
    on_exit(fn -> Application.delete_env(:ezagent_core, :routing_tables) end)

    {:ok, table: table}
  end

  test "RuleStore.add stores applies_to_users as JSON", %{table: table} do
    {:ok, rule} =
      RuleStore.add(table, Matcher.always(), [@recv_a], @user_a, applies_to_users: [@user_a])

    assert RuleStore.applies_to_users(rule) == [URI.to_string(@user_a)]
  end

  test "Resolver applies rule only to listed senders", %{table: table} do
    {:ok, _} =
      RuleStore.add(table, Matcher.always(), [@recv_a], @user_a, applies_to_users: [@user_a])

    :ok = RuleStore.load_into_registry(table)

    msg_alice = Message.new(@user_a, %{text: "hi"})
    assert [%URI{}] = Resolver.resolve(msg_alice, @session_uri, [])

    msg_bob = Message.new(@user_b, %{text: "hi"})
    assert [] = Resolver.resolve(msg_bob, @session_uri, [])
  end

  test "empty applies_to_users means applies to every sender", %{table: table} do
    {:ok, _} =
      RuleStore.add(table, Matcher.always(), [@recv_a], @user_a, applies_to_users: [])

    :ok = RuleStore.load_into_registry(table)

    msg_alice = Message.new(@user_a, %{text: "hi"})
    msg_bob = Message.new(@user_b, %{text: "hi"})

    assert Resolver.resolve(msg_alice, @session_uri, []) != []
    assert Resolver.resolve(msg_bob, @session_uri, []) != []
  end

  test "multiple senders allowed via list", %{table: table} do
    {:ok, _} =
      RuleStore.add(table, Matcher.always(), [@recv_b], @user_a,
        applies_to_users: [@user_a, @user_b]
      )

    :ok = RuleStore.load_into_registry(table)

    msg_alice = Message.new(@user_a, %{text: "hi"})
    msg_bob = Message.new(@user_b, %{text: "hi"})
    msg_other = Message.new(URI.new!("entity://user/team-alpha/carol"), %{text: "hi"})

    assert Resolver.resolve(msg_alice, @session_uri, []) != []
    assert Resolver.resolve(msg_bob, @session_uri, []) != []
    assert Resolver.resolve(msg_other, @session_uri, []) == []
  end

  test "legacy list-shaped ETS entry (no users filter) still resolves",
       %{table: table} do
    # Direct RoutingRegistry.put with plain list value — what tests +
    # pre-PR-5 callers wrote. Resolver must keep working with this shape.
    RoutingRegistry.put(table, Matcher.always(), [URI.to_string(@recv_a)])

    msg = Message.new(@user_a, %{text: "hi"})
    assert [%URI{}] = Resolver.resolve(msg, @session_uri, [])
  end
end
