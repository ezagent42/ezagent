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

    # #201-cred (codex r2 NEW-MEDIUM-4) — backfill existing rows so NO durable
    # grant is left with a NULL incarnation. A NULL incarnation would flow out
    # of `GrantRow.fetch_for_materialize/1` and raise `FunctionClauseError` in
    # the materialize-time revalidation (`revalidate_version!/3`), interacting
    # with the compensation-on-raise hole. The backfill value is DETERMINISTIC
    # per row (`'legacy:' || id`, and `id` is the PK = agent_uri, so it is
    # unique) and cannot collide with a freshly minted `Ecto.UUID` incarnation.
    # The runtime `nil`-incarnation clause in `revalidate_version!/3` remains as
    # the defensive safety net (rows the backfill could not reach on a dev DB
    # that already ran this migration before the backfill was added).
    execute(
      "UPDATE credential_grants SET incarnation_id = 'legacy:' || id WHERE incarnation_id IS NULL",
      "UPDATE credential_grants SET incarnation_id = NULL WHERE incarnation_id LIKE 'legacy:%'"
    )
  end
end
