defmodule EzagentCore.Repo.Migrations.ShareSettingsAnonSession do
  use Ecto.Migration

  # A5 (`link_anon`) — record the DEDICATED PUBLIC SESSION provisioned for a
  # target when anonymous sharing is enabled.
  #
  # Why a column on the share row rather than a new table: the binding is 1:1
  # with the share setting (one dedicated session per shared target, provisioned
  # idempotently from a deterministic key), its lifecycle is exactly the share's
  # (enable provisions, disable retires), and the anon read path needs the
  # REVERSE direction — "this public session is showing which target?" — which a
  # unique index on this column answers without a second source of truth.
  #
  # Nullable by design: `link_login` shares never provision a session, so the
  # column stays NULL for every row that is not an anon share.
  def change do
    alter table(:socialware_share_settings) do
      add :anon_session_uri, :string
    end

    # Unique: a provisioned public session shows exactly ONE target. The reverse
    # lookup (`ShareSetting.by_anon_session/1`) is on the anon read hot path.
    create unique_index(:socialware_share_settings, [:anon_session_uri],
             where: "anon_session_uri IS NOT NULL",
             name: :socialware_share_settings_anon_session_uri_index
           )
  end
end
