Code.require_file("../../support/migration_test_repo.exs", __DIR__)

defmodule Ezagent.ProviderConnection.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.MigrationTestRepo

  @historical [
    {20_260_718_000_000, "20260718000000_create_provider_connections.exs",
     EzagentCore.Repo.Migrations.CreateProviderConnections},
    {20_260_719_000_000, "20260719000000_fence_provider_callback_operations.exs",
     EzagentCore.Repo.Migrations.FenceProviderCallbackOperations},
    {20_260_719_001_000, "20260719001000_close_provider_callback_operations.exs",
     EzagentCore.Repo.Migrations.CloseProviderCallbackOperations},
    {20_260_719_002_000, "20260719002000_bind_provider_execution_identity.exs",
     EzagentCore.Repo.Migrations.BindProviderExecutionIdentity},
    {20_260_720_000_000, "20260720000000_harden_provider_task8_fences.exs",
     EzagentCore.Repo.Migrations.HardenProviderTask8Fences}
  ]

  @amendment [
    {20_260_720_001_000, "20260720001000_reserve_pending_provider_connections.exs",
     EzagentCore.Repo.Migrations.ReservePendingProviderConnections},
    {20_260_720_002_000, "20260720002000_close_provider_binding_cas.exs",
     EzagentCore.Repo.Migrations.CloseProviderBindingCas},
    {20_260_720_003_000, "20260720003000_add_provider_recovery_schedule.exs",
     EzagentCore.Repo.Migrations.AddProviderRecoverySchedule},
    {20_260_720_004_000, "20260720004000_add_refresh_compensation_obligations.exs",
     EzagentCore.Repo.Migrations.AddRefreshCompensationObligations}
  ]

  @supplement [
    {20_260_720_005_000, "20260720005000_close_provider_result_ownership_stages.exs",
     EzagentCore.Repo.Migrations.CloseProviderResultOwnershipStages}
  ]

  test "non-empty D1 rows upgrade through the explicit expand backfill validate sequence" do
    database = "provider_migration_#{System.unique_integer([:positive])}"
    admin_opts = connection_options("postgres")
    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])

    repo_config =
      connection_options(database) ++
        [pool_size: 2, migration_lock: nil, priv: "priv/repo_pg"]

    previous = Application.get_env(:ezagent_domain_provider_connection, MigrationTestRepo)
    Application.put_env(:ezagent_domain_provider_connection, MigrationTestRepo, repo_config)
    {:ok, _repo_pid} = MigrationTestRepo.start_link()

    on_exit(fn ->
      {:ok, cleanup_admin} = Postgrex.start_link(admin_opts)

      Postgrex.query!(
        cleanup_admin,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
        [database]
      )

      Postgrex.query!(cleanup_admin, ~s(DROP DATABASE "#{database}"), [])

      if previous,
        do: Application.put_env(:ezagent_domain_provider_connection, MigrationTestRepo, previous),
        else: Application.delete_env(:ezagent_domain_provider_connection, MigrationTestRepo)
    end)

    migrate(@historical)
    seed_pre_amendment_rows!()
    migrate(@amendment)
    seed_pre_supplement_rows!()
    migrate(@supplement)

    assert scalar!("""
           WITH expected(connection_id, status) AS (
             VALUES
               ('00000000-0000-0000-0000-000000000001'::uuid, 'active'),
               ('00000000-0000-0000-0000-000000000002'::uuid, 'pending_authorization'),
               ('00000000-0000-0000-0000-000000000003'::uuid, 'active'),
               ('00000000-0000-0000-0000-000000000004'::uuid, 'active'),
               ('00000000-0000-0000-0000-000000000005'::uuid, 'active'),
               ('00000000-0000-0000-0000-000000000006'::uuid, 'refreshing'),
               ('00000000-0000-0000-0000-000000000007'::uuid, 'revoking')
           )
           SELECT count(*)
             FROM expected
             JOIN provider_connections USING (connection_id, status)
           """) == 7

    assert scalar!("""
           SELECT count(*) FROM provider_connections
            WHERE connection_id = '00000000-0000-0000-0000-000000000002'
              AND status = 'pending_authorization'
              AND requested_execution_identity_class = 'connected_user'
              AND external_account_id IS NULL
              AND execution_identity IS NULL
              AND authorization_backend_ref IS NULL
              AND credential_backend_ref IS NULL
           """) == 1

    assert scalar!("""
           SELECT count(*) FROM provider_authorization_attempts
            WHERE attempt_ref = '20000000-0000-0000-0000-000000000002'
              AND purpose = 'initial_bind' AND status = 'pending'
              AND reservation_digest = 'state-pending'
              AND requested_permission_digest = 'perm-requested'
              AND callback_artifact_digest = 'subject-pending'
           """) == 1

    assert scalar!("""
           SELECT count(*) FROM provider_authorization_attempts
            WHERE attempt_ref = '20000000-0000-0000-0000-000000000003'
              AND purpose = 'legacy' AND status = 'cancelled'
              AND reservation_digest IS NULL
           """) == 1

    assert scalar!("""
           SELECT count(*) FROM provider_connection_operations
            WHERE recovery_attempts = 0
              AND status IN ('prepared','backend_committed','cleanup_pending')
              AND next_recovery_at IS NOT NULL
           """) == 8

    assert scalar!("""
           WITH expected(id, operation_class, status, provider_result_ref) AS (
             VALUES
               ('30000000-0000-0000-0000-000000000004'::uuid, 'store', 'backend_committed', 'handoff-backend'),
               ('30000000-0000-0000-0000-000000000005'::uuid, 'revoke', 'cleanup_pending', NULL),
               ('30000000-0000-0000-0000-000000000006'::uuid, 'refresh', 'prepared', NULL),
               ('30000000-0000-0000-0000-000000000007'::uuid, 'revoke', 'backend_committed', NULL)
           )
           SELECT count(*)
             FROM expected
             JOIN provider_connection_operations AS operation
               ON operation.id = expected.id
              AND operation.operation_class = expected.operation_class
              AND operation.status = expected.status
              AND operation.provider_result_ref IS NOT DISTINCT FROM expected.provider_result_ref
            WHERE operation.recovery_attempts = 0
              AND operation.next_recovery_at IS NOT NULL
           """) == 4

    assert scalar!("""
           SELECT count(*) FROM provider_connection_operations
            WHERE id = '30000000-0000-0000-0000-000000000005'
              AND provider_cleanup_status = 'not_required'
              AND credential_cleanup_status = 'pending'
           """) == 1

    assert scalar!("""
           SELECT count(*) FROM pg_constraint
            WHERE conname IN (
              'provider_authorization_attempts_connection_workspace_fkey',
              'provider_connection_operations_connection_workspace_fkey',
              'provider_connection_events_connection_workspace_fkey'
            ) AND convalidated
           """) == 3

    assert scalar!("""
           SELECT count(*)
             FROM information_schema.columns
            WHERE table_name = 'provider_connection_operations'
              AND column_name IN ('expected_authorization_ref', 'expected_authorization_version')
           """) == 2

    assert scalar!("""
           SELECT count(*)
             FROM pg_constraint
            WHERE conname IN (
              'provider_connection_operations_expected_authorization_check',
              'provider_connection_operations_ownership_stage_check'
            ) AND convalidated
           """) == 2

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id = 'op-advanced-callback'
              AND expected_authorization_ref = 'auth-advanced-callback'
              AND expected_authorization_version = 0
              AND result_permission_digest = 'perm'
           """) == 1

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id IN ('op-active-refresh', 'op-finished-refresh')
              AND expected_authorization_ref = CASE correlation_id
                    WHEN 'op-active-refresh' THEN 'auth-active-refresh'
                    ELSE 'auth-finished-refresh'
                  END
              AND expected_authorization_version = 1
           """) == 2

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id = 'op-fenced-callback'
              AND status = 'fenced'
              AND expected_authorization_ref = 'auth-fenced-callback'
              AND expected_authorization_version = 1
              AND provider_result_ref IS NULL
              AND result_ref IS NULL
           """) == 1

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id = 'op-terminal-reauth'
              AND operation_class = 'replace'
              AND status = 'fenced'
              AND expected_authorization_ref = 'auth-new-terminal-reauth'
              AND expected_authorization_version = 7
              AND provider_result_ref IS NULL
              AND result_ref IS NULL
           """) == 1

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id IN (
              'op-provider-owned-callback',
              'op-provider-owned-refresh'
            )
              AND status = 'prepared'
              AND provider_result_ref IS NOT NULL
              AND result_ref IS NULL
           """) == 2

    assert scalar!("""
           SELECT count(*)
             FROM provider_connection_operations
            WHERE correlation_id = 'op-credential-owned-refresh'
              AND status = 'backend_committed'
              AND provider_result_ref IS NOT NULL
              AND result_ref IS NOT NULL
              AND result_credential_version IS NOT NULL
           """) == 1
  end

  test "supplement fails loud when a terminal-advanced refresh cannot prove its reservation authorization" do
    database = "provider_migration_ambiguous_#{System.unique_integer([:positive])}"
    admin_opts = connection_options("postgres")
    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])

    repo_config =
      connection_options(database) ++
        [pool_size: 2, migration_lock: nil, priv: "priv/repo_pg"]

    previous = Application.get_env(:ezagent_domain_provider_connection, MigrationTestRepo)
    Application.put_env(:ezagent_domain_provider_connection, MigrationTestRepo, repo_config)
    {:ok, _repo_pid} = MigrationTestRepo.start_link()

    on_exit(fn ->
      {:ok, cleanup_admin} = Postgrex.start_link(admin_opts)

      Postgrex.query!(
        cleanup_admin,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
        [database]
      )

      Postgrex.query!(cleanup_admin, ~s(DROP DATABASE "#{database}"), [])

      if previous,
        do: Application.put_env(:ezagent_domain_provider_connection, MigrationTestRepo, previous),
        else: Application.delete_env(:ezagent_domain_provider_connection, MigrationTestRepo)
    end)

    migrate(@historical)

    insert_connection!(
      "00000000-0000-0000-0000-000000000012",
      "active",
      "ambiguous-refresh"
    )

    migrate(@amendment)

    query!(
      """
      UPDATE provider_connections
         SET connection_version = 10
       WHERE connection_id = '00000000-0000-0000-0000-000000000012'::uuid
      """,
      []
    )

    callback_complete = %{
      connection_id: "00000000-0000-0000-0000-000000000012",
      operation_class: "replace",
      expected_connection_version: 10,
      status: "prepared",
      provider_result_ref: "provider-result",
      handoff_ref: "handoff-result",
      result_external_account_id: "acct-ambiguous-refresh",
      result_display_login: "ambiguous-refresh",
      result_execution_identity: "connected_user",
      result_authorization_ref: "auth-ambiguous-refresh",
      result_authorization_version: 1,
      result_permission_digest: "perm"
    }

    refresh_complete = %{
      connection_id: "00000000-0000-0000-0000-000000000012",
      operation_class: "refresh",
      expected_connection_version: 10,
      status: "prepared",
      provider_result_ref: "provider-result",
      handoff_ref: "handoff-result",
      result_permission_digest: "perm"
    }

    callback_partials =
      for field <- [
            :provider_result_ref,
            :handoff_ref,
            :result_external_account_id,
            :result_display_login,
            :result_execution_identity,
            :result_authorization_ref,
            :result_authorization_version,
            :result_permission_digest
          ] do
        {Map.delete(callback_complete, field), "partial callback provider ownership tuple"}
      end

    refresh_partials =
      for field <- [:provider_result_ref, :handoff_ref, :result_permission_digest] do
        {Map.delete(refresh_complete, field), "partial refresh provider ownership tuple"}
      end ++
        for field <- [
              :result_external_account_id,
              :result_display_login,
              :result_execution_identity,
              :result_authorization_ref,
              :result_authorization_version
            ] do
          value = if field == :result_authorization_version, do: 99, else: "forbidden"

          {Map.put(refresh_complete, field, value), "partial refresh provider ownership tuple"}
        end

    credential_partials = [
      {Map.put(refresh_complete, :result_ref, "orphan-credential"),
       "partial credential ownership tuple"},
      {Map.put(refresh_complete, :result_credential_version, 2),
       "partial credential ownership tuple"}
    ]

    fenced_ownership =
      {Map.put(refresh_complete, :status, "fenced"),
       "fenced operation carries external ownership"}

    partials =
      (callback_partials ++ refresh_partials ++ credential_partials ++ [fenced_ownership])
      |> Enum.with_index(20)
      |> Enum.map(fn {{attrs, expected_error}, index} ->
        id = "30000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(index), 12, "0")}"

        {Map.merge(attrs, %{id: id, correlation_id: "partial-#{index}"}), expected_error}
      end)

    for {attrs, expected_error} <- partials do
      insert_pre_supplement_operation!(attrs)
      error = assert_raise Postgrex.Error, fn -> migrate(@supplement) end
      assert error.postgres.code == :check_violation

      assert Exception.message(error) =~ expected_error,
             "unexpected classifier for #{inspect(attrs)}: #{Exception.message(error)}"

      query!("DELETE FROM provider_connection_operations WHERE id = $1", [
        Ecto.UUID.dump!(attrs.id)
      ])
    end

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000012",
      connection_id: "00000000-0000-0000-0000-000000000012",
      operation_class: "refresh",
      correlation_id: "op-ambiguous-refresh",
      expected_connection_version: 10,
      status: "backend_committed",
      provider_result_ref: "provider-ambiguous-refresh",
      handoff_ref: "handoff-ambiguous-refresh",
      result_permission_digest: "perm-ambiguous-refresh",
      result_ref: "result-ambiguous-refresh",
      result_credential_version: 2
    })

    query!(
      """
      UPDATE provider_connection_operations
         SET status = 'cleanup_pending', provider_cleanup_status = 'pending'
       WHERE correlation_id = 'op-ambiguous-refresh'
      """,
      []
    )

    query!(
      """
      UPDATE provider_connections
         SET status = 'revoked', connection_version = 14
       WHERE connection_id = '00000000-0000-0000-0000-000000000012'::uuid
      """,
      []
    )

    error = assert_raise Postgrex.Error, fn -> migrate(@supplement) end
    assert error.postgres.code == :check_violation
    assert Exception.message(error) =~ "ambiguous operation authorization reservation"
  end

  defp migrate(migrations) do
    migration_dir = Application.app_dir(:ezagent_core, "priv/repo_pg/migrations")

    Enum.each(migrations, fn {version, filename, module} ->
      Code.require_file(Path.join(migration_dir, filename))
      assert :ok = Ecto.Migrator.up(MigrationTestRepo, version, module, log: false)
    end)
  end

  defp seed_pre_amendment_rows! do
    Enum.each(
      [
        {"00000000-0000-0000-0000-000000000001", "active", "active"},
        {"00000000-0000-0000-0000-000000000002", "pending_authorization", "pending"},
        {"00000000-0000-0000-0000-000000000003", "active", "consuming"},
        {"00000000-0000-0000-0000-000000000004", "active", "backend"},
        {"00000000-0000-0000-0000-000000000005", "active", "cleanup"},
        {"00000000-0000-0000-0000-000000000006", "refreshing", "refreshing"},
        {"00000000-0000-0000-0000-000000000007", "revoking", "termination"}
      ],
      fn {id, status, suffix} -> insert_connection!(id, status, suffix) end
    )

    insert_backend_record!(
      "10000000-0000-0000-0000-000000000002",
      "attempt-auth-pending",
      "00000000-0000-0000-0000-000000000002",
      0,
      "pending"
    )

    insert_backend_record!(
      "10000000-0000-0000-0000-000000000003",
      "attempt-auth-consuming",
      "00000000-0000-0000-0000-000000000003",
      2,
      "consuming"
    )

    insert_attempt!(
      "20000000-0000-0000-0000-000000000002",
      "attempt-auth-pending",
      "00000000-0000-0000-0000-000000000002",
      0,
      "pending"
    )

    insert_attempt!(
      "20000000-0000-0000-0000-000000000003",
      "attempt-auth-consuming",
      "00000000-0000-0000-0000-000000000003",
      2,
      "consuming"
    )

    insert_attempt!(
      "20000000-0000-0000-0000-000000000004",
      "auth-backend",
      "00000000-0000-0000-0000-000000000004",
      7,
      "consumed"
    )

    insert_operation!("00000000-0000-0000-0000-000000000004", "backend_committed", "backend")
    insert_operation!("00000000-0000-0000-0000-000000000005", "cleanup_pending", "cleanup")
    insert_operation!("00000000-0000-0000-0000-000000000006", "prepared", "refreshing")
    insert_operation!("00000000-0000-0000-0000-000000000007", "backend_committed", "termination")
  end

  defp seed_pre_supplement_rows! do
    query!(
      """
      UPDATE provider_connection_operations
         SET result_permission_digest = 'perm',
             result_authorization_version = 1
       WHERE correlation_id = 'op-backend'
      """,
      []
    )

    query!(
      """
      UPDATE provider_connections
         SET authorization_version = 0
       WHERE connection_id = '00000000-0000-0000-0000-000000000004'::uuid
      """,
      []
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000008",
      "active",
      "advanced-callback"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000009",
      "refreshing",
      "active-refresh"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000010",
      "active",
      "finished-refresh"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000011",
      "active",
      "fenced-callback"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000013",
      "active",
      "provider-owned-callback"
    )

    query!(
      """
      UPDATE provider_connections
         SET authorization_version = 0
       WHERE connection_id = '00000000-0000-0000-0000-000000000013'::uuid
      """,
      []
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000014",
      "refreshing",
      "provider-owned-refresh"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000015",
      "refreshing",
      "credential-owned-refresh"
    )

    insert_connection!(
      "00000000-0000-0000-0000-000000000016",
      "active",
      "terminal-reauth-old"
    )

    query!(
      """
      UPDATE provider_connections
         SET authorization_backend_ref = 'auth-old-terminal-reauth',
             authorization_version = 7,
             connection_version = 22,
             status = 'revoked'
       WHERE connection_id = '00000000-0000-0000-0000-000000000016'::uuid
      """,
      []
    )

    query!(
      """
      UPDATE provider_connections
         SET connection_version = CASE connection_id
               WHEN '00000000-0000-0000-0000-000000000008'::uuid THEN 8
               WHEN '00000000-0000-0000-0000-000000000009'::uuid THEN 11
             WHEN '00000000-0000-0000-0000-000000000010'::uuid THEN 12
             WHEN '00000000-0000-0000-0000-000000000011'::uuid THEN 20
             END
       WHERE connection_id IN (
         '00000000-0000-0000-0000-000000000008'::uuid,
         '00000000-0000-0000-0000-000000000009'::uuid,
         '00000000-0000-0000-0000-000000000010'::uuid
         ,'00000000-0000-0000-0000-000000000011'::uuid
       )
      """,
      []
    )

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000008",
      connection_id: "00000000-0000-0000-0000-000000000008",
      operation_class: "replace",
      correlation_id: "op-advanced-callback",
      expected_connection_version: 7,
      status: "finalized",
      provider_result_ref: "provider-advanced-callback",
      handoff_ref: "handoff-advanced-callback",
      result_external_account_id: "acct-advanced-callback",
      result_display_login: "advanced-callback",
      result_execution_identity: "connected_user",
      result_authorization_ref: "auth-advanced-callback",
      result_authorization_version: 1,
      result_ref: "result-advanced-callback",
      result_credential_version: 2
    })

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000009",
      connection_id: "00000000-0000-0000-0000-000000000009",
      operation_class: "refresh",
      correlation_id: "op-active-refresh",
      expected_connection_version: 10,
      status: "prepared"
    })

    insert_pre_supplement_attempt!(
      "20000000-0000-0000-0000-000000000013",
      "00000000-0000-0000-0000-000000000013",
      "auth-provider-owned-callback",
      String.length("provider-owned-callback")
    )

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000013",
      connection_id: "00000000-0000-0000-0000-000000000013",
      attempt_ref: "20000000-0000-0000-0000-000000000013",
      operation_class: "store",
      correlation_id: "op-provider-owned-callback",
      expected_connection_version: String.length("provider-owned-callback"),
      status: "prepared",
      provider_result_ref: "provider-owned-callback",
      handoff_ref: "handoff-owned-callback",
      result_external_account_id: "acct-provider-owned-callback",
      result_display_login: "provider-owned-callback",
      result_execution_identity: "connected_user",
      result_authorization_ref: "auth-provider-owned-callback",
      result_authorization_version: 1,
      result_permission_digest: "perm-provider-owned-callback",
      prior_credential_ref: "cred-provider-owned-callback",
      prior_credential_version: 1,
      attempt_version: 1,
      attempt_claim_token: "claim-provider-owned-callback"
    })

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000014",
      connection_id: "00000000-0000-0000-0000-000000000014",
      operation_class: "refresh",
      correlation_id: "op-provider-owned-refresh",
      expected_connection_version: String.length("provider-owned-refresh"),
      status: "prepared",
      provider_result_ref: "provider-owned-refresh",
      handoff_ref: "handoff-owned-refresh",
      result_permission_digest: "perm-provider-owned-refresh"
    })

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000015",
      connection_id: "00000000-0000-0000-0000-000000000015",
      operation_class: "refresh",
      correlation_id: "op-credential-owned-refresh",
      expected_connection_version: String.length("credential-owned-refresh"),
      status: "backend_committed",
      provider_result_ref: "provider-credential-owned-refresh",
      handoff_ref: "handoff-credential-owned-refresh",
      result_permission_digest: "perm-credential-owned-refresh",
      result_ref: "credential-owned-refresh",
      result_credential_version: 2
    })

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000010",
      connection_id: "00000000-0000-0000-0000-000000000010",
      operation_class: "refresh",
      correlation_id: "op-finished-refresh",
      expected_connection_version: 10,
      status: "finalized",
      provider_result_ref: "provider-finished-refresh",
      handoff_ref: "handoff-finished-refresh",
      result_permission_digest: "perm-finished-refresh",
      result_ref: "result-finished-refresh",
      result_credential_version: 2
    })

    insert_pre_supplement_attempt!(
      "20000000-0000-0000-0000-000000000011",
      "00000000-0000-0000-0000-000000000011",
      "auth-fenced-callback",
      20
    )

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000011",
      connection_id: "00000000-0000-0000-0000-000000000011",
      attempt_ref: "20000000-0000-0000-0000-000000000011",
      operation_class: "store",
      correlation_id: "op-fenced-callback",
      expected_connection_version: 20,
      attempt_version: 1,
      attempt_claim_token: "claim-fenced-callback",
      prior_credential_ref: "cred-fenced-callback",
      prior_credential_version: 1,
      status: "prepared"
    })

    insert_pre_supplement_attempt!(
      "20000000-0000-0000-0000-000000000016",
      "00000000-0000-0000-0000-000000000016",
      "auth-new-terminal-reauth",
      20
    )

    insert_pre_supplement_operation!(%{
      id: "30000000-0000-0000-0000-000000000016",
      connection_id: "00000000-0000-0000-0000-000000000016",
      attempt_ref: "20000000-0000-0000-0000-000000000016",
      operation_class: "replace",
      correlation_id: "op-terminal-reauth",
      expected_connection_version: 20,
      attempt_version: 1,
      attempt_claim_token: "claim-terminal-reauth",
      prior_credential_ref: "cred-terminal-reauth-old",
      prior_credential_version: 7,
      status: "fenced"
    })

    query!(
      """
      UPDATE provider_connections
         SET status = 'revoked', connection_version = 22
       WHERE connection_id = '00000000-0000-0000-0000-000000000011'::uuid
      """,
      []
    )

    query!(
      """
      UPDATE provider_connection_operations
         SET status = 'fenced', safe_error_code = 'connection_terminal'
       WHERE correlation_id = 'op-fenced-callback'
      """,
      []
    )
  end

  defp insert_pre_supplement_attempt!(attempt_ref, connection_id, authorization_ref, version) do
    query!(
      """
      INSERT INTO provider_authorization_attempts
        (attempt_ref, workspace_uri, backend_pair_id, authorization_ref, connection_id,
         connection_version, bound_subject_digest, state_digest, correlation_id,
         attempt_version, status, purpose, reservation_digest,
         requested_permission_digest, requested_execution_identity_class,
         redirect_uri_id, callback_artifact_digest, expires_at, inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', 'pair-a', $2, $3, $4, 'subject', $5,
              $6, 1, 'consumed', 'reauthorize', 'reservation',
              'perm', 'connected_user', 'callback-v1', 'artifact',
              now() + interval '1 hour', now(), now())
      """,
      [
        Ecto.UUID.dump!(attempt_ref),
        authorization_ref,
        Ecto.UUID.dump!(connection_id),
        version,
        "state-#{attempt_ref}",
        "attempt-#{attempt_ref}"
      ]
    )
  end

  defp insert_pre_supplement_operation!(attrs) do
    query!(
      """
      INSERT INTO provider_connection_operations
        (id, workspace_uri, connection_id, backend_pair_id, operation_class,
         correlation_id, bound_input_digest, expected_connection_version,
         expected_credential_version, result_ref, result_credential_version,
         provider_result_ref, handoff_ref, result_external_account_id,
         result_display_login, result_execution_identity, result_authorization_ref,
         result_authorization_version, result_permission_digest, attempt_ref,
         attempt_version, attempt_claim_token, prior_credential_ref,
         prior_credential_version, status,
         next_recovery_at, inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', $2, 'pair-a', $3, $4, 'digest', $5, 1,
              $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
              $19, $20, $21, CASE WHEN $21 = 'finalized' THEN NULL ELSE now() END,
              now(), now())
      """,
      [
        Ecto.UUID.dump!(attrs.id),
        Ecto.UUID.dump!(attrs.connection_id),
        attrs.operation_class,
        attrs.correlation_id,
        attrs.expected_connection_version,
        Map.get(attrs, :result_ref),
        Map.get(attrs, :result_credential_version),
        Map.get(attrs, :provider_result_ref),
        Map.get(attrs, :handoff_ref),
        Map.get(attrs, :result_external_account_id),
        Map.get(attrs, :result_display_login),
        Map.get(attrs, :result_execution_identity),
        Map.get(attrs, :result_authorization_ref),
        Map.get(attrs, :result_authorization_version),
        Map.get(attrs, :result_permission_digest),
        attrs |> Map.get(:attempt_ref) |> then(&if(&1, do: Ecto.UUID.dump!(&1), else: nil)),
        Map.get(attrs, :attempt_version),
        Map.get(attrs, :attempt_claim_token),
        Map.get(attrs, :prior_credential_ref),
        Map.get(attrs, :prior_credential_version),
        attrs.status
      ]
    )
  end

  defp insert_connection!(id, status, suffix) do
    pending? = status == "pending_authorization"

    query!(
      """
      INSERT INTO provider_connections
        (connection_id, workspace_uri, owner_uri, provider_id, governed_host,
         external_account_id, display_login, execution_identity, acquisition_method,
         authorization_backend_ref, credential_backend_ref, authorization_version,
         credential_version, connection_version, status, permission_digest,
         backend_pair_id, authorization_backend_id, credential_backend_id,
         refresh_lease_version, inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', 'entity://acme/user/u1', 'fake', 'example.test',
              $2, $3, 'connected_user', 'oauth', $4, $5, 1, 1, $6, $7, 'perm',
              'pair-a', 'auth-b', 'cred-b', 0, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        if(pending?, do: "pending:account", else: "acct-#{suffix}"),
        suffix,
        if(pending?, do: "pending:authorization", else: "auth-#{suffix}"),
        if(pending?, do: "pending:credential", else: "cred-#{suffix}"),
        String.length(suffix),
        status
      ]
    )
  end

  defp insert_backend_record!(id, authorization_ref, connection_id, version, suffix) do
    query!(
      """
      INSERT INTO provider_authorization_backend_records
        (id, workspace_uri, backend_pair_id, authorization_ref, execution_identity,
         key_id, key_fingerprint, nonce, ciphertext, bound_input_digest,
         begin_correlation_id, owner_uri, connection_id, connection_version,
         provider_id, governed_host, acquisition_method, requested_permissions_digest,
         redirect_uri_id, lifecycle_status, expires_at, inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', 'pair-a', $2, 'connected_user', 'key-a', $3,
              $4, $5, $6, $7, 'entity://acme/user/u1', $8, $9, 'fake',
              'example.test', 'oauth', 'perm-requested', 'callback-v1', 'pending',
              now() + interval '1 hour', now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        authorization_ref,
        <<1>>,
        <<2>>,
        <<3>>,
        "bound-#{suffix}",
        "begin-#{suffix}",
        connection_id,
        version
      ]
    )
  end

  defp insert_attempt!(id, authorization_ref, connection_id, version, status) do
    query!(
      """
      INSERT INTO provider_authorization_attempts
        (attempt_ref, workspace_uri, backend_pair_id, authorization_ref, connection_id,
         connection_version, bound_subject_digest, state_digest, correlation_id,
         attempt_version, status, callback_artifact, claim_token, claim_until,
         expires_at, inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', 'pair-a', $2, $3, $4, $5, $6, $7, 1, $8,
              '{}', $9, $10, now() + interval '1 hour', now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        authorization_ref,
        Ecto.UUID.dump!(connection_id),
        version,
        "subject-#{status}",
        "state-#{status}",
        "corr-#{status}",
        status,
        if(status == "consuming", do: "claim", else: nil),
        if(status == "consuming", do: DateTime.add(DateTime.utc_now(), 300), else: nil)
      ]
    )
  end

  defp insert_operation!(connection_id, status, suffix) do
    operation_class =
      case suffix do
        "backend" -> "store"
        "cleanup" -> "revoke"
        "termination" -> "revoke"
        _other -> "refresh"
      end

    result_ref = if status in ["backend_committed", "cleanup_pending"], do: "result-#{suffix}"
    store? = operation_class == "store"

    operation_id =
      Map.fetch!(%{"backend" => 4, "cleanup" => 5, "refreshing" => 6, "termination" => 7}, suffix)

    query!(
      """
      INSERT INTO provider_connection_operations
        (id, workspace_uri, connection_id, backend_pair_id, operation_class,
         correlation_id, bound_input_digest, expected_connection_version,
         expected_credential_version, result_ref, status, safe_error_code,
         result_credential_version, prior_credential_ref, prior_credential_version,
         attempt_ref, attempt_version, attempt_claim_token, handoff_ref,
         inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', $2, 'pair-a', $3, $4, 'digest', $13, 1,
              $5, $6, $7, $8, $9, 1, $14, $10, $11, $12, now(), now())
      """,
      [
        Ecto.UUID.dump!(
          "30000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(operation_id), 12, "0")}"
        ),
        Ecto.UUID.dump!(connection_id),
        operation_class,
        "op-#{suffix}",
        result_ref,
        status,
        if(status == "cleanup_pending", do: "cleanup_pending", else: nil),
        if(result_ref, do: 2, else: nil),
        if(result_ref, do: "prior-#{suffix}", else: nil),
        if(store?, do: 1, else: nil),
        if(store?, do: "claim-#{suffix}", else: nil),
        if(store?, do: "handoff-#{suffix}", else: nil),
        String.length(suffix),
        if(
          store?,
          do: Ecto.UUID.dump!("20000000-0000-0000-0000-000000000004"),
          else: nil
        )
      ]
    )
  end

  defp scalar!(sql), do: query!(sql, []).rows |> hd() |> hd()
  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(MigrationTestRepo, sql, params)

  defp connection_options(database) do
    [
      username: System.get_env("POSTGRES_USER", "ezagent_pg_compat"),
      password: System.get_env("POSTGRES_PASSWORD", "ezagent_pg_compat"),
      hostname: System.get_env("POSTGRES_HOST", "127.0.0.1"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "55432")),
      database: database
    ]
  end
end
