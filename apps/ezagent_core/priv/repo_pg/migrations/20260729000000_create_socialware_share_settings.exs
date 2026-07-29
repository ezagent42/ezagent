defmodule EzagentCore.Repo.Migrations.CreateSocialwareShareSettings do
  use Ecto.Migration

  # URI-share unification (A1 redesign) — the per-target "sharing setting", the
  # single owner-controlled toggle that governs whether a share LINK grants access
  # (like a doc's "link sharing: off / anyone-with-link" switch), separate from
  # the permission layer (who holds a cap). Modeled on the per-session
  # `web_anon_access` policy, but per-target. Authority to share lives HERE (only
  # the owner can flip it), not in the link — the link is a stateless pointer.
  # One row per target; revocation = flip `enabled` to false.
  def change do
    create table(:socialware_share_settings, primary_key: false) do
      add :target_uri, :string, primary_key: true
      add :enabled, :boolean, null: false, default: false
      # The openness level (superset spanning login-link → anon). `link_login`
      # grants an authenticated clicker a person-cap; `link_anon` is the most-open
      # level (routes to the session-scoped `web_anon_access` mechanism).
      add :visibility, :string, null: false, default: "link_login"
      # What the enabled link grants — the access the claim mints.
      add :behavior, :string
      add :actions_json, :string, null: false, default: "[]"
      add :access, :string
      # The owner who enabled sharing = the accountable granter of every claimed cap.
      add :granter_uri, :string
      add :workspace_uri, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
