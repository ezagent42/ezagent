defmodule Mix.Tasks.Ezagent.Db.Reset do
  @shortdoc "Drop + recreate the configured Ezagent PostgreSQL DB (no prompts)"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (DB maintenance).**
  > Intentionally NOT a dispatched op. Wipes + rebuilds the DB the
  > runtime needs to even start. Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
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

  1. Drops the configured PostgreSQL database
  2. Recreates it
  3. Runs every migration in the configured Repo `:priv` path
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

  @impl Mix.Task
  def run(_args) do
    # Boot just the Repo + Home plumbing — NOT the full Application
    # tree (we'd boot UserSupervisor against a still-being-rebuilt
    # schema). Repo + Ecto are enough for migrations.
    Mix.shell().info("Resetting Ezagent PostgreSQL DB")

    Mix.Task.run("ecto.drop", ["--force", "--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    Mix.shell().info("✓ DB reset complete — boot Ezagent to repopulate seeds")
    :ok
  end
end
