defmodule EzagentCore.Repo.Migrations.AddSocialwareAnonBindings do
  use Ecto.Migration

  # Issue #51 (design §3.4, OQ-4) — the anon external-user binding table:
  # the GC index AND the cookie→entity resolver for anonymous socialware viewers.
  #
  # A row maps one anon external-user (`entity://<ws>/user/anon-<random>`) to the
  # public socialware session it VIEWS, carrying the `last_seen_at` that the 48h GC
  # sweeps on (`Ezagent.Socialware.AnonUser.GC`). Additive — new table, no change to
  # existing data.
  #
  # ## Key = entity_uri (NOT a stored cookie token)
  #
  # OQ-4's sketch listed a `cookie_id_hash` column, but design §6 settled the
  # `socialware_anon` cookie as a SIGNED Phoenix.Token carrying
  # `{external_user_name, session_uri}` — self-describing + integrity-checked by the
  # signature, so a tampered cookie is rejected as "no cookie" (mint fresh). The
  # returning-visitor resolution (§4.1a) is therefore "verify cookie → reconstruct
  # the `entity://` URI → look it up, scoped to THIS session", and the GC + login-
  # replacement paths both key by the entity. No cookie secret needs persisting, so
  # the honest minimal primary key is `entity_uri` (one anon-User ⇄ one binding).
  def change do
    create table(:socialware_anon_bindings, primary_key: false) do
      # the anon external-user URI: entity://<viewed-workspace>/user/anon-<random>
      add :entity_uri, :string, primary_key: true
      add :session_uri, :string, null: false
      # invariant #14 — per-tenant tables carry workspace_uri NOT NULL
      add :workspace_uri, :string, null: false
      # the 48h-TTL basis; bumped on every public-route hit (touch/2)
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # GC sweeps the whole table by last_seen_at (hourly) — index it for the range
    # scan. entity_uri is the PK (already indexed) so get/delete/upsert need no extra
    # index. The per-session anon-member index (ceiling / login-replacement reap)
    # lands with its query function in the controller/sweeper PR — no speculative
    # index ahead of a consumer.
    create index(:socialware_anon_bindings, [:last_seen_at],
             name: :socialware_anon_bindings_last_seen_index
           )
  end
end
