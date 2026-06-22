defmodule Mix.Tasks.Ezagent.Home.AdoptDb do
  @shortdoc "Deprecated no-op: SQLite DB adoption was retired"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (DB maintenance).**
  > Intentionally NOT a dispatched op. This task is retained as a
  > compatibility no-op after the PostgreSQL-only migration. Stays as `mix ezagent.*`;
  > do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  ## Usage

      mix ezagent.home.adopt_db

  ## Idempotency

  Always exits 0 after ensuring the home skeleton exists.
  """
  use Mix.Task

  alias Ezagent.Home

  @impl Mix.Task
  def run(_argv) do
    unless Home.initialized?() do
      Mix.shell().info("EZAGENT_HOME not initialized — running mix ezagent.home.init first")
      Mix.Task.run("ezagent.home.init")
    end

    Mix.shell().info("SQLite DB adoption is retired; Ezagent now uses PostgreSQL Repo config.")
  end
end
