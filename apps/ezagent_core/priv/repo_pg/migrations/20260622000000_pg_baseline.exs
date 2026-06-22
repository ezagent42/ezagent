defmodule EzagentCore.Repo.Migrations.PgBaseline do
  use Ecto.Migration

  def change do
    create table(:invocations) do
      add :trace_id, :string
      add :caller, :string
      add :target, :string, null: false
      add :action, :string
      add :args, :text
      add :result, :text
      add :duration_us, :integer
      add :authz, :string
      add :exception, :text
      add :workspace_uri, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:invocations, [:inserted_at])
    create index(:invocations, [:target, :inserted_at])
    create index(:invocations, [:workspace_uri])

    create table(:dlq) do
      add :reason, :string, null: false
      add :payload, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:dlq, [:inserted_at])

    create table(:kind_snapshots, primary_key: false) do
      add :uri, :string, primary_key: true
      add :kind_type, :string, null: false
      add :state, :map
      add :state_binary, :binary
      add :version, :integer, null: false, default: 0
      add :workspace_uri, :string, null: false
      add :ever_created, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:kind_snapshots, [:workspace_uri])

    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :sender, :string, null: false
      add :mentions, {:array, :string}, null: false, default: []
      add :body, :map, null: false
      add :ref_id, :string
      add :inserted_at, :utc_datetime_usec, null: false
      add :visibility, :string, null: false, default: "customer_visible"
      add :routed_at, :utc_datetime_usec
    end

    create index(:messages, [:session_uri, :inserted_at])
    create index(:messages, [:sender])
    create index(:messages, [:workspace_uri])
    create index(:messages, [:session_uri, :routed_at])

    create table(:routing_rules) do
      add :table_name, :string, null: false
      add :matcher_data, :map, null: false
      add :receivers, {:array, :string}, null: false, default: []
      add :created_by, :string
      add :created_at, :utc_datetime_usec, null: false
      add :source, :string, null: false, default: "admin"
      add :enabled, :boolean, null: false, default: true
      add :applies_to_users, :text, null: false, default: "[]"
      add :workspace_uri, :string
      add :rule_set, :string
      add :position, :integer, null: false, default: 0
      add :prompt_template_ref, :string
    end

    create index(:routing_rules, [:table_name])
    create index(:routing_rules, [:workspace_uri])
    create index(:routing_rules, [:rule_set])

    create table(:workspaces) do
      add :name, :string, null: false
      add :uri, :string, null: false
      add :member_uris, :text, null: false, default: "[]"
      add :session_templates, :text, null: false, default: "{}"
      add :routing_rules, :text, null: false, default: "[]"
      add :created_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:name])
    create unique_index(:workspaces, [:uri])

    create table(:users) do
      add :uri, :string, null: false
      add :password_hash, :string
      add :caps_json, :text, null: false, default: "[]"
      add :workspace_uri, :string, null: false
      add :confirmed, :boolean, null: false, default: false
      add :email_verified, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:uri])
    create index(:users, [:workspace_uri])

    create table(:entity_tokens) do
      add :entity_uri, :string, null: false
      add :token_hash, :string, null: false
      add :label, :string
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :workspace_uri, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:entity_tokens, [:entity_uri])
    create index(:entity_tokens, [:workspace_uri])

    create table(:entity_profiles, primary_key: false) do
      add :entity_uri, :string, primary_key: true
      add :display_name, :string, null: false
      add :email, :string
      add :workspace_uri, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entity_profiles, ["lower(email)"],
             name: :entity_profiles_email_lower_index,
             where: "email IS NOT NULL"
           )

    create index(:entity_profiles, [:workspace_uri])

    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:magic_link_tokens) do
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :purpose, :string, null: false, default: "login"
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:magic_link_tokens, [:token_hash])
    create index(:magic_link_tokens, [:email])

    create table(:template_tags) do
      add :workspace_uri, :string, null: false
      add :name, :string, null: false
      add :tag, :string, null: false
      add :version_hash, :string, null: false
      add :created_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:template_tags, [:workspace_uri, :name, :tag])
    create index(:template_tags, [:workspace_uri])

    create table(:read_markers) do
      add :workspace_uri, :string, null: false
      add :session_uri, :string, null: false
      add :user_uri, :string, null: false
      add :source, :string, null: false
      add :last_read_message_uri, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:read_markers, [:workspace_uri, :session_uri, :user_uri, :source])
    create index(:read_markers, [:workspace_uri])

    create table(:workspace_magic_link_rules) do
      add :workspace_uri, :string, null: false
      add :rule_type, :string, null: false
      add :rule_value, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_magic_link_rules, [:workspace_uri, :rule_type, :rule_value])
    create index(:workspace_magic_link_rules, [:workspace_uri])

    create table(:external_mirror_bindings, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :adapter_id, :string, null: false
      add :target_id, :string, null: false
      add :opts_json, :text, null: false, default: "{}"
      add :bound_by, :string, null: false
      add :bound_at, :utc_datetime_usec, null: false
      add :workspace_uri, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:external_mirror_bindings, [:session_uri, :adapter_id, :target_id],
             name: :external_mirror_bindings_natural_key_index
           )

    create index(:external_mirror_bindings, [:workspace_uri])

    create table(:feishu_user_bindings, primary_key: false) do
      add :open_id, :string, primary_key: true
      add :user_uri, :string, null: false
      add :bound_by, :string, null: false
      add :bound_at, :utc_datetime_usec, null: false
    end

    create table(:agent_lineage, primary_key: false) do
      add :agent_uri, :string, primary_key: true
      add :spawned_by, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:credential_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :credential_source_uri, :string, null: false
      add :approved_by, :string, null: false
      add :approved_scope, :string, null: false
      add :version, :integer, null: false, default: 1
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_grants, [:agent_uri], name: :credential_grants_agent_uri_index)
    create index(:credential_grants, [:workspace_uri])

    create table(:user_default_credential_sources, primary_key: false) do
      add :id, :string, primary_key: true
      add :owner_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :flavor, :string, null: false
      add :source_uri, :string, null: false
      add :set_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_default_credential_sources, [:workspace_uri])

    create table(:workspace_shared_credential_sources, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :flavor, :string, null: false
      add :source_uri, :string, null: false
      add :set_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_shared_credential_sources, [:workspace_uri])

    create table(:socialware_settlements, primary_key: false) do
      add :turn_id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :target_surface_version, :integer
      add :expected_prior_approved, :integer
      add :subwrites_done, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :committed_at, :utc_datetime_usec
      add :conflict_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_settlements, [:workspace_uri])
    create index(:socialware_settlements, [:session_uri])

    create table(:socialware_settlement_messages, primary_key: false) do
      add :turn_id, :string, null: false
      add :message_id, :string, null: false
      add :workspace_uri, :string, null: false
    end

    create unique_index(:socialware_settlement_messages, [:turn_id, :message_id],
             name: :socialware_settlement_messages_pkey
           )

    create index(:socialware_settlement_messages, [:message_id],
             name: :socialware_settlement_messages_message_id_index
           )

    create index(:socialware_settlement_messages, [:workspace_uri])

    create table(:socialware_customer_outbox, primary_key: false) do
      add :turn_id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :message_ids, {:array, :string}, null: false, default: []
      add :surface_version, :integer
      add :committed_seq, :integer
      add :emitted_at, :utc_datetime_usec
    end

    create index(:socialware_customer_outbox, [:workspace_uri])
    create index(:socialware_customer_outbox, [:session_uri, :committed_seq])

    create table(:socialware_config_objects, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :subject_uri, :string, null: false
      add :key, :string, null: false
      add :body, :map, null: false
      add :created_by, :string, null: false
      add :source_turn_id, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :socialware_config_objects,
             [:workspace_uri, :subject_uri, :key, :source_turn_id],
             where: "source_turn_id IS NOT NULL",
             name: :socialware_config_objects_unique_source_turn
           )

    create index(:socialware_config_objects, [:workspace_uri])

    create table(:socialware_config_pointers, primary_key: false) do
      add :id, :string, primary_key: true
      add :layer, :string, null: false
      add :workspace_uri, :string, null: false
      add :subject_uri, :string, null: false
      add :key, :string, null: false
      add :config_id, :string, null: false
      add :previous_config_id, :string
      add :pointed_by, :string, null: false
      add :source_turn_id, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_config_pointers, [:workspace_uri])

    create table(:socialware_anon_bindings, primary_key: false) do
      add :entity_uri, :string, primary_key: true
      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :last_seen_at, :utc_datetime_usec
      add :reaping_at, :utc_datetime_usec
      add :merging_to, :string
      add :merge_state, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_anon_bindings, [:workspace_uri])
    create index(:socialware_anon_bindings, [:session_uri])

    create table(:invite_codes) do
      add :code, :string, null: false
      add :workspace_uri, :string, null: false
      add :role, :string
      add :max_uses, :integer, null: false, default: 1
      add :used_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :created_by, :string, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invite_codes, [:code], name: :invite_codes_code_index)

    create constraint(:invite_codes, :invite_codes_max_uses_positive, check: "max_uses >= 1")
    create constraint(:invite_codes, :invite_codes_used_count_valid,
             check: "used_count >= 0 AND used_count <= max_uses"
           )
  end
end
