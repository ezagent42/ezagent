defmodule EzagentCore.Repo.Migrations.CreateSocialwareShareClaims do
  @moduledoc """
  URI-share (A1, Feishu model) — per-claimer acceptance record.

  A `ShareClaim` row means "this grantee clicked/accepted the share link for this
  target". Access is re-derived live (claim row AND `ShareSetting.active/1`), so
  the row is NOT a capability — clicking a link never makes you a durable
  collaborator, and the owner turning sharing off cuts all claimers off instantly
  (codex Fix 1). One row per target × grantee.
  """
  use Ecto.Migration

  def change do
    create table(:socialware_share_claims, primary_key: false) do
      add :target_uri, :string, primary_key: true
      add :grantee_uri, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :claimed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Live gate looks up by (target, grantee); the composite PK already indexes
    # that. A reverse index by target lists a share's claimers (Feishu "who has
    # accessed via the link").
    create index(:socialware_share_claims, [:target_uri])
    create index(:socialware_share_claims, [:workspace_uri])
  end
end
