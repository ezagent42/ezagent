defmodule EzagentCore.Repo.Migrations.PrEm3ExternalMirrorBindings do
  @moduledoc """
  PR-EM-3 (ExternalMirror Domain SPEC §7.1) — projection table for the
  Session Kind's `:external_mirror` slice.

  ## Direction

  The Session's `:external_mirror` slice is the single source of truth
  per **P3** — this table is a **projection** written by the `:bind` /
  `:unbind` action bodies (`Ezagent.Behavior.ExternalMirror.invoke/4`).
  Read at boot by `Ezagent.Behavior.ExternalMirror.init_slice/1`
  (per-session rehydration) AND by
  `Ezagent.ExternalMirror.BootReconciler` (cross-session multi-node
  reconciliation, V1 single-node no-op safety net).

  ## Cardinality

  Unique on `(session_uri, adapter_id, target_id)` — natural key for
  idempotency at the DB level. Concurrent `:bind` calls for the same
  triple collide on this constraint (`{:error, _}` from
  `Repo.insert/2`), matching the in-memory PerBindingSupervisor /
  WorkerRegistry idempotency contract (PR-EM-2 §3.1 r5 HIGH-3 fix).

  ## workspace_uri (P21)

  `workspace_uri NOT NULL` per the
  `per_tenant_tables_have_workspace_column_test.exs` invariant.
  Derived structurally from `session_uri` (3-segment shape
  `session://<template>/<workspace>/<name>` per Phase 9 PR-7) via
  `Ezagent.Persistence.workspace_uri_for!/1`.

  Cross-workspace bindings are rejected by dispatch step 5.6
  (`Kind.Runtime.workspace_isolation_check`) BEFORE reaching this
  insert site — the column is just structural metadata for
  per-tenant scoping of cross-session queries.

  ## No back-compat / no migration of feishu_session_bindings

  Allen 2026-05-24: "no migration / no back-compat" — the
  Feishu plugin's `feishu_session_bindings` table is retired in a
  later PR (PR-EM-6 — Feishu adapter rewrite). PR-EM-3 ships the
  new table empty.
  """

  use Ecto.Migration

  def change do
    create table(:external_mirror_bindings, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :adapter_id, :string, null: false
      add :target_id, :string, null: false
      add :opts_json, :string, null: false, default: "{}"
      add :bound_by, :string, null: false
      add :bound_at, :utc_datetime_usec, null: false
      add :workspace_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:external_mirror_bindings, [:session_uri, :adapter_id, :target_id],
             name: :external_mirror_bindings_natural_key_index
           )

    create index(:external_mirror_bindings, [:session_uri],
             name: :external_mirror_bindings_session_uri_index
           )

    create index(:external_mirror_bindings, [:workspace_uri],
             name: :external_mirror_bindings_workspace_uri_index
           )

    create index(:external_mirror_bindings, [:adapter_id],
             name: :external_mirror_bindings_adapter_id_index
           )
  end
end
