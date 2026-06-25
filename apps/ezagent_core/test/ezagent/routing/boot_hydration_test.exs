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
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.RoutingRegistry
  alias Ezagent.Routing.{Matcher, RuleStore}

  # The single durable routing table in the system. Declared by
  # `EzagentDomainInstanceMessage.Application` at boot (it owns writes);
  # the resolver reads it.
  @table EzagentDomainInstanceMessage.Routing.MentionRouting

  # Sandbox provided by EzagentCore.DataCase (#92).

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

    # GUARANTEED cleanup (codex #721 review): steps 2-4 mutate the PRODUCTION
    # singleton MentionRouting ETS table. If any assertion fails or
    # `load_into_registry/1` raises, ExUnit would otherwise unwind with the table
    # left wiped/stale and poison unrelated routing tests (SQL-sandbox rollback
    # does NOT restore ETS). `try/after` runs in THIS (sandbox-checked-out)
    # process on every exit path: delete the test row + reload from the DB, which
    # restores the table to its exact pre-test contents (DB rules minus our row).
    # The `test-receiver://` scheme is also not in the global SchemeRegistry, so
    # leaving the rule live could crash a concurrent send in `URI.new!/1`.
    try do
      # 2. Simulate a FRESH BOOT: the process-owned ETS table is recreated
      #    empty on restart. Clear the live registry to that empty state.
      :ok = RoutingRegistry.replace_table_contents(@table, [])
      refute rule_present?(receiver), "precondition: registry must be empty after wipe"

      # 3. Run the boot hydration step (what the boot path invokes).
      assert :ok = RuleStore.load_into_registry(@table)

      # 4. The durable rule must be back in the LIVE registry — resolvable.
      assert rule_present?(receiver),
             "G1-b regression: a durable RuleStore rule was NOT re-hydrated into " <>
               "the live RoutingRegistry on a simulated fresh boot"
    after
      _ = RuleStore.delete(row.id, force: true)
      _ = RuleStore.load_into_registry(@table)
    end
  end

  defp rule_present?(receiver) do
    RoutingRegistry.list_all(@table)
    |> Enum.any?(fn
      {_matcher, %{receivers: r}} -> receiver in r
      _ -> false
    end)
  end
end
