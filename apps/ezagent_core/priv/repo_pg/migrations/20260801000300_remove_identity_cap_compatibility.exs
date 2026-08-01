defmodule EzagentCore.Repo.Migrations.RemoveIdentityCapCompatibility do
  use Ecto.Migration

  def up do
    drop_if_exists table(:identity_cutover)

    execute "ALTER TABLE identity_caps DROP CONSTRAINT IF EXISTS identity_caps_identity_status_check"
    execute "ALTER TABLE identity_caps ALTER COLUMN identity_status SET DEFAULT 'staged'"

    execute """
    ALTER TABLE identity_caps
    ADD CONSTRAINT identity_caps_identity_status_check
    CHECK (identity_status IN ('staged', 'active', 'revoked_unprovisioned', 'tombstoned'))
    """

    alter table(:users) do
      remove(:caps_json)
    end
  end

  def down do
    alter table(:users) do
      add(:caps_json, :text, null: false, default: "[]")
    end

    create table(:identity_cutover, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:activated_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    execute "ALTER TABLE identity_caps DROP CONSTRAINT IF EXISTS identity_caps_identity_status_check"

    execute "UPDATE identity_caps SET identity_status = 'revoked_unprovisioned' WHERE identity_status = 'staged'"

    execute "ALTER TABLE identity_caps ALTER COLUMN identity_status SET DEFAULT 'active'"

    execute """
    ALTER TABLE identity_caps
    ADD CONSTRAINT identity_caps_identity_status_check
    CHECK (identity_status IN ('active', 'revoked_unprovisioned', 'tombstoned'))
    """
  end
end
