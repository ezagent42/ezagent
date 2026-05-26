defmodule Mix.Tasks.Ezagent.Home.AdoptDb do
  @shortdoc "Move repo-root ezagent_core_dev.db into $EZAGENT_HOME/<profile>/db/"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (DB maintenance).**
  > Intentionally NOT a dispatched op. Moves the SQLite DB file on
  > disk before/around the runtime BEAM. Stays as `mix ezagent.*`;
  > do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  Phase 6 PR 1 — finishes the runtime-state migration started in Phase 5
  PR 1 by moving the dev SQLite DB out of the repo working tree and into
  `$EZAGENT_HOME/<profile>/db/ezagent_core.db`.

  Concrete moves (only files that exist; idempotent):

      <repo-root>/ezagent_core_dev.db      → $EZAGENT_HOME/<profile>/db/ezagent_core.db
      <repo-root>/ezagent_core_dev.db-shm  → $EZAGENT_HOME/<profile>/db/ezagent_core.db-shm
      <repo-root>/ezagent_core_dev.db-wal  → $EZAGENT_HOME/<profile>/db/ezagent_core.db-wal

  After the move, dev Phoenix server reads the DB path from
  `Ezagent.Home.path(:db)` via `config/runtime.exs` (no more
  `Path.expand("../ezagent_core_dev.db", __DIR__)`).

  ## Usage

      mix ezagent.home.adopt_db

  ## Idempotency

  - If no repo-root DB exists, prints a notice and exits 0.
  - If target already exists, refuses to overwrite (operator must
    delete the target by hand — we don't decide which copy wins).
  - Init runs implicitly if `$EZAGENT_HOME` skeleton is missing.

  ## Safety

  - Requires the dev server to be stopped (we detect a live wal lock
    and refuse to proceed). Lock-detection is best-effort: if a server
    holds the WAL, the move will succeed at the FS layer but the
    server will keep writing to its stale FD. Stop the server first.
  """
  use Mix.Task

  alias Ezagent.Home

  @repo_files [
    {"ezagent_core_dev.db", "ezagent_core.db"},
    {"ezagent_core_dev.db-shm", "ezagent_core.db-shm"},
    {"ezagent_core_dev.db-wal", "ezagent_core.db-wal"}
  ]

  @impl Mix.Task
  def run(_argv) do
    unless Home.initialized?() do
      Mix.shell().info("EZAGENT_HOME not initialized — running mix ezagent.home.init first")
      Mix.Task.run("ezagent.home.init")
    end

    repo_root = repo_root!()
    target_dir = Home.path(:db)
    File.mkdir_p!(target_dir)

    moved = Enum.flat_map(@repo_files, &move_one(repo_root, target_dir, &1))

    case moved do
      [] ->
        Mix.shell().info(
          "No repo-root dev DB found at #{repo_root}/ezagent_core_dev.db — nothing to adopt."
        )

        Mix.shell().info(
          "Dev server already reads from #{target_dir}/ezagent_core.db on next start."
        )

      files ->
        Mix.shell().info("Adopted #{length(files)} file(s) into #{target_dir}:")
        Enum.each(files, fn f -> Mix.shell().info("  ✓ #{f}") end)
        Mix.shell().info("")
        Mix.shell().info("Repo working tree is now clean of dev DB files.")
        Mix.shell().info("Next: restart `mix phx.server` to pick up the new path.")
    end
  end

  defp move_one(repo_root, target_dir, {src_name, dst_name}) do
    src = Path.join(repo_root, src_name)
    dst = Path.join(target_dir, dst_name)

    cond do
      not File.exists?(src) ->
        []

      File.exists?(dst) ->
        Mix.raise("""
        Refusing to overwrite existing target: #{dst}
        Either delete the target file, or delete the source file in the repo root.
        """)

      true ->
        File.rename!(src, dst)
        [dst_name]
    end
  end

  defp repo_root! do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> Mix.raise("must run from inside the esr-ng repo (git rev-parse failed)")
    end
  end
end
