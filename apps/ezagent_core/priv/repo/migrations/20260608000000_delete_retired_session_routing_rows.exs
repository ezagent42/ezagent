defmodule EzagentCore.Repo.Migrations.DeleteRetiredSessionRoutingRows do
  @moduledoc """
  2026-05-25 — SessionRouting retirement (greenfield delete, no
  back-compat path, per `feedback_let_it_crash_no_workarounds` +
  Allen's explicit greenfield authorization).

  Background
  ----------

  PR-EM-3 (#317) shipped the ExternalMirror domain with the
  `external_mirror_bindings` table. The Feishu chat ↔ session bridge
  that `SessionRouting` (a `routing_rules.table_name` group) previously
  held has fully migrated there. The `SessionRouting` table declaration
  is being removed from `EzagentDomainChat.Application`, along with
  every code-side reference (resolver default tables, default-rules
  bootstrap, /routing LV table switcher, admin_live session-scoped
  rule listing, RoutingRegistry boot test).

  Any `routing_rules` rows whose `table_name` still names the retired
  module would become orphans — `RuleStore.load_into_registry/1` is
  no longer called for them, so they would sit in the DB unread but
  not gone. This migration removes them.

  Behavior
  --------

  - Forward-only `DELETE` against the legacy `table_name` string
    `"Elixir.EzagentDomainChat.Routing.SessionRouting"`.
  - Idempotent: re-running the migration on an already-cleaned DB is
    a no-op (delete-where-exists).
  - No backfill / migration to ExternalMirror: those rows were the
    chat ↔ session URI map; ExternalMirror builds its bindings from
    `Ezagent.ExternalMirror.bind/3` calls (admin LV / CLI / API), not
    from imported routing rules.

  No-back-compat precedent: same shape as
  `20260603000000_phase9_remove_legacy_admin_seed.exs` (delete the
  legacy row, no `down/0` re-seed).
  """
  use Ecto.Migration

  def up do
    execute(
      "DELETE FROM routing_rules WHERE table_name = 'Elixir.EzagentDomainChat.Routing.SessionRouting'"
    )
  end

  def down do
    # Re-seed is intentionally NOT supported. SessionRouting was the
    # legacy chat ↔ session bridge; its responsibility now lives in
    # `external_mirror_bindings`. Re-creating retired rows would
    # require resurrecting the deleted module + the bridge code that
    # read from it, which is the opposite of greenfield delete.
    :ok
  end
end
