defmodule EzagentCore.Repo.Migrations.CreateForgejoOauthApps do
  use Ecto.Migration

  # Forgejo provider V1 slice F0 (design
  # docs/superpowers/specs/2026-07-29-forgejo-provider-v1-design.md §5.1):
  # per-tenant OAuth application registrations.
  #
  # GitHub needs no such table — it is one hosted instance, so one App's
  # client_id/secret lives in config and serves everyone. Forgejo is
  # self-hosted: each instance is its own OAuth provider, so the credentials
  # are keyed by {workspace, instance host}. A tenant admin registers the
  # application once per instance in that instance's web UI (registering it
  # through the API would require a `write:user` token, which can modify
  # account settings — design §4.1.3) and the pair is recorded here.
  #
  # Per-tenant (SPEC v3 §7.4 / invariant 14): `workspace_uri` is NOT NULL and
  # is the first component of the primary key, so a lookup can never cross
  # tenants — a client_secret belonging to one workspace must not be reachable
  # from another.
  #
  # `client_secret_ciphertext` is AES-256-GCM sealed by the plugin before it
  # reaches this table; the nonce is stored alongside it. The column never
  # holds plaintext.
  def change do
    create table(:forgejo_oauth_apps, primary_key: false) do
      add :workspace_uri, :string, primary_key: true
      add :governed_host, :string, primary_key: true
      add :client_id, :string, null: false
      add :client_secret_ciphertext, :binary, null: false
      add :client_secret_nonce, :binary, null: false
      add :redirect_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:forgejo_oauth_apps, [:workspace_uri])
  end
end
