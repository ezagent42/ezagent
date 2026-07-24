Code.require_file("../support/profile_display_name_migration_test_repo.exs", __DIR__)

defmodule Ezagent.ProfileDisplayNameMigrationTest do
  use ExUnit.Case, async: false

  alias Ezagent.ProfileDisplayNameMigrationTestRepo, as: MigrationRepo

  @migrations [
    {20_260_724_000_000, "20260724000000_add_agent_profile_display_name_uniqueness.exs",
     EzagentCore.Repo.Migrations.AddAgentProfileDisplayNameUniqueness},
    {20_260_724_001_000, "20260724001000_scope_agent_profile_display_name_uniqueness.exs",
     EzagentCore.Repo.Migrations.ScopeAgentProfileDisplayNameUniqueness},
    {20_260_724_002_000, "20260724002000_repair_agent_profile_display_name_uniqueness.exs",
     EzagentCore.Repo.Migrations.RepairAgentProfileDisplayNameUniqueness}
  ]

  test "duplicate no-email users migrate while agent display names remain workspace-unique" do
    database = "profile_display_name_migration_#{System.unique_integer([:positive])}"
    admin_options = connection_options("postgres")
    {:ok, admin} = Postgrex.start_link(admin_options)
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])

    previous = Application.get_env(:ezagent_core, MigrationRepo)

    Application.put_env(
      :ezagent_core,
      MigrationRepo,
      connection_options(database) ++
        [pool_size: 2, migration_lock: nil, priv: "priv/repo_pg"]
    )

    {:ok, repo_pid} = MigrationRepo.start_link()

    on_exit(fn ->
      if Process.alive?(repo_pid) do
        try do
          GenServer.stop(repo_pid)
        catch
          :exit, _reason -> :ok
        end
      end

      {:ok, cleanup_admin} = Postgrex.start_link(admin_options)

      Postgrex.query!(
        cleanup_admin,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
        [database]
      )

      Postgrex.query!(cleanup_admin, ~s(DROP DATABASE "#{database}"), [])

      if previous,
        do: Application.put_env(:ezagent_core, MigrationRepo, previous),
        else: Application.delete_env(:ezagent_core, MigrationRepo)
    end)

    create_entity_profiles!()
    seed_legal_duplicates!()
    migrate(@migrations)

    assert scalar!("SELECT count(*) FROM entity_profiles WHERE display_name = 'Shared'") == 2
    assert_agent_scoped_predicate!()

    error =
      assert_raise Postgrex.Error, fn ->
        insert_profile!("entity://migration/agent/second", "Builder")
      end

    assert error.postgres.code == :unique_violation

    assert :ok =
             Ecto.Migrator.down(
               MigrationRepo,
               20_260_724_002_000,
               EzagentCore.Repo.Migrations.RepairAgentProfileDisplayNameUniqueness,
               log: false
             )

    assert_agent_scoped_predicate!()

    assert :ok =
             Ecto.Migrator.down(
               MigrationRepo,
               20_260_724_001_000,
               EzagentCore.Repo.Migrations.ScopeAgentProfileDisplayNameUniqueness,
               log: false
             )

    assert_agent_scoped_predicate!()

    # Model a database that already applied the original broad migration,
    # then prove the new forward migration repairs it without relying on the
    # edited historical source.
    query!("DELETE FROM entity_profiles WHERE entity_uri = 'entity://migration/user/second'")
    query!("DROP INDEX entity_profiles_agent_workspace_display_name_index")

    query!("""
    CREATE UNIQUE INDEX entity_profiles_agent_workspace_display_name_index
      ON entity_profiles (workspace_uri, display_name)
      WHERE email IS NULL
    """)

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               20_260_724_002_000,
               EzagentCore.Repo.Migrations.RepairAgentProfileDisplayNameUniqueness,
               log: false
             )

    assert_agent_scoped_predicate!()
    insert_profile!("entity://migration/user/reintroduced", "Shared")
    assert scalar!("SELECT count(*) FROM entity_profiles WHERE display_name = 'Shared'") == 2
  end

  defp create_entity_profiles! do
    query!("""
    CREATE TABLE entity_profiles (
      entity_uri varchar(255) PRIMARY KEY,
      display_name varchar(255) NOT NULL,
      email varchar(255),
      workspace_uri varchar(255) NOT NULL,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """)
  end

  defp seed_legal_duplicates! do
    insert_profile!("entity://migration/user/first", "Shared")
    insert_profile!("entity://migration/user/second", "Shared")
    insert_profile!("entity://migration/agent/first", "Builder")
  end

  defp insert_profile!(entity_uri, display_name) do
    query!(
      """
      INSERT INTO entity_profiles
        (entity_uri, display_name, email, workspace_uri, inserted_at, updated_at)
      VALUES ($1, $2, NULL, 'workspace://migration', now(), now())
      """,
      [entity_uri, display_name]
    )
  end

  defp migrate(migrations) do
    migration_dir = Application.app_dir(:ezagent_core, "priv/repo_pg/migrations")

    Enum.each(migrations, fn {version, filename, module} ->
      unless Code.ensure_loaded?(module) do
        Code.require_file(Path.join(migration_dir, filename))
      end

      assert :ok = Ecto.Migrator.up(MigrationRepo, version, module, log: false)
    end)
  end

  defp scalar!(sql), do: query!(sql).rows |> hd() |> hd()

  defp assert_agent_scoped_predicate! do
    predicate =
      scalar!("""
      SELECT pg_get_expr(index_definition.indpred, index_definition.indrelid)
        FROM pg_index AS index_definition
        JOIN pg_class AS index_relation
          ON index_relation.oid = index_definition.indexrelid
       WHERE index_relation.relname =
             'entity_profiles_agent_workspace_display_name_index'
      """)

    assert predicate =~ "/agent/"
    refute predicate =~ "email IS NULL"
  end

  defp query!(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, sql, params)

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
