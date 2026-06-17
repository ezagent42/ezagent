defmodule EzagentCore.Repo.Migrations.AddReapingAtToSocialwareAnonBindings do
  use Ecto.Migration

  # Issue #51 (§3.4) — crash-safe GC claim. The original sweeper deleted the
  # binding AS the claim, but the binding is BOTH the GC index and the claim token,
  # so a crash / failed leave mid-reap left an orphan (offline session-member +
  # `users` row) that no future sweep could rediscover (codex review).
  #
  # `reaping_at` makes the claim NON-destructive: the sweeper compare-and-UPDATEs it
  # (`SET reaping_at = now WHERE still-expired AND not-already-claimed`) instead of
  # deleting, so the row survives as the durable retry record through the leave +
  # `users`-delete; it is hard-deleted LAST. A row stuck in `reaping_at` past a
  # threshold is re-surfaced by `list_expired/2` so a crashed reap is retried (all
  # reap steps are idempotent). Additive — nullable, no backfill.
  def change do
    alter table(:socialware_anon_bindings) do
      add :reaping_at, :utc_datetime_usec, null: true
    end
  end
end
