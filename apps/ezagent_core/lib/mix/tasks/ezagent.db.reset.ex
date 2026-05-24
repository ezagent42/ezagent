defmodule Mix.Tasks.Ezagent.Db.Reset do
  @shortdoc "Wipe + recreate the local Ezagent SQLite DB (no prompts)"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (DB maintenance).**
  > Intentionally NOT a dispatched op. Wipes + rebuilds the DB the
  > runtime needs to even start. Stays as `mix ezagent.*`; do NOT
  > migrate to `mix esr`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  PR #141 SPEC v2 §5.11 — "no backward compatibility, clean rebuild".

  Existing DB data is wiped and the schema rebuilt from scratch via
  the ordered migration list. Used by dev / CI to recover from a URI
  scheme migration without operator intervention.

  ## Usage

      mix ezagent.db.reset
      MIX_ENV=test mix ezagent.db.reset

  ## What it does

  1. Drops the SQLite file at `$EZAGENT_HOME/<profile>/db/ezagent_core.db`
     (default `~/.ezagent/default/db/ezagent_core.db`)
  2. Recreates an empty file
  3. Runs every migration in
     `apps/ezagent_core/priv/repo/migrations/` in order
  4. Re-runs application boot-time seed callbacks if Ezagent is
     subsequently started (admin User, default Workspace, etc.)

  ## Safety

  This task is destructive — there is no prompt, no `--force`
  required. It is intended for dev environments where data is
  considered ephemeral. **Do not run against any production DB.**
  Recommended invocation pattern is from a worktree's `bin/reset.sh`
  or CI bootstrap script with the DB path explicitly bound.
  """

  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(_args) do
    # Boot just the Repo + Home plumbing — NOT the full Application
    # tree (we'd boot UserSupervisor against a still-being-rebuilt
    # schema). Repo + Ecto are enough for migrations.
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    db_path = ezagent_db_path()
    Mix.shell().info("Resetting Ezagent DB at #{db_path}")

    drop_db(db_path)
    ensure_db_dir(db_path)
    run_migrations()

    Mix.shell().info("✓ DB reset complete — boot Ezagent to repopulate seeds")
    :ok
  end

  defp ezagent_db_path do
    case Application.get_env(:ezagent_core, EzagentCore.Repo) do
      nil ->
        # Fallback to Home convention
        home = System.get_env("EZAGENT_HOME") || Path.join(System.user_home!(), ".ezagent")
        profile = System.get_env("EZAGENT_PROFILE") || "default"
        Path.join([home, profile, "db", "ezagent_core.db"])

      config ->
        Keyword.get(config, :database) ||
          raise "EzagentCore.Repo config missing :database"
    end
  end

  defp drop_db(path) do
    if File.exists?(path) do
      File.rm!(path)
      Mix.shell().info("  removed #{path}")
    else
      Mix.shell().info("  no existing DB at #{path} — skipping drop")
    end

    # SQLite auxiliary files (WAL, SHM) — clean these too so the next
    # connection doesn't read stale write-ahead pages.
    for suffix <- ["-shm", "-wal", "-journal"] do
      aux = path <> suffix
      if File.exists?(aux), do: File.rm!(aux)
    end

    :ok
  end

  defp ensure_db_dir(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :ok
  end

  defp run_migrations do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(EzagentCore.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end
end
