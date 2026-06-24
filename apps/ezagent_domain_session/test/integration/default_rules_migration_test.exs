defmodule EzagentDomainInstanceMessage.Integration.DefaultRulesMigrationTest do
  @moduledoc """
  Mention-gated routing — `EzagentDomainInstanceMessage.DefaultRules` migration.

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

  use EzagentCore.DataCase, async: false

  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  # Sandbox provided by EzagentCore.DataCase (#92).

  defp system_default_rows do
    RuleStore.list(MentionRouting)
    |> Enum.filter(&(&1.source == RuleStore.system_default_source()))
  end

  # Wipe every persisted system_default row so the test starts from a
  # known shape. force: true is required — system_default rows are
  # delete-protected.
  defp wipe_system_defaults do
    for row <- system_default_rows() do
      delete_system_default(row.id)
    end

    :ok
  end

  defp delete_system_default(id, attempts_left \\ 5) do
    RuleStore.delete(id, force: true)
  rescue
    error in DBConnection.ConnectionError ->
      if attempts_left > 0 do
        Process.sleep(25)
        delete_system_default(id, attempts_left - 1)
      else
        reraise error, __STACKTRACE__
      end
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

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

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

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      assert [migrated] = system_default_rows()
      assert migrated.id == old.id
      assert migrated.receivers == @new_receivers

      refute migrated.enabled,
             "an admin-disabled default must NOT be resurrected by migration"
    end

    test "NO system_default row → seeds the new mention-gated default (enabled)" do
      wipe_system_defaults()
      assert system_default_rows() == []

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

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

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

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

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      assert [survivor] = system_default_rows()
      assert survivor.id == first.id
      assert survivor.enabled
      assert survivor.receivers == @new_receivers
    end

    test "bootstrap is idempotent — re-running keeps exactly one migrated row" do
      wipe_system_defaults()
      insert_old_shape_rule()

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()
      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      assert [row] = system_default_rows()
      assert row.receivers == @new_receivers
    end
  end

  # codex review — HIGH-2: the migration is atomic + fail-closed. The
  # non-atomic version deleted duplicates before updating the survivor,
  # logged errors, and still returned :ok — a partial failure could
  # reload BOTH the migrated default and a stale $session_members
  # default. These tests inject a fault at each step and assert the
  # store is left FULLY untouched (every row keeps the OLD
  # $session_members shape) and bootstrap/0 returns {:error, _} so the
  # registry is NOT reloaded from a half-migrated store.
  describe "migration is atomic + fail-closed (codex HIGH-2)" do
    @old_receivers [Resolver.session_members_token()]

    # Restore the config seam after each test so a leaked fault can't
    # poison a later test.
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_domain_session, :default_rules_migration_fault)
      end)

      :ok
    end

    test "receiver update fails → bootstrap returns {:error}, NO row migrated" do
      wipe_system_defaults()
      old = insert_old_shape_rule()
      assert old.enabled
      assert old.receivers == @old_receivers

      # Inject a failure into the survivor's update_receivers step.
      Application.put_env(
        :ezagent_domain_session,
        :default_rules_migration_fault,
        [{:update_receivers, {:error, :injected_update_failure}}]
      )

      result = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      # Fail-closed: bootstrap surfaces the error, does not return :ok.
      assert {:error, {:update_receivers_failed, _id, :injected_update_failure}} = result

      # The store is FULLY untouched — the survivor still carries the
      # OLD $session_members shape, NOT a half-migrated state. A
      # subsequent load_into_registry would NOT reintroduce a stale
      # $session_members default because bootstrap skipped the reload.
      assert [untouched] = system_default_rows()
      assert untouched.id == old.id
      assert untouched.receivers == @old_receivers, "rolled back — old shape preserved"
      assert untouched.enabled
    end

    test "duplicate delete fails → transaction rolls back, survivor NOT migrated, duplicates kept" do
      wipe_system_defaults()
      survivor = insert_old_shape_rule()
      dup = insert_old_shape_rule()
      assert length(system_default_rows()) == 2

      # The survivor update succeeds, then the duplicate delete fails.
      # The whole transaction must roll back — including the survivor
      # update — so we never get the survivor migrated AND a stale
      # $session_members duplicate still present.
      Application.put_env(
        :ezagent_domain_session,
        :default_rules_migration_fault,
        [{:delete_duplicate, {:error, :injected_delete_failure}}]
      )

      result = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      assert {:error, {:delete_duplicate_failed, _id, :injected_delete_failure}} = result

      # Atomic rollback: BOTH rows survive, BOTH on the OLD shape. The
      # storm is not half-fixed — the survivor was NOT migrated.
      rows = system_default_rows()
      assert length(rows) == 2, "delete rolled back — duplicate still present"

      for row <- rows do
        assert row.receivers == @old_receivers,
               "survivor update rolled back too — no half-migrated $session_users default"
      end

      assert Enum.any?(rows, &(&1.id == survivor.id))
      assert Enum.any?(rows, &(&1.id == dup.id))
    end

    test "after a failed migration a clean re-run fully migrates (recoverable)" do
      wipe_system_defaults()
      insert_old_shape_rule()
      insert_old_shape_rule()

      # First run fails at the delete step (fault fires once).
      Application.put_env(
        :ezagent_domain_session,
        :default_rules_migration_fault,
        [{:delete_duplicate, {:error, :injected_delete_failure}}]
      )

      assert {:error, _} = EzagentDomainInstanceMessage.DefaultRules.bootstrap()
      # Fault is one-shot — already cleared. Store untouched.
      assert length(system_default_rows()) == 2

      # A clean re-run (no injected fault) migrates fully.
      assert :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      assert [migrated] = system_default_rows()
      assert migrated.receivers == @new_receivers
    end
  end
end
