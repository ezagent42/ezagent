defmodule Ezagent.Routing.RuntimeAddTest do
  @moduledoc """
  PR #127 regression — runtime rule adds via `RuleStore.add` +
  `RuleStore.load_into_registry` MUST update the live RoutingRegistry
  immediately, even when invoked from a non-table-owner process.

  Bug fixed: pre-PR-127 `RoutingRegistry.put/3` had a strict
  `assert_owner` check that returned `{:error, {:not_owner, ...}}`
  silently when called from the LV process (LV ≠ chat plugin's
  Application owner). Rules landed in DB but didn't take effect
  until phx restart re-loaded the rules in the owner process.

  Allen 2026-05-19 02:54 caught this when his routing-via-UI add
  didn't fire until phx restart.

  This test simulates a write from a separate Task process (not
  the test process which would otherwise be the table owner if it
  declared the test table itself).
  """
  use ExUnit.Case, async: false

  alias Ezagent.RoutingRegistry
  alias Ezagent.Routing.{Matcher, RuleStore}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  test "replace_table_contents/2 works from a non-owner process" do
    # Declare table under THIS process. Then call replace from another.
    table = :"pr127_test_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    entries = [
      {{:always}, %{receivers: ["x://1"], applies_to_users: [], workspace_uri: nil}},
      {{:always}, %{receivers: ["x://2"], applies_to_users: [], workspace_uri: nil}}
    ]

    # Run replace from a Task (different pid from the owner).
    task = Task.async(fn -> RoutingRegistry.replace_table_contents(table, entries) end)
    assert :ok = Task.await(task, 5_000)

    # Verify both entries landed.
    rows = RoutingRegistry.list_all(table)
    assert length(rows) == 2
    receivers = rows |> Enum.flat_map(fn {_k, v} -> v.receivers end) |> Enum.sort()
    assert receivers == ["x://1", "x://2"]
  end

  test "replace_table_contents/2 deletes stale entries (not just inserts)" do
    table = :"pr127_replace_#{System.unique_integer([:positive])}"
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    # Seed with one entry.
    :ok =
      RoutingRegistry.replace_table_contents(table, [
        {{:always}, %{receivers: ["x://old"], applies_to_users: [], workspace_uri: nil}}
      ])

    assert length(RoutingRegistry.list_all(table)) == 1

    # Replace with a different entry — old should be gone.
    :ok =
      RoutingRegistry.replace_table_contents(table, [
        {{:mention, "x://new"},
         %{receivers: ["x://new"], applies_to_users: [], workspace_uri: nil}}
      ])

    rows = RoutingRegistry.list_all(table)
    assert length(rows) == 1
    assert match?([{{:mention, "x://new"}, _}], rows)
  end

  test "RuleStore.load_into_registry from a non-owner process reflects DB state" do
    # The chat plugin owns MentionRouting at boot. Test process is
    # not the owner. Adding a rule via RuleStore.add + load_into_registry
    # from this test process must still update the live table.
    table = EzagentDomainInstanceMessage.Routing.MentionRouting

    {:ok, row} =
      RuleStore.add(
        table,
        Matcher.always(),
        ["test-receiver://pr127"],
        nil
      )

    # Trigger reload from this (non-owner) process.
    assert :ok = RuleStore.load_into_registry(table)

    # Verify the rule is in the live table.
    rows = RoutingRegistry.list_all(table)

    found =
      Enum.any?(rows, fn
        {_matcher, %{receivers: r}} -> "test-receiver://pr127" in r
        _ -> false
      end)

    # Clean up BEFORE asserting (still inside the test's shared sandbox
    # connection). This rule lands in the PRODUCTION MentionRouting table
    # (a global singleton), and its `test-receiver://` receiver scheme is
    # NOT in the global SchemeRegistry — left in place, any concurrent
    # chat send (ChatRoutingTest / MentionFailedTest) resolves this rule
    # and crashes in Ezagent.URI.new!/1 ("scheme test-receiver not
    # registered"). Remove the rule + reload so the global table returns
    # to its pre-test state regardless of the assertion outcome.
    _ = RuleStore.delete(row.id, force: true)
    :ok = RuleStore.load_into_registry(table)

    assert found, "PR #127 regression: rule added via RuleStore.add not in live RoutingRegistry"
  end
end
