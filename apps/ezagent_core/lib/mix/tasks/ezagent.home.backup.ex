defmodule Mix.Tasks.Ezagent.Home.Backup do
  @shortdoc "Back up the active EZAGENT_HOME profile (db + config dirs) for migration"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (FS op around the BEAM).**
  > Like `ezagent.home.adopt_db` / `ezagent.home.init`, this is intentionally
  > NOT a dispatched op — it copies the SQLite DB + on-disk config trees at the
  > filesystem layer. Stays as `mix ezagent.home.*`; do NOT migrate to
  > `mix ezagent`.

  Complete-migration capability (home portability #120). Produces a
  **consistent** snapshot of `$EZAGENT_HOME/$EZAGENT_PROFILE/` that, restored
  via `mix ezagent.home.restore`, fully reconstitutes the system on another
  machine or path.

  ## Usage

      mix ezagent.home.backup --out <path.tar.gz>
      mix ezagent.home.backup --out <dir>

      EZAGENT_HOME=/data/ezagent EZAGENT_PROFILE=prod \\
        mix ezagent.home.backup --out /backups/ezagent-$(date +%F).tar.gz

  A `--out` ending in `.tar.gz`/`.tgz` produces a gzipped tarball; any other
  value is treated as an output directory (must be empty / non-existent).

  ## What's included

  - `db/ezagent_core.db` — the source of truth (users, caps, sessions,
    routing rules, Kind snapshots). Copied via SQLite `VACUUM INTO` for a
    consistent, fully-checkpointed snapshot (safe even with a live `-wal`).
  - `cc-agents/`, `codex/`, `credentials/`, `snapshots/`, `plugins/`,
    `uploads/`, `inbox/` — the on-disk trees the DB references.

  ## What's excluded (ephemeral / host-local — rebuilt on boot)

  - `logs/`, `pty-pids/` (live PID tracking), `runtime/` (node cookie).

  ## Safety

  `VACUUM INTO` reads a single consistent transaction, so a backup taken
  while the server runs is internally consistent. For a guaranteed-quiescent
  copy, stop the server first.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:exqlite)

    {opts, _, _} = OptionParser.parse(argv, switches: [out: :string])

    out =
      opts[:out] ||
        Mix.raise("""
        --out is required.

            mix ezagent.home.backup --out <path.tar.gz | dir>
        """)

    case Ezagent.Home.Migration.backup(out) do
      {:ok, path} ->
        Mix.shell().info("✓ Backed up #{Ezagent.Home.profile_dir()}")
        Mix.shell().info("  → #{path}")
        Mix.shell().info("")
        Mix.shell().info("Restore on the target with:")

        Mix.shell().info(
          "  mix ezagent.home.restore --from #{path} --home <EZAGENT_HOME> --profile <profile>"
        )

      {:error, {:home_not_found, dir}} ->
        Mix.raise("EZAGENT_HOME profile not found: #{dir}\nNothing to back up.")

      {:error, reason} ->
        Mix.raise("backup failed: #{inspect(reason)}")
    end
  end
end
