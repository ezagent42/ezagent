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
           """) == 4

    assert scalar!("""
           WITH expected(id, operation_class, status, provider_result_ref) AS (
             VALUES
               ('30000000-0000-0000-0000-000000000004'::uuid, 'store', 'backend_committed', 'handoff-backend'),
               ('30000000-0000-0000-0000-000000000005'::uuid, 'refresh', 'cleanup_pending', NULL),
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

    insert_operation!("00000000-0000-0000-0000-000000000004", "backend_committed", "backend")
    insert_operation!("00000000-0000-0000-0000-000000000005", "cleanup_pending", "cleanup")
    insert_operation!("00000000-0000-0000-0000-000000000006", "prepared", "refreshing")
    insert_operation!("00000000-0000-0000-0000-000000000007", "backend_committed", "termination")
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
         attempt_version, attempt_claim_token, handoff_ref,
         inserted_at, updated_at)
      VALUES ($1, 'workspace://acme', $2, 'pair-a', $3, $4, 'digest', 1, 1,
              $5, $6, $7, $8, $9, 1, $10, $11, $12, now(), now())
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
        if(store?, do: "handoff-#{suffix}", else: nil)
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
