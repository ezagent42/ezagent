defmodule EzagentCore.Repo.Migrations.FenceProviderCallbackOperations do
  use Ecto.Migration

  def change do
    alter table(:provider_connection_operations) do
      add :attempt_version, :bigint
      add :attempt_claim_token, :text
      add :handoff_ref, :text
    end
  end
end
