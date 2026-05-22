defmodule EzagentDomainChat.DefaultRules do
  @moduledoc """
  Phase 4-completion PR 9 §A: declarative default routing rules for the
  chat plugin's RoutingRegistry tables.

  Previously (Phase 3): default fan-out (send to in-session members)
  was hardcoded in `Ezagent.Behavior.Chat.invoke(:send, ...)` as a
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
     `[$session_users, $mentions]`; force-delete the rest; log the
     dedupe.

  ## Bootstrap semantics

  - Idempotent — re-running migrates an already-migrated row to the
    same shape (a no-op in effect).
  - Admin's `disable/1` is preserved — a disabled default stays
    disabled across migration.
  - `enabled` flag respected by `load_into_registry/1`.
  """

  require Logger

  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias EzagentDomainChat.Routing.{MentionRouting, SessionRouting}

  # The migrated default rule's receivers (SPEC §3).
  defp default_receivers,
    do: [Resolver.session_users_token(), Resolver.mentions_token()]

  @doc """
  Bootstrap default rules + hydrate persisted rules into RoutingRegistry.
  Idempotent — safe to call on every boot.
  """
  @spec bootstrap :: :ok
  def bootstrap do
    :ok = migrate_system_default_rule()
    :ok = RuleStore.load_into_registry(MentionRouting)
    :ok = RuleStore.load_into_registry(SessionRouting)
    :ok
  end

  # SPEC §4 — migrate (not skip) an existing system_default row.
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
        # disabled-wins: the survivor's enabled = AND of all rows'
        # enabled. If ANY system_default row is disabled, the migrated
        # survivor stays disabled — an admin's opt-out is never lost.
        merged_enabled = Enum.all?(rows, & &1.enabled)

        case duplicates do
          [] ->
            :ok

          _ ->
            Logger.warning(
              "EzagentDomainChat.DefaultRules: found #{length(rows)} system_default " <>
                "rows in MentionRouting — deduping. Keeping id=#{survivor.id} " <>
                "(oldest), deleting #{inspect(Enum.map(duplicates, & &1.id))}. " <>
                "Survivor enabled=#{merged_enabled} (disabled-wins AND of " <>
                "#{inspect(Enum.map(rows, & &1.enabled))})."
            )

            for dup <- duplicates do
              case RuleStore.delete(dup.id, force: true) do
                :ok ->
                  :ok

                {:error, reason} ->
                  Logger.error(
                    "EzagentDomainChat.DefaultRules: failed to delete duplicate " <>
                      "system_default rule id=#{dup.id}: #{inspect(reason)}"
                  )
              end
            end
        end

        Logger.info(
          "EzagentDomainChat.DefaultRules: migrating system_default rule " <>
            "id=#{survivor.id} receivers → #{inspect(default_receivers())} " <>
            "(enabled=#{merged_enabled})"
        )

        case RuleStore.update_receivers(survivor.id, default_receivers(), merged_enabled) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "EzagentDomainChat.DefaultRules: failed to migrate system_default " <>
                "rule id=#{survivor.id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp seed_default_rule do
    Logger.info(
      "EzagentDomainChat.DefaultRules: seeding system_default rule " <>
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
          "EzagentDomainChat.DefaultRules: failed to seed system_default rule: #{inspect(reason)}"
        )

        :ok
    end
  end
end
