defmodule Mix.Tasks.Ezagent.Bootstrap do
  @shortdoc "One-command Ezagent install: home.init + ecto.migrate + health-check"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (bootstrap).**
  > Intentionally NOT a dispatched op. Runs BEFORE the runtime BEAM is
  > available (installs/repairs it). Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  Phase 7 PR 33 (D7-5, D7-9) — the canonical "dev team installs Ezagent
  on a prod-like host" entry point. Wraps the existing single-purpose
  tasks into a single command so a new contributor can go from
  `git clone` to a running Ezagent in one step.

  ## Usage

      mix ezagent.bootstrap                # default profile
      EZAGENT_PROFILE=staging mix ezagent.bootstrap

  ## What it runs (in order)

  1. **`mix ezagent.home.init`** — creates `$EZAGENT_HOME/<profile>/`
     skeleton (credentials, db, snapshots, logs, plugins). Idempotent.
  2. **`mix deps.get`** — ensures dependency tree is present (no-op if
     already fetched).
  3. **`mix ezagent.home.adopt_db`** — compatibility no-op after PostgreSQL
     migration; retained so old bootstrap scripts remain idempotent.
  4. **`mix ecto.create`** + **`mix ecto.migrate`** — ensures the PostgreSQL
     DB exists and schema is current. No-op on schema-current.
  5. **Health check** — opens an Ecto connection and runs a trivial
     query (`SELECT 1`). Confirms config + DB are wired correctly
     before the dev tries `mix phx.server`.

  ## What it does NOT do

  - Start phx.server (the dev does that — bootstrap is install, not
    runtime). Print the start command at the end.
  - Mint admin credentials beyond what `ezagent.home.init` already does
    (operator-supplied secrets are out of scope; bootstrap shouldn't
    touch `credentials/*.yaml`).
  - Run plugin-specific seed scripts (e.g. Feishu user binding).
    Those are documented in plugin authoring guide; bootstrap stays
    plugin-agnostic.

  ## Idempotency

  Re-running on an already-bootstrapped host is safe and produces no
  changes (other than touch on lockfiles + ecto reporting "already
  up"). Useful for CI gates that want to confirm a checkout is
  ready-to-serve.

  ## Exit codes

  - `0` — bootstrap complete; ready to `mix phx.server`
  - `1` — one of the sub-steps failed; error printed to stderr
  """

  use Mix.Task

  alias Ezagent.Home

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info(banner("Phase 1 — EZAGENT_HOME skeleton (ezagent.home.init)"))
    Mix.Task.run("ezagent.home.init", [])

    Mix.shell().info(banner("Phase 2 — Dependencies (mix deps.get)"))
    Mix.Task.run("deps.get", [])

    Mix.shell().info(banner("Phase 3 — DB migration to EZAGENT_HOME (ezagent.home.adopt_db)"))
    Mix.Task.run("ezagent.home.adopt_db", [])

    Mix.shell().info(banner("Phase 4 — Ecto schema (ecto.create + ecto.migrate)"))
    # Both apps' Repos need to be migrated; the umbrella's mix tasks
    # walk them for us.
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    Mix.shell().info(banner("Phase 5 — Health check"))
    health_check_summary()

    Mix.shell().info("""

    ✅ Bootstrap complete.

    EZAGENT_HOME:    #{Home.profile_dir()}
    DB:          #{Home.path(:db)}
    Credentials: #{Home.path(:credentials)} (chmod 700)
    Logs:        #{Home.path(:logs)}

    Next: start the server.
        mix phx.server

    Admin LV will be reachable at http://localhost:10042/admin.

    For multi-host or quasi-production setups, see
    docs/onboarding/first-30-days.md.
    """)
  end

  defp banner(label) do
    """

    ───────────────────────────────────────────────────────────────
    #{label}
    ───────────────────────────────────────────────────────────────
    """
  end

  defp health_check_summary do
    # Start the app so EzagentCore.Repo is alive for the SELECT 1 check.
    # Mix is in non-running mode by default; we need just enough to
    # ping the database.
    case Application.ensure_all_started(:ezagent_core) do
      {:ok, _started} ->
        case Ecto.Adapters.SQL.query(EzagentCore.Repo, "SELECT 1", []) do
          {:ok, _} ->
            Mix.shell().info("    ✓ Ecto connection: OK (SELECT 1 returned)")

          {:error, err} ->
            Mix.shell().error("    ✗ Ecto query failed: #{inspect(err)}")
            exit({:shutdown, 1})
        end

      {:error, err} ->
        Mix.shell().error("    ✗ Failed to start :ezagent_core for health check: #{inspect(err)}")
        exit({:shutdown, 1})
    end
  end
end
