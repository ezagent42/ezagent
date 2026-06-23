defmodule EzagentCore.Repo.Migrations.EmailThreadState do
  @moduledoc """
  #88 PR-1 (email external-mirror adapter SPEC §4.3 / HIGH 5) — durable
  RFC 5322 threading state for the email ExternalMirror Binding.

  ## Why durable

  RFC 5322 threading needs the thread's root `Message-ID`, the last
  outbound `Message-ID` (for `In-Reply-To`), and the full `References`
  chain so the human's mail client groups the conversation. The
  per-binding `Ezagent.Email.Binding` runtime state is TRANSIENT (lost on
  Worker restart / node restart), so threading state MUST be durable —
  otherwise a restart breaks the chain and the human sees a new thread.

  ## Key

  PK = `binding_row_id` (the `Ezagent.ExternalMirror.BindingRow.row_id/3`
  value — one thread per binding). The Binding computes this from the
  SERVER-STAMPED `msg.session_uri` at publish time (never from
  caller-controlled opts), so it always equals the parent binding row id.

  ## FK CASCADE (rebind = new thread — plan D3)

  `binding_row_id REFERENCES external_mirror_bindings(id) ON DELETE
  CASCADE`. An `:unbind` deletes the `external_mirror_bindings` row; the
  CASCADE clears the thread state so a later rebind (which reuses the same
  row id for the same `(session, adapter, target)`) starts a FRESH thread
  rather than silently continuing the old one, and leaves no orphan rows.

  ## workspace_uri (P21 / invariant #14)

  `workspace_uri NOT NULL` per
  `per_tenant_tables_have_workspace_column_test.exs`. Derived structurally
  from the session by the Binding at write time.

  ## Repo path

  Lives in `priv/repo_pg/migrations` (the PG-only suite path set in
  `config/test.exs` `priv: "priv/repo_pg"`); the legacy SQLite
  `priv/repo/migrations` path is dead for the PG suite.
  """

  use Ecto.Migration

  def change do
    create table(:email_thread_state, primary_key: false) do
      add :binding_row_id,
          references(:external_mirror_bindings,
            column: :id,
            type: :string,
            on_delete: :delete_all
          ),
          primary_key: true

      add :root_message_id, :string
      add :last_message_id, :string
      add :references_chain, :text
      add :workspace_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_thread_state, [:workspace_uri],
             name: :email_thread_state_workspace_uri_index
           )
  end
end
