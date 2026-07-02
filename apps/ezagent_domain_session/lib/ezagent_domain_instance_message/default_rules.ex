defmodule EzagentDomainInstanceMessage.DefaultRules do
  @moduledoc """
  Phase 4-completion PR 9 §A: declarative default routing rules for the
  chat plugin's RoutingRegistry tables.

  Previously (Phase 3): default fan-out (send to in-session members)
  was hardcoded in `Ezagent.ActionSet.Session.invoke(:send, ...)` as a
  fall-through branch — a leak per "no scattered routing logic"
  principle (Allen 2026-05-16).

  Now: the default fan-out is **a system_default rule** that
  `Ezagent.Routing.Resolver` expands at resolve time. `/admin/routing`
  shows it as a real (but protected) row.

  ## The mention-gated default (2026-05-22)

  Per `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  (rev 3), the `system_default` rule is:

      matcher: {:always}   receivers: ["$session_users", "$mentions"]

  (was `["$session_members"]`). Agent actuation is now mention-gated:
  an un-mentioned agent gets no `chat.receive`, while every User
  member still gets their per-user notification via `$session_users`
  and the session stream stays unconditional.

  ## Migration of an existing `system_default` row (SPEC §4)

  `bootstrap/0` MIGRATES — it does not skip — an existing persisted
  `system_default` row. Hazards a naive re-seed would hit:

  - `RuleStore.has_system_default?/1` returns true for ANY
    `source == "system_default"` row regardless of `enabled` — a
    "skip if a system_default exists" idempotency would skip even
    when only a DISABLED old row exists.
  - An admin may have intentionally **disabled** the system_default.
  - There may be duplicate system_default rows.

  Migration algorithm (`migrate_system_default_rule/0`):

  1. List all `system_default` rows in `MentionRouting`.
  2. **No rows** → seed the new `{:always} → [$session_users,
     $mentions]` (enabled).
  3. **One or more rows** → **disabled-wins** dedupe: keep the oldest
     (by `id`) deterministically; its surviving `enabled` is the AND
     of every duplicate's `enabled` (any admin-disabled row keeps the
     survivor disabled); replace its receivers IN PLACE with
     `[$session_users, $mentions]`; delete the rest; log the dedupe.

  ## Atomicity + fail-closed (codex review — HIGH-2)

  The dedupe + update + delete sequence runs inside a single
  `EzagentCore.Repo.transaction/1`, ordered **survivor-update FIRST,
  then duplicate-deletes**, and ANY error (`update_receivers/3` or a
  delete returning `{:error, _}`) calls `Repo.rollback/1`. Either the
  store is FULLY migrated or it is FULLY untouched — never the
  half-applied states the non-atomic version could leave:

  - a delete of an enabled duplicate succeeds but the survivor update
    fails → both the migrated survivor and a stale `$session_members`
    default would reload → broadcast fan-out reintroduced;
  - the survivor update succeeds but a duplicate delete fails →
    duplicate `system_default` rows persist.

  On a transaction failure `migrate_system_default_rule/0` returns
  `{:error, reason}` and `bootstrap/0` propagates it — it does NOT
  `load_into_registry/1` a partially-migrated store and does NOT
  return `:ok`. The caller (`EzagentDomainInstanceMessage.Application`) crashes
  on the non-`:ok` return, so a migration that cannot complete
  cleanly fails the boot loudly rather than silently degrading.

  ## Bootstrap semantics

  - Idempotent — re-running migrates an already-migrated row to the
    same shape (a no-op in effect).
  - Admin's `disable/1` is preserved — a disabled default stays
    disabled across migration.
  - `enabled` flag respected by `load_into_registry/1`.
  - Fail-closed — `bootstrap/0` returns `{:error, reason}` (and the
    registry is NOT reloaded) when the migration cannot complete.
  """

  require Logger

  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  # The migrated default rule's receivers (SPEC §3).
  defp default_receivers,
    do: [Resolver.session_users_token(), Resolver.mentions_token()]

  @doc """
  Bootstrap default rules + hydrate persisted rules into RoutingRegistry.
  Idempotent — safe to call on every boot.

  Fail-closed (codex review — HIGH-2): if `migrate_system_default_rule/0`
  cannot complete cleanly the transaction is rolled back, this returns
  `{:error, reason}`, and the registry is NOT reloaded — a
  partially-migrated store is never hydrated. The caller crashes on the
  non-`:ok` return, so a failed migration fails the boot loudly.
  """
  @spec bootstrap :: :ok | {:error, term()}
  def bootstrap do
    case migrate_system_default_rule() do
      :ok ->
        :ok = RuleStore.load_into_registry(MentionRouting)
        :ok

      {:error, reason} ->
        Logger.error(
          "EzagentDomainInstanceMessage.DefaultRules: system_default migration failed — " <>
            "NOT reloading the routing registry (a partially-migrated store " <>
            "must never be hydrated): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # SPEC §4 — migrate (not skip) an existing system_default row.
  #
  # codex review HIGH-2 — the dedupe + update + delete sequence is
  # atomic + fail-closed: it runs inside a single Repo.transaction,
  # the survivor is UPDATED before duplicates are deleted, and any
  # error rolls the whole transaction back. The store is either fully
  # migrated or fully untouched.
  @spec migrate_system_default_rule :: :ok | {:error, term()}
  defp migrate_system_default_rule do
    system_default = RuleStore.system_default_source()

    rows =
      RuleStore.list(MentionRouting)
      |> Enum.filter(&(&1.source == system_default))
      # Deterministic order — oldest first. RuleStore.list/1 already
      # orders by :id asc, but be explicit so the "keep oldest" choice
      # is not coupled to that implementation detail.
      |> Enum.sort_by(& &1.id)

    case rows do
      [] ->
        seed_default_rule()

      [survivor | duplicates] ->
        migrate_existing_rows(survivor, duplicates, rows)
    end
  end

  # Atomic migration of one or more existing system_default rows.
  # Wrapped in Repo.transaction — survivor UPDATED first, duplicates
  # deleted after; ANY error rolls the whole thing back so the store
  # is never left half-migrated.
  defp migrate_existing_rows(survivor, duplicates, rows) do
    # disabled-wins: the survivor's enabled = AND of all rows'
    # enabled. If ANY system_default row is disabled, the migrated
    # survivor stays disabled — an admin's opt-out is never lost.
    merged_enabled = Enum.all?(rows, & &1.enabled)

    txn =
      Repo.transaction(fn ->
        # 1. Update the survivor FIRST. If this fails the transaction
        #    rolls back before any duplicate is deleted — the old
        #    rows survive intact (no half-migrated store).
        Logger.info(
          "EzagentDomainInstanceMessage.DefaultRules: migrating system_default rule " <>
            "id=#{survivor.id} receivers → #{inspect(default_receivers())} " <>
            "(enabled=#{merged_enabled})"
        )

        case migration_step(:update_receivers, fn ->
               RuleStore.update_receivers(survivor.id, default_receivers(), merged_enabled)
             end) do
          :ok ->
            :ok

          {:error, reason} ->
            Repo.rollback({:update_receivers_failed, survivor.id, reason})
        end

        # 2. Delete the duplicates. A delete failure rolls the whole
        #    transaction back — including the survivor update — so we
        #    never end up with the survivor migrated AND a stale
        #    $session_members duplicate still present.
        case duplicates do
          [] ->
            :ok

          _ ->
            Logger.warning(
              "EzagentDomainInstanceMessage.DefaultRules: found #{length(rows)} system_default " <>
                "rows in MentionRouting — deduping. Keeping id=#{survivor.id} " <>
                "(oldest), deleting #{inspect(Enum.map(duplicates, & &1.id))}. " <>
                "Survivor enabled=#{merged_enabled} (disabled-wins AND of " <>
                "#{inspect(Enum.map(rows, & &1.enabled))})."
            )

            for dup <- duplicates do
              case migration_step(:delete_duplicate, fn ->
                     RuleStore.delete(dup.id, force: true)
                   end) do
                :ok ->
                  :ok

                {:error, reason} ->
                  Repo.rollback({:delete_duplicate_failed, dup.id, reason})
              end
            end
        end

        :ok
      end)

    case txn do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "EzagentDomainInstanceMessage.DefaultRules: system_default migration transaction " <>
            "rolled back — the store is untouched: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # No existing system_default row → seed the new mention-gated
  # default. Fail-closed: a seed failure returns {:error, reason} so
  # bootstrap/0 does not reload an empty routing table as if all were
  # well.
  defp seed_default_rule do
    Logger.info(
      "EzagentDomainInstanceMessage.DefaultRules: seeding system_default rule " <>
        "(always → #{inspect(default_receivers())}) into MentionRouting"
    )

    case RuleStore.add(
           MentionRouting,
           Matcher.always(),
           default_receivers(),
           nil,
           source: RuleStore.system_default_source()
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "EzagentDomainInstanceMessage.DefaultRules: failed to seed system_default rule: #{inspect(reason)}"
        )

        {:error, {:seed_failed, reason}}
    end
  end

  # Test seam (codex review HIGH-2 verification) — runs `step_fn` and
  # returns its result, EXCEPT when a test has injected a fault for
  # this `step` name via the `:default_rules_migration_fault` config
  # key, in which case it returns the configured `{:error, reason}`.
  #
  # This exists purely so the failure-path test can exercise the
  # transaction rollback / fail-closed branch deterministically — a
  # real `update_receivers/3` or `delete/2` failure cannot be forced
  # from a single-process sandboxed test without interleaving a
  # concurrent delete. It is a strict no-op in dev/prod (the config
  # key is unset), NOT a behavioral shim: when no fault is configured
  # the real step result is returned unchanged.
  #
  # Config shape: `{step_atom, {:error, reason}}` or a list of such
  # tuples — each fault fires AT MOST ONCE (it is cleared from config
  # after firing) so a multi-step migration still completes once the
  # injected failure has been observed.
  defp migration_step(step, step_fn) when is_atom(step) and is_function(step_fn, 0) do
    case pop_injected_fault(step) do
      {:ok, error} -> error
      :none -> step_fn.()
    end
  end

  defp pop_injected_fault(step) do
    faults = Application.get_env(:ezagent_domain_session, :default_rules_migration_fault)

    case List.wrap(faults) do
      [] ->
        :none

      list ->
        case Enum.split_with(list, fn {s, _err} -> s == step end) do
          {[], _rest} ->
            :none

          {[{^step, error} | more_for_step], rest} ->
            remaining = more_for_step ++ rest

            if remaining == [] do
              Application.delete_env(:ezagent_domain_session, :default_rules_migration_fault)
            else
              Application.put_env(:ezagent_domain_session, :default_rules_migration_fault, remaining)
            end

            {:ok, error}
        end
    end
  end
end
