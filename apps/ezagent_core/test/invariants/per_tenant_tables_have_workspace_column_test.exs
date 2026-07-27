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

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

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
    {Ezagent.Session.MessageSequence, "session_message_sequences"},
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
    # #17 credential/config cascade — grants are scoped to the
    # workspace of the agent being provisioned; a grant for ws A must
    # never be queried or reused from ws B.
    {Ezagent.Credential.GrantRow, "credential_grants"},
    # task #87 — invite codes carry their authoritative target workspace.
    # Per-tenant: a code for ws A admits a registrant to ws A only; admin
    # cross-workspace listing is the documented exception (like Users.list_all).
    {Ezagent.Entity.InviteCode, "invite_codes"},
    # #17 credential/config cascade — a user's default source is keyed
    # by (owner, workspace, flavor), so the pointer is per-tenant.
    {Ezagent.Credential.UserDefaultSource, "user_default_credential_sources"},
    # #17 credential/config cascade PR-3 — a workspace-shared source is keyed
    # by (workspace, flavor), so the pointer is per-tenant.
    {Ezagent.Credential.WorkspaceSharedSource, "workspace_shared_credential_sources"},
    # SPEC 2026-05-23-read-receipts — read-confidence marker per
    # `(session, user, source)`. Per-tenant: a marker's
    # `last_read_message_uri` is meaningless across workspaces.
    {Ezagent.Session.ReadMarker, "read_markers"},
    # SPEC 2026-05-24-magic-link-rules-v2 PR-A — per-workspace
    # magic-link acceptance rules. Per-tenant by definition (a
    # `domain` rule for ws A must never authorise a login into ws B).
    {Ezagent.Workspace.MagicLinkRule, "workspace_magic_link_rules"},
    # Socialware P3 — committed settlement rows gate the external customer
    # projection per workspace; no row is cross-tenant.
    {Ezagent.Socialware.SettlementRecord, "socialware_settlements"},
    {Ezagent.Socialware.SettlementMessage, "socialware_settlement_messages"},
    {Ezagent.Socialware.DeliveryOutbox, "socialware_delivery_outbox"},
    # Socialware P6 — immutable self-evolve config objects and mutable
    # pointers are scoped by workspace; a config object for ws A must never
    # be resolved from ws B.
    {Ezagent.Socialware.ConfigObject, "socialware_config_objects"},
    {Ezagent.Socialware.ConfigPointer, "socialware_config_pointers"},
    # CR (change-request) config governance (SPEC 2026-06-26 rev 3) — both
    # carry workspace_uri NOT NULL (invariant #14).
    {Ezagent.Socialware.ConfigChangeRequest, "socialware_config_change_requests"},
    {Ezagent.Socialware.ConfigChangeItem, "socialware_config_change_items"},
    # #82/#896 protocol_api — an inbound API key authorizes an external caller to
    # reach a specific agent in a specific workspace (`workspace_uri` NOT NULL).
    # Per-tenant by definition: a key minted for ws A must never grant access to
    # ws B. Same bearer-credential shape as `entity_tokens` (looked up globally by
    # the opaque key, but carries + enforces its own workspace scope).
    {Ezagent.ProtocolApi.ApiKeyStore, "protocol_api_keys"},
    # Issue #51 — the anon external-user binding maps an anon-User to the public
    # session it views; the workspace is DERIVED from that session (never supplied),
    # so a binding can never span tenants.
    {Ezagent.Socialware.AnonBinding, "socialware_anon_bindings"},
    # Phase 3 S5 — pre-issued recipe artifacts are keyed to one concrete agent;
    # the binding must stay inside that agent's workspace boundary.
    {Ezagent.Identity.RecipeCapBinding, "recipe_cap_bindings"},
    # Entity-caps scoped Task B — the outbound audit/revoke ledger is tenant-owned
    # by the grantee workspace, even when the accountable issuer is cross-workspace.
    {Ezagent.OutboundGrant, "outbound_grants"},
    {Ezagent.Agent.CreationInventoryEntry, "agent_creation_inventory"},
    {Ezagent.Agent.RetirementObligation, "agent_retirement_obligations"},
    # Socialware composition-cap lane — every derivation row is scoped to the
    # concrete source/target workspace and is union-reconciled only within it.
    {Ezagent.Socialware.CompositionBinding, "socialware_composition_bindings"},
    {Ezagent.Socialware.CompositionConsent, "socialware_composition_consents"},
    {Ezagent.Socialware.CompositionConsentCommand, "socialware_composition_consent_commands"},
    # Socialware P9 — named workspace responsibility assignments are scoped to
    # one workspace; the same holder URI cannot receive a responsibility across
    # tenants without a separate row in that tenant.
    {Ezagent.Workspace.ResponsibilityAssignment, "workspace_responsibility_assignments"},
    # #88 PR-1 — durable RFC 5322 threading state for the email
    # ExternalMirror Binding, keyed by the binding row id. Per-tenant:
    # the thread (root/last Message-ID + References chain) is scoped to
    # the bound session's workspace; a thread for ws A must never be read
    # from ws B. Derived structurally from the session at write time.
    {Ezagent.Email.ThreadState, "email_thread_state"},
    # #88 PR-2 — email-owned per-binding inbound metadata (local alias +
    # verification status + binding-scoped token), keyed by the binding row
    # id. Per-tenant: the alias→session reverse lookup and the verification
    # gate are scoped to the bound session's workspace; a row for ws A must
    # never be read from ws B. Derived structurally from the session.
    {Ezagent.Email.InboundBinding, "email_inbound_binding"},
    # Orchestration-as-socialware M1 — routing trace rows record the message
    # journey for operator debugging. A message belongs to one workspace, so
    # trace rows carry the same workspace partition.
    {Ezagent.Routing.Trace, "routing_traces"},
    # Entity capability grant/revoke delivery is scoped to the grantee's
    # workspace. The singleton sweeper is the documented system-scope reader.
    {Ezagent.Cap.Delivery, "cap_delivery_outbox"},
    # Git task workspace lifecycle rows contain canonical checkout and Agent
    # retirement coordinates for exactly one workspace generation.
    {Ezagent.Workspace.TaskWorkspace.Provision, "git_task_workspace_provisions"},
    {Ezagent.ProviderConnection.Connection, "provider_connections"},
    {Ezagent.ProviderConnection.AuthorizationAttempt, "provider_authorization_attempts"},
    {Ezagent.ProviderConnection.Operation, "provider_connection_operations"},
    {Ezagent.ProviderConnection.Event, "provider_connection_events"},
    {Ezagent.ProviderConnection.AuthorizationBackendRecord,
     "provider_authorization_backend_records"},
    {Ezagent.ProviderConnection.ProviderAuthorizationCommand, "provider_authorization_commands"}
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
    "derivation_edges" =>
      "Global append-only provenance keyed by canonical URIs; creation and transfer edges may intentionally cross workspace boundaries.",
    "identity_reap_queue" =>
      "System cleanup worklist keyed by canonical principal URI; retries must survive ownership and workspace transfer.",
    "revocation_fences" =>
      "System authority-use fence keyed by canonical principal URI; one offboarding cascade may span workspaces.",
    "kind_cap_authorities" =>
      "Framework authority rows are globally keyed by canonical Kind URI; the URI itself carries tenant identity and the admin anchor is system-scoped.",
    "workspaces" => "Workspace IS the tenant; trivially scoped by row id.",
    "routing_rules" =>
      "Already has workspace_uri (Phase 6 PR 8 / PR #146-149) — pre-dated this migration.",
    "routing_traces" =>
      "Runtime routing trace table; already carries workspace_uri NOT NULL and has no schema module.",
    "dlq" =>
      "Pre-tenant boundary — failure can precede workspace determination; operator triages from system scope.",
    "app_settings" =>
      "Global system config (SMTP, registration domains) — system scope by design.",
    "magic_link_tokens" =>
      "Cross-workspace by design — email-based pre-login, no workspace context at mint time.",
    "feishu_user_bindings" =>
      "Plugin-owned mapping; workspace inherent in bound user_uri downstream.",
    # Remediation C-B (#114): durable backing for the `Ezagent.AgentLineage`
    # ETS read-cache. A global lineage index keyed by `agent_uri` (the
    # child URI is itself workspace-qualified); the `(agent_uri →
    # spawned_by)` mapping is NOT workspace-scoped — a spawn lineage may
    # legitimately cross workspaces, and CapBAC `{:spawned_by, P}` matching
    # resolves by agent_uri, not by workspace. SQLite is the rebuild source
    # for `AgentLineage.rehydrate/0` at boot.
    "agent_lineage" =>
      "Global lineage cache keyed by agent_uri (not workspace-scoped); rebuild source for the AgentLineage ETS index.",
    # PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §9):
    # `feishu_session_bindings` was retired in favor of the generic
    # `external_mirror_bindings` projection table (workspace_uri NOT
    # NULL — see PR-EM-3 migration).
    "schema_migrations" => "Ecto-internal migration tracking — not tenant data.",
    "registration_requests" =>
      "Pre-tenant registration intake — a row is created before any workspace exists (the requester has no workspace yet); triaged from system scope."
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
        info = table_columns(unquote(table_name))

        column = Enum.find(info, fn col -> col.name == "workspace_uri" end)

        assert column,
               "#{unquote(table_name)} has no `workspace_uri` column in the DB. " <>
                 "Run `mix ezagent.db.reset && mix ecto.migrate` if a migration is missing."

        assert column.notnull,
               "#{unquote(table_name)}.workspace_uri exists but is NULLABLE — the " <>
                 "Phase 9 PR-6 migration should set NOT NULL. Check the migration's " <>
                 "`modify :workspace_uri, ..., null: false, from: ...` step."
      end
    end

    for table_name <- @per_tenant_schemaless_tables do
      test "#{table_name} (schemaless) table has workspace_uri column with NOT NULL" do
        info = table_columns(unquote(table_name))

        column = Enum.find(info, fn col -> col.name == "workspace_uri" end)

        assert column,
               "#{unquote(table_name)} has no `workspace_uri` column in the DB."

        assert column.notnull,
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

  defp table_columns(table_name) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT column_name, is_nullable, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY ordinal_position
        """,
        [table_name]
      )

    Enum.map(rows, fn [name, nullable, data_type] ->
      %{name: name, notnull: nullable == "NO", type: data_type}
    end)
  end

  defp list_db_tables do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)

    Enum.map(rows, fn [name] -> name end)
  end
end
