defmodule EzagentCore.Repo.Migrations.AppSettings do
  @moduledoc """
  Username & Auth M2 — key-value runtime config store.

  Holds UI-managed runtime config: `smtp_config` and
  `registration_domains`. Values are JSON text. The SMTP password is
  stored as-is — Ezagent has no at-rest encryption today (ApiKeys stores
  plaintext too); encryption is a separate project-wide decision.
  """
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
