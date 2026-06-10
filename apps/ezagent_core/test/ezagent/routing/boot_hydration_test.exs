defmodule Ezagent.Routing.BootHydrationTest do
  @moduledoc """
  G1-b regression — durable routing rules in `RuleStore` (SQLite) MUST be
  re-loaded into the live `RoutingRegistry` ETS table on a fresh boot.

  The failure this guards against: after a server restart the
  RoutingRegistry ETS table is recreated EMPTY (it is process-owned, not
  persistent), so a rule that survives in SQLite but is never hydrated
  back into ETS will never route — the resolver reads ETS, not SQLite.
  Symptom: a seeded routing rule persists in the DB across restart but a
  customer message stores yet never reaches the bot.

  This is the `load_into_registry/1` round-trip gate (DB rule → cleared
  registry → hydrate → present) the boot-time hydration relies on. The
  boot wiring that actually calls it lives in
  `EzagentDomainInstanceMessage.DefaultRules.bootstrap/0` (run from that
  domain's `Application.start/2`); this test pins the underlying contract
  that wiring depends on.
  """
  use ExUnit.Case, async: false

  alias Ezagent.RoutingRegistry
  alias Ezagent.Routing.{Matcher, RuleStore}

  # The single durable routing table in the system. Declared by
  # `EzagentDomainInstanceMessage.Application` at boot (it owns writes);
  # the resolver reads it.
  @table EzagentDomainInstanceMessage.Routing.MentionRouting

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  test "a durable rule survives a simulated fresh boot via load_into_registry/1" do
    receiver = "test-receiver://g1b-boot-hydration"

    # 1. Install a durable (admin) routing rule — this persists to SQLite.
    {:ok, row} =
      RuleStore.add(
        @table,
        Matcher.always(),
        [receiver],
        URI.new!("entity://system/user/admin")
      )

    # 2. Simulate a FRESH BOOT: the process-owned ETS table is recreated
    #    empty on restart. Clear the live registry to that empty state.
    #    (`replace_table_contents/2` with [] wipes the table.)
    :ok = RoutingRegistry.replace_table_contents(@table, [])
    refute rule_present?(receiver), "precondition: registry must be empty after wipe"

    # 3. Run the boot hydration step (what the boot path invokes).
    assert :ok = RuleStore.load_into_registry(@table)

    # 4. The durable rule must be back in the LIVE registry — resolvable.
    present? = rule_present?(receiver)

    # Restore the global MentionRouting table to its pre-test state BEFORE
    # asserting: this rule lands in the PRODUCTION singleton table and its
    # `test-receiver://` scheme is not in the global SchemeRegistry, so a
    # concurrent chat send would otherwise resolve it and crash in
    # `Ezagent.URI.new!/1`. (Same hygiene as runtime_add_test.exs.)
    _ = RuleStore.delete(row.id, force: true)
    :ok = RuleStore.load_into_registry(@table)

    assert present?,
           "G1-b regression: a durable RuleStore rule was NOT re-hydrated into " <>
             "the live RoutingRegistry on a simulated fresh boot"
  end

  defp rule_present?(receiver) do
    RoutingRegistry.list_all(@table)
    |> Enum.any?(fn
      {_matcher, %{receivers: r}} -> receiver in r
      _ -> false
    end)
  end
end
