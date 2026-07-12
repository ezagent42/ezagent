defmodule EzagentCore.Repo.Migrations.CreateSocialwareCompositionConsents do
  use Ecto.Migration

  def change do
    create table(:socialware_composition_consents, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false

      add :binding_id,
          references(:socialware_composition_bindings,
            type: :string,
            column: :id,
            on_delete: :delete_all
          ),
          null: false

      add :target_approval, :string, null: false, default: "pending"
      add :source_approval, :string, null: false, default: "pending"
      add :target_owner_uri, :string
      add :source_owner_uri, :string
      add :target_approver_uri, :string
      add :source_approver_uri, :string
      add :target_decided_at, :utc_datetime_usec
      add :source_decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:socialware_composition_consents, [:binding_id])
    create index(:socialware_composition_consents, [:workspace_uri])
    create index(:socialware_composition_consents, [:target_owner_uri, :target_approval])
    create index(:socialware_composition_consents, [:source_owner_uri, :source_approval])

    create constraint(
             :socialware_composition_consents,
             :socialware_composition_consents_target_approval,
             check:
               "target_approval IN ('pending', 'approved', 'denied', 'revoked', 'superseded')"
           )

    create constraint(
             :socialware_composition_consents,
             :socialware_composition_consents_source_approval,
             check:
               "source_approval IN ('pending', 'approved', 'denied', 'revoked', 'superseded')"
           )

    create table(:socialware_composition_consent_commands, primary_key: false) do
      add :idempotency_key, :string, primary_key: true
      add :workspace_uri, :string, null: false

      add :binding_id,
          references(:socialware_composition_bindings,
            type: :string,
            column: :id,
            on_delete: :delete_all
          ),
          null: false

      add :side, :string, null: false
      add :command, :string, null: false
      add :actor_uri, :string, null: false
      add :result_state, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:socialware_composition_consent_commands, [:workspace_uri])
    create index(:socialware_composition_consent_commands, [:binding_id, :inserted_at])

    create constraint(
             :socialware_composition_consent_commands,
             :socialware_composition_consent_commands_side,
             check: "side IN ('target', 'source')"
           )

    create constraint(
             :socialware_composition_consent_commands,
             :socialware_composition_consent_commands_command,
             check: "command IN ('approve', 'deny', 'revoke')"
           )
  end
end
