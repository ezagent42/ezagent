defmodule EzagentCore.Repo.Migrations.CreateForgejoCredentials do
  use Ecto.Migration

  # Forgejo provider credential custody, made durable.
  #
  # Before this table the credentials lived in an ETS table owned by one Agent.
  # That table dies with its owner, so a SINGLE crash of that process wiped
  # every user's OAuth credential on the node while the durable
  # `provider_connections` rows kept pointing at them — leaving connections that
  # look active and fail on lease. Recovery was a browser re-authorization per
  # user per instance, because the refresh token was in the same wiped record.
  #
  # This matters for Forgejo in a way it does not for GitHub: a GitHub App mints
  # a fresh installation token per operation from a config-held private key, so
  # its stored token is identity-only. A Forgejo access token IS the repository
  # credential.
  #
  # Columns follow `provider_authorization_backend_records`: the sealed envelope
  # is `{key_id, key_fingerprint, nonce, ciphertext}` from
  # `Ezagent.ProviderConnection.SealedEnvelope`, which supports rotation (rows
  # open under the key they recorded).
  #
  # Per-tenant: `workspace_uri` NOT NULL.
  def change do
    create table(:forgejo_credentials, primary_key: false) do
      add :credential_ref, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :credential_version, :integer, null: false, default: 1
      add :key_id, :string, null: false
      add :key_fingerprint, :binary, null: false
      add :nonce, :binary, null: false
      add :ciphertext, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:forgejo_credentials, [:workspace_uri])
  end
end
