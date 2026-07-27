defmodule EzagentCore.Repo.Migrations.AddIncarnationIdToCredentialGrants do
  use Ecto.Migration

  def change do
    alter table(:credential_grants) do
      # #201 PR-3 (R4) — immutable grant-incarnation id. Compensation for a
      # losing / non-created spawn attempt deletes EXACTLY the row that
      # attempt minted (transactional compare-on-identity), so a stale
      # compensator can never delete a DIFFERENT incarnation's row after a
      # hard-delete + reinsert (version resets to 1 → URI+version is not an
      # identity). NULL for rows minted before this column existed — those
      # never match an incarnation-scoped delete (fail-conservative).
      add :incarnation_id, :string
    end
  end
end
