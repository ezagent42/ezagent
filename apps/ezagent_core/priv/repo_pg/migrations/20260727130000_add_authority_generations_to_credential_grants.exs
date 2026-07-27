defmodule EzagentCore.Repo.Migrations.AddAuthorityGenerationsToCredentialGrants do
  use Ecto.Migration

  def change do
    alter table(:credential_grants) do
      # #201-cred (codex r2 HIGH-5) — the authority generations the grant was
      # authorized under. Recorded at authorize time, re-validated under lock
      # at insertion (a stale attempt whose authorizing holder/source
      # generation ceased to be current is rejected) and again at every
      # materialization fetch. NULL for workspace-shared mints (no cap-borne
      # authorizing holder) and rows minted before this column existed —
      # those skip generation validation (fail-open for legacy rows only).
      add :holder_generation, :integer
      add :source_generation, :integer
    end
  end
end
