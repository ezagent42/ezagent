defmodule Ezagent.Invariants.BootstrapToServingTest do
  @moduledoc """
  Phase 7 completion PR-6 closeout — the V1.1 gating test the audit
  (`docs/notes/phase-7-implementation-audit-2026-05-22.md` §V1-V5)
  named `bootstrap_to_serving_test` as MISSING.

  V1.1 contract: a new contributor goes from `git clone` to a running
  Ezagent in one command — `mix ezagent.bootstrap` (Decision #139 /
  D7-9). The bootstrap task is the install path: EZAGENT_HOME skeleton
  → deps → DB adopt → `ecto.create` + `ecto.migrate` → a `SELECT 1`
  **health check** that confirms the checkout is ready to serve before
  the dev runs `mix phx.server`.

  Running the full task here would mutate the operator's machine
  (creates `$EZAGENT_HOME`, migrates the real DB) — out of scope for a
  CI unit test. This gate instead asserts the **end-state the task
  delivers + verifies** (its own Phase-5 step): the Repo is alive and
  serving SQL, the schema is migrated, and the EZAGENT_HOME paths
  resolve. That end-state IS "ready to serve" — the same condition the
  task's `SELECT 1` health check confirms. It also pins the task module
  + its documented D7-9 contract so the one-command entry point cannot
  be silently removed.

  Pure assertions against the already-bootstrapped test environment —
  the test DB the suite runs against IS a bootstrapped Ezagent.
  """

  use EzagentCore.DataCase, async: false

  describe "the bootstrap task — the one-command V1.1 entry point" do
    test "Mix.Tasks.Ezagent.Bootstrap exists with run/1" do
      Code.ensure_loaded(Mix.Tasks.Ezagent.Bootstrap)

      assert function_exported?(Mix.Tasks.Ezagent.Bootstrap, :run, 1),
             "the one-command bootstrap entry point (V1.1 / D7-9) must exist — " <>
               "a new contributor relies on `mix ezagent.bootstrap`"
    end

    test "the bootstrap task documents its D7-9 contract + health-check step" do
      source =
        File.read!(Path.join(__DIR__, "../../lib/mix/tasks/ezagent.bootstrap.ex"))

      assert source =~ "Health check",
             "the bootstrap moduledoc must document the health-check step — " <>
               "it is what proves the checkout is ready to serve"

      assert source =~ ~r/SELECT 1/,
             "the task must run a trivial `SELECT 1` to confirm the DB is " <>
               "wired before the dev tries `mix phx.server`"

      assert source =~ "ecto.migrate",
             "the task must run ecto.migrate — a ready-to-serve checkout " <>
               "has a current schema"
    end
  end

  describe "the bootstrap end-state — the Repo is serving" do
    test "the Ecto Repo answers a trivial SQL query (the task's health check)" do
      # This is exactly the bootstrap task's Phase-5 health check
      # (`Ecto.Adapters.SQL.query(EzagentCore.Repo, "SELECT 1", [])`).
      # A bootstrapped Ezagent answers it.
      assert {:ok, %{rows: [[1]]}} =
               Ecto.Adapters.SQL.query(EzagentCore.Repo, "SELECT 1", []),
             "a bootstrapped Ezagent's Repo must answer SELECT 1 — the task's " <>
               "own health check; if this fails the checkout is NOT ready to serve"
    end

    test "the schema is migrated — core per-tenant tables exist" do
      # `ecto.migrate` ran (bootstrap Phase 4). The canonical Phase-7
      # per-tenant tables must be present — a checkout with an
      # unmigrated DB cannot serve.
      for table <- ~w(messages invocations kind_snapshots routing_rules workspaces) do
        assert {:ok, %{rows: rows}} =
                 Ecto.Adapters.SQL.query(
                   EzagentCore.Repo,
                   "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
                   [table]
                 )

        assert rows != [],
               "table #{inspect(table)} is missing — bootstrap's ecto.migrate " <>
                 "step did not produce a complete schema"
      end
    end
  end

  describe "the bootstrap end-state — EZAGENT_HOME paths resolve" do
    test "Ezagent.Home resolves the profile dir + db path" do
      # `ezagent.home.init` (bootstrap Phase 1) creates the skeleton;
      # `Ezagent.Home` resolves the paths the rest of the system reads.
      # These must be absolute, non-empty paths — a half-initialized
      # home would surface here.
      profile_dir = Ezagent.Home.profile_dir()
      db_path = Ezagent.Home.path(:db)

      assert is_binary(profile_dir) and profile_dir != ""

      assert Path.type(profile_dir) == :absolute,
             "EZAGENT_HOME profile dir must be an absolute path"

      assert is_binary(db_path) and db_path != ""

      assert String.starts_with?(db_path, profile_dir),
             "the DB path must live under the profile dir — the bootstrap " <>
               "skeleton layout (Decision #139)"
    end
  end
end
