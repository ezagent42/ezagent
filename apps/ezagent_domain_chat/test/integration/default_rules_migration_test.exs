defmodule EzagentDomainChat.Integration.DefaultRulesMigrationTest do
  @moduledoc """
  Mention-gated routing — `EzagentDomainChat.DefaultRules` migration.

  Implements `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  §4 + §6.6:

  - an OLD `{:always} → [$session_members]` enabled row → migrated
    receivers `[$session_users, $mentions]`, still enabled;
  - an OLD row DISABLED → migrated receivers, STILL disabled (an
    admin's opt-out is never resurrected);
  - mixed enabled/disabled duplicate system_default rows → deduped to
    one row, and that survivor is DISABLED (disabled-wins).

  Each test resets the persisted `system_default` rows to a chosen
  shape, runs `DefaultRules.bootstrap/0`, and inspects the result.
  Non-async — it mutates the shared `routing_rules` table + the
  process-global RoutingRegistry the live app owns.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias EzagentDomainChat.Routing.MentionRouting

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  defp system_default_rows do
    RuleStore.list(MentionRouting)
    |> Enum.filter(&(&1.source == RuleStore.system_default_source()))
  end

  # Wipe every persisted system_default row so the test starts from a
  # known shape. force: true is required — system_default rows are
  # delete-protected.
  defp wipe_system_defaults do
    for row <- system_default_rows() do
      :ok = RuleStore.delete(row.id, force: true)
    end

    :ok
  end

  # Insert an OLD-shape system_default row: `{:always} → [$session_members]`.
  defp insert_old_shape_rule do
    {:ok, row} =
      RuleStore.add(
        MentionRouting,
        Matcher.always(),
        [Resolver.session_members_token()],
        nil,
        source: RuleStore.system_default_source()
      )

    row
  end

  @new_receivers [Resolver.session_users_token(), Resolver.mentions_token()]

  describe "migration of an existing system_default row (SPEC §4)" do
    test "OLD {:always} → $session_members ENABLED → migrated, still enabled" do
      wipe_system_defaults()
      old = insert_old_shape_rule()
      assert old.enabled
      assert old.receivers == [Resolver.session_members_token()]

      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      assert [migrated] = system_default_rows()
      # In-place migration — same row id, receivers replaced.
      assert migrated.id == old.id
      assert migrated.receivers == @new_receivers
      assert migrated.enabled, "an enabled default must stay enabled"
    end

    test "OLD row DISABLED → migrated receivers, STILL disabled" do
      wipe_system_defaults()
      old = insert_old_shape_rule()
      :ok = RuleStore.disable(old.id)

      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      assert [migrated] = system_default_rows()
      assert migrated.id == old.id
      assert migrated.receivers == @new_receivers

      refute migrated.enabled,
             "an admin-disabled default must NOT be resurrected by migration"
    end

    test "NO system_default row → seeds the new mention-gated default (enabled)" do
      wipe_system_defaults()
      assert system_default_rows() == []

      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      assert [seeded] = system_default_rows()
      assert seeded.receivers == @new_receivers
      assert seeded.enabled
      assert seeded.matcher_data == %{"type" => "always"}
    end

    test "mixed enabled/disabled duplicates → deduped, survivor DISABLED (disabled-wins)" do
      wipe_system_defaults()

      enabled_row = insert_old_shape_rule()
      disabled_row = insert_old_shape_rule()
      third_row = insert_old_shape_rule()
      :ok = RuleStore.disable(disabled_row.id)

      # Three system_default rows now exist; one is disabled.
      assert length(system_default_rows()) == 3

      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      # Deduped down to exactly one.
      assert [survivor] = system_default_rows()

      # Oldest kept deterministically.
      assert survivor.id == enabled_row.id

      # disabled-wins: ANY disabled duplicate → survivor disabled.
      refute survivor.enabled,
             "disabled-wins: a disabled duplicate must leave the survivor disabled"

      assert survivor.receivers == @new_receivers

      # The other two rows are gone.
      refute Enum.any?(system_default_rows(), &(&1.id == disabled_row.id))
      refute Enum.any?(system_default_rows(), &(&1.id == third_row.id))
    end

    test "all-enabled duplicates → deduped, survivor stays ENABLED" do
      wipe_system_defaults()

      first = insert_old_shape_rule()
      _second = insert_old_shape_rule()

      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      assert [survivor] = system_default_rows()
      assert survivor.id == first.id
      assert survivor.enabled
      assert survivor.receivers == @new_receivers
    end

    test "bootstrap is idempotent — re-running keeps exactly one migrated row" do
      wipe_system_defaults()
      insert_old_shape_rule()

      :ok = EzagentDomainChat.DefaultRules.bootstrap()
      :ok = EzagentDomainChat.DefaultRules.bootstrap()

      assert [row] = system_default_rows()
      assert row.receivers == @new_receivers
    end
  end
end
