defmodule EzagentCore.Repo.Migrations.AddIncarnationIdToCredentialGrants do
  use Ecto.Migration

  def change do
    alter table(:credential_grants) do
      # #201 PR-3 (R4) — immutable grant-incarnation id. Compensation for a
      # losing / non-created spawn attempt deletes EXACTLY the row that
      # attempt minted (transactional compare-on-identity), so a stale
      # compensator can never delete a DIFFERENT incarnation's row after a
      # hard-delete + reinsert (version resets to 1 → URI+version is not an
      # identity).
      add :incarnation_id, :string
    end

    # #201-cred (codex r3 MEDIUM-4) — the NULL-incarnation BACKFILL is NOT here.
    # This migration column-add was already applied on dev/upgraded databases
    # (introduced round-1, PR-3) BEFORE the backfill existed, so a backfill added
    # to THIS file would never run on those DBs (Ecto sees `20260727120000`
    # already applied). The backfill therefore lives in its own later-timestamped
    # migration (`20260728000000_backfill_credential_grant_incarnation_id.exs`),
    # which every already-upgraded DB will run on its next `ecto.migrate`.
  end
end
