defmodule Mix.Tasks.Ezagent.Home.Restore do
  @shortdoc "Restore an ezagent-home backup and configured PostgreSQL DB"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (FS op around the BEAM).**
  > This is intentionally NOT a dispatched op. It unpacks files, restores the
  > PostgreSQL dump, and rewrites persisted home paths before the runtime
  > starts. Stays as `mix ezagent.home.*`.

  Complete-migration capability (home portability #120). Unpacks a backup
  produced by `mix ezagent.home.backup` into a target home + profile and
  **rewrites every persisted absolute path** so the restored system points at
  the NEW location (see `docs/notes/home-portability-audit.md`).

  ## Usage

      mix ezagent.home.restore --from <backup> --home <EZAGENT_HOME> --profile <profile>
      mix ezagent.home.restore --from <backup> --home <EZAGENT_HOME> --profile <profile> --force

  - `--from` — a `.tar.gz`/`.tgz` or directory produced by `home.backup`.
  - `--home` — the target `EZAGENT_HOME` (the restored profile lands at
    `<home>/<profile>/`).
  - `--profile` — the target profile name (need not match the source).
  - `--force` — overwrite a non-empty target profile dir (otherwise refused).

  ## What it does

  1. Copies config trees into `<home>/<profile>/`.
  2. Restores `db/ezagent_core.dump` into the currently configured Repo DB.
  3. Recreates the ephemeral skeleton (`logs/`, `pty-pids/`, `runtime/`).
  4. Rewrites the Sandbox slices in `kind_snapshots.state_binary` whose
     `config_dir_path` / `agent_config_dir` pointed at the SOURCE profile dir
     so they point at the TARGET profile dir. The source prefix is read from
     the backup's `MANIFEST.json`.

  After restore, point the server at the target home:

      EZAGENT_HOME=<home> EZAGENT_PROFILE=<profile> mix phx.server

  ## Safety

  Refuses to clobber a non-empty target profile dir unless `--force`.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [from: :string, home: :string, profile: :string, force: :boolean]
      )

    from = opts[:from] || Mix.raise(usage("--from is required"))
    home = opts[:home] || Mix.raise(usage("--home is required"))
    profile = opts[:profile] || Mix.raise(usage("--profile is required"))
    force? = opts[:force] || false

    case Ezagent.Home.Migration.restore(from, home, profile, force: force?) do
      {:ok, {target_profile_dir, rewritten}} ->
        Mix.shell().info("✓ Restored into #{target_profile_dir}")
        Mix.shell().info("  rewrote #{rewritten} snapshot path(s) to the new home")
        Mix.shell().info("")
        Mix.shell().info("Boot the restored home with:")
        Mix.shell().info("  EZAGENT_HOME=#{Path.expand(home)} EZAGENT_PROFILE=#{profile} \\")
        Mix.shell().info("    mix phx.server")

      {:error, {:target_not_empty, dir}} ->
        Mix.raise("""
        Refusing to overwrite non-empty target: #{dir}
        Pass --force to overwrite, or choose a fresh --home/--profile.
        """)

      {:error, {:backup_not_found, p}} ->
        Mix.raise("backup not found: #{p}")

      {:error, reason} ->
        Mix.raise("restore failed: #{inspect(reason)}")
    end
  end

  defp usage(msg) do
    """
    #{msg}

        mix ezagent.home.restore --from <backup> --home <EZAGENT_HOME> --profile <profile> [--force]
    """
  end
end
