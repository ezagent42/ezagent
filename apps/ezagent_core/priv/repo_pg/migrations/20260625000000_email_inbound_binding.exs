defmodule EzagentCore.Repo.Migrations.EmailInboundBinding do
  @moduledoc """
  #88 PR-2 (email external-mirror adapter inbound, SPEC §3/§4.4/§6) —
  durable, email-OWNED per-binding inbound metadata.

  ## Why an email-owned side-table (plan D4 — spec §6 deviation, spirit-preserved)

  Spec §6 describes `local_address` + `verification_status` as columns on
  the GENERIC `external_mirror_bindings` projection row. But that row is
  written by the GENERIC `Ezagent.Behavior.ExternalMirror.do_bind/3` (a
  fixed-column path shared by Feishu + protocol_api + email) with no
  adapter-callback seam — adding email-specific columns there is a generic
  domain-contract change touching the other adapters (against the North
  Star: keep plugin concerns out of core). So email metadata lives in this
  email-owned table instead, keyed by `binding_row_id` (the
  `Ezagent.ExternalMirror.BindingRow.row_id/3` value), FK CASCADE to
  `external_mirror_bindings(id)` — the SAME proven pattern PR-1's
  `email_thread_state` uses. Zero core change; Feishu/protocol_api
  untouched. The lead may later lift `local_address` onto the generic row
  for the cross-session admin LV — out of scope for PR-2.

  ## Columns

  - `binding_row_id` (PK, FK CASCADE) — one inbound-meta row per binding.
  - `local_address` (UNIQUE) — ezagent's own alias address; the inbound
    reverse-lookup authority (`To:` → row → session, spec §3/§6). UNIQUE so
    an inbound `To:` resolves to AT MOST one binding (the whole inbound
    security model rests on this).
  - `session_uri` + `target_id` — denormalized so inbound is a single-table
    lookup `local_address → (session_uri, target_id, status)`.
  - `verification_status` (`"pending_verification" | "verified"`, default
    pending) — SERVER-OWNED; flipped to `"verified"` ONLY by the web
    confirm path, NEVER from caller opts (forgery-safe, plan D1).
  - `verification_token_hash` + `verification_expires_at` — binding-scoped
    one-time confirm token (SHA-256 of the raw token; raw goes in the link
    only). MagicLinkToken keys by email not binding, so a binding-scoped
    token is minted here.
  - `workspace_uri` (NOT NULL) — per-tenant scoping (invariant #14).

  ## Indexes

  - UNIQUE on `local_address` — inbound reverse-lookup authority.
  - UNIQUE on `session_uri` — §6.1 "one email binding per session" (v1).
  - non-unique on `workspace_uri` — per-tenant queries.
  """

  use Ecto.Migration

  def change do
    create table(:email_inbound_binding, primary_key: false) do
      add :binding_row_id,
          references(:external_mirror_bindings,
            column: :id,
            type: :string,
            on_delete: :delete_all
          ),
          primary_key: true

      add :local_address, :string, null: false
      add :session_uri, :string, null: false
      add :target_id, :string, null: false
      add :verification_status, :string, null: false, default: "pending_verification"
      add :verification_token_hash, :binary
      add :verification_expires_at, :utc_datetime_usec
      add :workspace_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_inbound_binding, [:local_address],
             name: :email_inbound_binding_local_address_index
           )

    create unique_index(:email_inbound_binding, [:session_uri],
             name: :email_inbound_binding_session_uri_index
           )

    create index(:email_inbound_binding, [:workspace_uri],
             name: :email_inbound_binding_workspace_uri_index
           )
  end
end
