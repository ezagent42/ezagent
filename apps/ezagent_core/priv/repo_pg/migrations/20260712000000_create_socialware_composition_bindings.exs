defmodule EzagentCore.Repo.Migrations.CreateSocialwareCompositionBindings do
  use Ecto.Migration

  def change do
    create table(:socialware_composition_bindings, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :session_uri, :string, null: false
      add :install_id, :string, null: false
      add :definition_config_id, :string, null: false
      add :definition_content_hash, :string, null: false
      add :source_role, :string, null: false
      add :target_role, :string, null: false
      add :source_uri, :string, null: false
      add :target_uri, :string, null: false
      add :behavior, :string, null: false
      add :action, :string, null: false
      add :issuer_uri, :string, null: false
      add :cap, :map, null: false
      add :cap_identity, :string, null: false
      add :status, :string, null: false, default: "active"
      add :inactive_reason, :string
      add :inactivated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_composition_bindings, [:workspace_uri])
    create index(:socialware_composition_bindings, [:session_uri, :status])
    create index(:socialware_composition_bindings, [:source_uri, :cap_identity, :status])
    create index(:socialware_composition_bindings, [:target_uri, :status])

    create constraint(
             :socialware_composition_bindings,
             :socialware_composition_bindings_status,
             check: "status IN ('active', 'degraded', 'inactive')"
           )
  end
end
