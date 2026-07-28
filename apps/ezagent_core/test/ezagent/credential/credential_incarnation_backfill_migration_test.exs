Code.require_file(
  "../../support/credential_incarnation_backfill_migration_test_repo.exs",
  __DIR__
)

defmodule Ezagent.CredentialIncarnationBackfillMigrationTest do
  @moduledoc """
  #201-cred (codex r3 MEDIUM-4) — the NULL-incarnation backfill must live in a
  NEW, later-timestamped migration, NOT inside the already-applied
  `20260727120000_add_incarnation_id_to_credential_grants`.

  Fail-before/pass-after reproduction of the deploy bug: an upgraded database ran
  `20260727120000` (round-1, column add) BEFORE any backfill existed. We simulate
  that by migrating THROUGH `20260727120000`, seeding a NULL-incarnation grant row
  (a row on the already-upgraded DB), then running the REMAINING migrations.

    * With the fix (backfill in `20260728000000`) the new migration is pending and
      runs → the NULL is backfilled to `'legacy:' || id`.
    * Reverting the fix (backfill folded back into the already-applied
      `20260727120000`, no later migration) leaves the seeded NULL untouched — no
      pending migration ever visits it — and this test reds.
  """
  use ExUnit.Case, async: false

  alias Ezagent.CredentialIncarnationBackfillMigrationTestRepo, as: MigrationRepo

  # The column-add migration an already-upgraded DB has already applied.
  @add_incarnation_version 20_260_727_120_000

  test "a NEW later migration backfills NULL incarnation_ids on an already-upgraded DB" do
    database = "credential_incarnation_backfill_migration_#{System.unique_integer([:positive])}"
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

    migrations_path = Application.app_dir(:ezagent_core, "priv/repo_pg/migrations")

    # 1. Upgrade the DB THROUGH the column-add migration (nothing later yet).
    Ecto.Migrator.run(MigrationRepo, migrations_path, :up,
      to: @add_incarnation_version,
      log: false
    )

    # 2. A grant row on that already-upgraded DB carries a NULL incarnation_id.
    #    Seed it via raw SQL — the changeset ALWAYS overwrites incarnation_id, so
    #    a NULL can only be produced by bypassing it.
    agent_uri = "entity://team-a/agent/legacy-null"

    query!(
      """
      INSERT INTO credential_grants
        (id, agent_uri, workspace_uri, credential_source_uri, approved_by,
         approved_scope, version, incarnation_id, inserted_at, updated_at)
      VALUES ($1, $1, 'workspace://team-a', 'entity://team-a/agent/src',
              'entity://team-a/user/alice', 'entity://team-a/agent/src', 1, NULL,
              now(), now())
      """,
      [agent_uri]
    )

    assert scalar!(
             "SELECT incarnation_id FROM credential_grants WHERE id = '#{agent_uri}'"
           ) == nil

    # 3. Run the REMAINING migrations (the new later-timestamped backfill).
    Ecto.Migrator.run(MigrationRepo, migrations_path, :up, all: true, log: false)

    # 4. The new migration reached the pre-existing NULL row and backfilled it.
    assert scalar!(
             "SELECT incarnation_id FROM credential_grants WHERE id = '#{agent_uri}'"
           ) == "legacy:#{agent_uri}"
  end

  defp scalar!(sql), do: query!(sql).rows |> hd() |> hd()

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
