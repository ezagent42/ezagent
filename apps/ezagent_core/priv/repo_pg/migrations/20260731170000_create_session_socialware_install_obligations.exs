defmodule EzagentCore.Repo.Migrations.CreateSessionSocialwareInstallObligations do
  use Ecto.Migration

  def change do
    create table(:session_socialware_install_obligations) do
      add :session_uri, :text, null: false
      add :workspace_uri, :text, null: false
      add :actor_uri, :text
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :claim_token, :text
      add :next_attempt_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_socialware_install_obligations, [:session_uri])
    create index(:session_socialware_install_obligations, [:workspace_uri])

    create index(
             :session_socialware_install_obligations,
             [:status, :next_attempt_at]
           )
  end
end
