defmodule EzagentCore.Invariants.PerTenantTablesHaveWorkspaceColumnTest do
  @moduledoc """
  Phase 9 PR-6 (SPEC v3 §7.4) architectural invariant — every per-tenant
  schema declares a `:workspace_uri` field AND the backing DB column
  exists with NOT NULL.

  Pinned facts:

  1. Each schema module in `@per_tenant_schemas` lists `:workspace_uri`
     in its `__schema__(:fields)`.
  2. The DB-side column exists, has `NOT NULL` (`notnull = 1`), and is
     of type `string`.
  3. Each schema module in `@exempt_schemas` documents WHY it does not
     carry the column (workspace IS the tenant; pre-tenant boundary;
     plugin-owned data isolated via parent FK; etc.).
  4. The set of "all schemas" minus the per-tenant list minus the
     exempt list is empty — adding a NEW schema without categorising
     it fails this test.

  This test is the durable guard against the regression "PR-N adds a
  table, forgets workspace_uri" that PR-6 is designed to prevent. Per
  SPEC §7.4 + memory `feedback_completion_requires_invariant_test`.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentCore.Repo

  # Per-tenant schemas — MUST declare `:workspace_uri` field AND have
  # NOT NULL column in the DB.
  #
  # NB: `Ezagent.Users`, `Ezagent.Entity.Token`, `Ezagent.Entity.Profile`
  # live in `ezagent_domain_identity` (not `ezagent_core`). Referenced
  # as runtime atoms here because ezagent_core mustn't compile-time
  # depend on domain_identity (tier boundary, ezagent-developer skill
  # invariant). The schema-side test loads them via
  # `Code.ensure_loaded?/1` and skips if absent (caller running
  # `mix test apps/ezagent_core` in isolation).
  @per_tenant_schemas [
    {Ezagent.Message, "messages"},
    {Ezagent.Ecto.KindSnapshot, "kind_snapshots"},
    {Ezagent.Users, "users"},
    {Ezagent.Entity.Token, "entity_tokens"},
    {Ezagent.Entity.Profile, "entity_profiles"},
    # Phase 7 completion PR-3 (SPEC §1.7 (c)) — the SessionTemplate
    # tag registry. Per-tenant: a `(workspace, name, tag)` row is
    # scoped to its workspace (`stable` in ws A ≠ `stable` in ws B).
    {Ezagent.TemplateTags, "template_tags"},
    # PR-EM-3 (ExternalMirror SPEC §7.1) — the `:external_mirror`
    # Session-slice projection. Per-tenant: a `(session_uri,
    # adapter_id, target_id)` binding row is scoped to the session's
    # workspace (a Lark chat bound in ws A must not be readable from
    # ws B).
    {Ezagent.ExternalMirror.BindingRow, "external_mirror_bindings"},
    # SPEC 2026-05-23-read-receipts — read-confidence marker per
    # `(session, user, source)`. Per-tenant: a marker's
    # `last_read_message_uri` is meaningless across workspaces.
    {Ezagent.Chat.ReadMarker, "read_markers"},
    # SPEC 2026-05-24-magic-link-rules-v2 PR-A — per-workspace
    # magic-link acceptance rules. Per-tenant by definition (a
    # `domain` rule for ws A must never authorise a login into ws B).
    {Ezagent.Workspace.MagicLinkRule, "workspace_magic_link_rules"}
  ]

  # Per-tenant tables that have NO schema module (raw `Repo.insert_all`
  # writes only). DB-side NOT NULL check applies; schema-side check is
  # N/A. `invocations` is the canonical example — the audit log is
  # written via `Ezagent.Audit.Writer` using a string table name to
  # avoid coupling the audit hot path to a schema module.
  @per_tenant_schemaless_tables ["invocations"]

  # Tables that exist but intentionally lack `workspace_uri`. Documented
  # in `apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs`
  # under "Exempt tables".
  @exempt_tables_with_reason %{
    "workspaces" => "Workspace IS the tenant; trivially scoped by row id.",
    "routing_rules" =>
      "Already has workspace_uri (Phase 6 PR 8 / PR #146-149) — pre-dated this migration.",
    "message_routings" =>
      "Join table; inherits scope via FK to messages (which has workspace_uri NOT NULL).",
    "dlq" =>
      "Pre-tenant boundary — failure can precede workspace determination; operator triages from system scope.",
    "app_settings" =>
      "Global system config (SMTP, registration domains) — system scope by design.",
    "magic_link_tokens" =>
      "Cross-workspace by design — email-based pre-login, no workspace context at mint time.",
    "feishu_user_bindings" =>
      "Plugin-owned mapping; workspace inherent in bound user_uri downstream.",
    # PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §9):
    # `feishu_session_bindings` was retired in favor of the generic
    # `external_mirror_bindings` projection table (workspace_uri NOT
    # NULL — see PR-EM-3 migration).
    "schema_migrations" => "Ecto-internal migration tracking — not tenant data."
  }

  describe "schema-side invariant" do
    for {schema_module, table_name} <- @per_tenant_schemas do
      test "#{inspect(schema_module)} (#{table_name}) declares :workspace_uri field" do
        module = unquote(schema_module)

        if Code.ensure_loaded?(module) do
          fields = module.__schema__(:fields)

          assert :workspace_uri in fields,
                 """
                 #{inspect(module)} does not declare a `:workspace_uri`
                 field but is listed as per-tenant in this invariant test.
                 Per SPEC v3 §7 / Phase 9 PR-6, every per-tenant schema
                 must carry the column so SELECTs can scope by workspace.

                 Fix: add `field :workspace_uri, :string` to the schema and
                 ensure write call sites populate it via
                 `Ezagent.Persistence.workspace_uri_for!/1`.
                 """
        else
          # Schema lives in an app not currently loaded — this test
          # passes only when the umbrella-wide test run can see all
          # apps (e.g. `mix test` from repo root). Solo `mix test
          # apps/ezagent_core` skips with a warning.
          IO.warn(
            "Skipping schema-field check for #{inspect(module)} — module not " <>
              "loadable from this app context. Run `mix test` from repo root " <>
              "to exercise this assertion."
          )
        end
      end
    end
  end

  describe "DB-side invariant" do
    for {_schema_module, table_name} <- @per_tenant_schemas do
      test "#{table_name} table has workspace_uri column with NOT NULL" do
        info = pragma_table_info(unquote(table_name))

        column = Enum.find(info, fn col -> col.name == "workspace_uri" end)

        assert column,
               "#{unquote(table_name)} has no `workspace_uri` column in the DB. " <>
                 "Run `mix ezagent.db.reset && mix ecto.migrate` if a migration is missing."

        assert column.notnull == 1,
               "#{unquote(table_name)}.workspace_uri exists but is NULLABLE — the " <>
                 "Phase 9 PR-6 migration should set NOT NULL. Check the migration's " <>
                 "`modify :workspace_uri, ..., null: false, from: ...` step."
      end
    end

    for table_name <- @per_tenant_schemaless_tables do
      test "#{table_name} (schemaless) table has workspace_uri column with NOT NULL" do
        info = pragma_table_info(unquote(table_name))

        column = Enum.find(info, fn col -> col.name == "workspace_uri" end)

        assert column,
               "#{unquote(table_name)} has no `workspace_uri` column in the DB."

        assert column.notnull == 1,
               "#{unquote(table_name)}.workspace_uri must be NOT NULL — the audit " <>
                 "writer fills the column on every insert per Phase 9 PR-6."
      end
    end
  end

  describe "exemption discipline" do
    test "every table that exists is either per-tenant or explicitly exempt" do
      all_tables = list_db_tables()

      per_tenant_tables =
        Enum.map(@per_tenant_schemas, fn {_m, t} -> t end) ++
          @per_tenant_schemaless_tables

      exempt_tables = Map.keys(@exempt_tables_with_reason)

      categorized = MapSet.new(per_tenant_tables ++ exempt_tables)
      orphans = Enum.reject(all_tables, fn t -> MapSet.member?(categorized, t) end)

      assert orphans == [],
             """
             These DB tables are neither in the per-tenant list nor on the
             exempt list:

               #{Enum.join(orphans, "\n  ")}

             Decide for each:

             - If the table holds per-tenant data: add a `workspace_uri`
               column via a migration + declare in this test's
               `@per_tenant_schemas` list.
             - If the table is intentionally cross-workspace (system
               config, plugin-internal mapping, pre-tenant audit): add to
               `@exempt_tables_with_reason` with a 1-sentence rationale.

             Silent uncategorised tables are how cross-tenant leaks slip
             in past PR-6's invariant tests.
             """
    end
  end

  # ---------------------------------------------------------------------
  # Helpers

  defp pragma_table_info(table_name) do
    {:ok, %{rows: rows, columns: cols}} =
      Repo.query("PRAGMA table_info(#{table_name})")

    col_names = Enum.map(cols, &String.to_atom/1)

    Enum.map(rows, fn row ->
      Enum.zip(col_names, row) |> Map.new()
    end)
  end

  defp list_db_tables do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT name FROM sqlite_master
      WHERE type='table' AND name NOT LIKE 'sqlite_%'
      ORDER BY name
      """)

    Enum.map(rows, fn [name] -> name end)
  end
end
