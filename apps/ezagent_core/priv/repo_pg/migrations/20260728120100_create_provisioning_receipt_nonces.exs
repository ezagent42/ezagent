defmodule EzagentCore.Repo.Migrations.CreateProvisioningReceiptNonces do
  use Ecto.Migration

  # #189 PR-1 (codex F3a): consumed provisioning-receipt nonces — the
  # SINGLE-USE ledger for `Ezagent.Identity.ProvisioningReceipt`. A nonce is
  # inserted inside the provisioning transaction (ON CONFLICT DO NOTHING on
  # the PK); a replay conflicts and the provision is rejected.
  def change do
    create table(:provisioning_receipt_nonces, primary_key: false) do
      add :nonce, :string, primary_key: true
      add :consumed_at, :utc_datetime_usec, null: false
    end

    create index(:provisioning_receipt_nonces, [:consumed_at])
  end
end
