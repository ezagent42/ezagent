defmodule EzagentCore.Repo.Migrations.BackfillCredentialGrantIncarnationId do
  use Ecto.Migration

  # #201-cred (codex r3 MEDIUM-4) — upgrade-safe NULL-incarnation backfill.
  #
  # `20260727120000_add_incarnation_id_to_credential_grants` only ADDED the
  # nullable column (round-1, PR-3). Rows that predate it — and any grant
  # inserted while the column existed but was still nullable — carry a NULL
  # `incarnation_id`. A NULL incarnation flows out of
  # `GrantRow.fetch_for_materialize/1` and would have raised `FunctionClauseError`
  # in the materialize-time revalidation before the runtime `nil` clause was
  # added; more importantly a NULL incarnation can never be compensated ABA-safely
  # (`delete_incarnation/2` matches on the exact id).
  #
  # A backfill added INSIDE `20260727120000` would NEVER run on a database that
  # already applied that version before the backfill was written (Ecto records
  # the version as applied and never re-runs it). This is a NEW, later-timestamped
  # migration so every already-upgraded database backfills on its next
  # `ecto.migrate`.
  #
  # The backfill value is DETERMINISTIC per row (`'legacy:' || id`, and `id` is
  # the PK = agent_uri, so it is unique) and cannot collide with a freshly minted
  # `Ecto.UUID` incarnation. Idempotent: the `WHERE incarnation_id IS NULL` guard
  # makes a re-run a no-op, and the down-migration only reverts the deterministic
  # `legacy:%` values it wrote.
  def change do
    execute(
      "UPDATE credential_grants SET incarnation_id = 'legacy:' || id WHERE incarnation_id IS NULL",
      "UPDATE credential_grants SET incarnation_id = NULL WHERE incarnation_id LIKE 'legacy:%'"
    )
  end
end
