defmodule EzagentCore.Repo.Migrations.BindProviderExecutionIdentity do
  use Ecto.Migration

  def up do
    alter table(:provider_authorization_backend_records) do
      add :execution_identity, :text
    end

    create constraint(
             :provider_authorization_backend_records,
             :provider_authorization_backend_records_execution_identity_check,
             check: "execution_identity IS NOT NULL AND execution_identity <> ''"
           )
  end

  def down do
    drop constraint(
           :provider_authorization_backend_records,
           :provider_authorization_backend_records_execution_identity_check
         )

    alter table(:provider_authorization_backend_records) do
      remove :execution_identity
    end
  end
end
