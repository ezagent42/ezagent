defmodule EzagentCore.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      package: package(),
      name: "Ezagent",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  # OTP release for prod docker (mix release). An umbrella release only starts
  # the apps listed here (plus their deps) — the plugins are NOT in ezagent_web's
  # dep tree (they're started as sibling apps), so EVERY runnable app must be
  # listed explicitly or it silently won't boot in the release.
  # `ezagent_cli` is task-only → :load (available, not started).
  defp releases do
    [
      ezagent: [
        applications: [
          ezagent_core: :permanent,
          ezagent_domain_identity: :permanent,
          ezagent_domain_workspace: :permanent,
          ezagent_domain_session: :permanent,
          ezagent_domain_socialware: :permanent,
          ezagent_domain_agent_bridge: :permanent,
          ezagent_domain_agent: :permanent,
          ezagent_domain_external_mirror: :permanent,
          ezagent_domain_pty: :permanent,
          ezagent_domain_python: :permanent,
          ezagent_domain_ui: :permanent,
          ezagent_plugin_cc: :permanent,
          ezagent_plugin_codex: :permanent,
          ezagent_plugin_curl_agent: :permanent,
          ezagent_plugin_email: :permanent,
          ezagent_plugin_py: :permanent,
          ezagent_plugin_feishu: :permanent,
          ezagent_plugin_github: :permanent,
          ezagent_plugin_world: :permanent,
          ezagent_plugin_hello: :permanent,
          ezagent_plugin_protocol_api: :permanent,
          ezagent_plugin_kb: :permanent,
          ezagent_web: :permanent,
          ezagent_cli: :load
        ],
        include_executables_for: [:unix]
      ]
    ]
  end

  def cli do
    [
      # `ci.fast` / `gate.arch` boot the app + hit the test DB (check_invariants,
      # socialware.check, the arch/invariant ExUnit subset), so they MUST run in
      # `:test` — auto-select it so a dev/agent can just `mix ci.fast` without
      # remembering `MIX_ENV=test` (the CI `gate` job sets `MIX_ENV=test` itself).
      preferred_envs: [precommit: :test, "ci.fast": :test, "gate.arch": :test]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # Generates browsable HTML API docs from the apps' @moduledocs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Configures `mix docs` (ExDoc). Run from the umbrella root to aggregate
  # every child app's modules into a single browsable doc/ tree.
  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "ARCHITECTURE.md",
        "GLOSSARY.md",
        "IMPLEMENTATION_ROADMAP.md",
        "docs/notes/README.md": [title: "Forensic Notes Index"]
      ],
      groups_for_extras: [
        Project: ["README.md", "ARCHITECTURE.md", "GLOSSARY.md", "IMPLEMENTATION_ROADMAP.md"],
        Notes: ["docs/notes/README.md"]
      ],
      source_url: "https://github.com/ezagent42/esr-ng"
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # #1476-followup — the deterministic arch/invariant ExUnit subset the CI `gate`
  # job runs (via `docker/ci-runner.sh` `gate)`, which the `.github/workflows/ci.yml`
  # `gate` job invokes in a container). SINGLE SOURCE OF TRUTH: both the `gate.arch`
  # alias below AND that `docker/ci-runner.sh` step invoke `mix gate.arch`, so this
  # path list can never drift between the local fast gate and CI.
  # Path-scoped from the umbrella root: `mix test <paths>` RECURSES into every
  # umbrella child, and each child silently skips the dirs it does not own — so
  # this runs exactly the arch/invariant tests across all apps. These are the
  # deterministic, never-flaky gates (arch scans, invariant tests) that catch the
  # class of red-test-slipped-to-review a killed 120s full-suite run misses.
  @arch_invariant_test_paths [
    "apps/ezagent_core/test/architecture",
    "apps/ezagent_core/test/invariants",
    "apps/ezagent_domain_external_mirror/test/invariants",
    "apps/ezagent_domain_identity/test/invariants",
    "apps/ezagent_domain_session/test/invariants"
  ]

  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      # FF-3 (cleanup-4) — the compiler dead-code gate. `--warnings-as-errors`
      # is the ONLY reliable detector of unused private functions + unreachable
      # / mis-grouped clauses (the cleanup audit proved grep-based dead-code
      # detection is ~100% false-positive for this class). `--force` makes the
      # gate sound: an incremental compile silently skips unchanged modules, so
      # a warning re-introduced in an otherwise-untouched file would slip past.
      # Mirrored by the architecture test
      # `compiler_dead_code_gate_test.exs`. Keep these flags in sync.
      precommit: [
        "compile --warnings-as-errors --force",
        "deps.unlock --unused",
        "format",
        "test",
        # cc-headless SDK worker pure-helper suite (stdlib-only, no SDK needed) —
        # codex review of PR #1452 flagged it was not wired into any gate. Run as
        # an alias FUNCTION step (NOT `cmd`): `mix cmd` is `@recursive true`, so a
        # `cmd`-based invocation runs once per child app with cwd=that child, and a
        # root-relative path (`apps/ezagent_plugin_cc/priv/python/...`) fails to
        # resolve there — `python -m unittest` then degrades the unresolved path
        # into a bogus dotted module name and dies with `ModuleNotFoundError: No
        # module named 'apps/ezagent_plugin_cc/priv/python/test_ezagent_cc_sdk_worker'`.
        # Same recursion trap documented for `mix cmd --cd` above. See
        # `run_cc_sdk_worker_tests/1`.
        &run_cc_sdk_worker_tests/1
      ],
      # #108 — `mix ci.local` mirrors the CI `precommit + check_invariants` job
      # (`.github/workflows/ci.yml`) END-TO-END against a PRIVATE partitioned
      # test DB, so a dev can pre-push-verify the EXACT gate CI runs instead of a
      # single-app `mix test` (which silently excludes `:umbrella_only`
      # cross-tier suites and never hits the full-umbrella concurrency where the
      # recurring flake surfaces). Run it as:
      #
      #     MIX_ENV=test MIX_TEST_PARTITION=$USER mix ci.local
      #
      # `MIX_TEST_PARTITION=$USER` → private DB `ezagent_pg_compat_test$USER`;
      # two devs run concurrently and nobody touches the shared dev DB.
      #
      # Step ORDER mirrors CI and is load-bearing: `pnpm install` populates
      # node_modules BEFORE `precommit`'s `mix compile`, because the assets
      # esbuild build (triggered during the web app's `mix test`) must resolve
      # react/zod — without it the run dies with `Could not resolve "react"`, a
      # NON-test failure that otherwise masquerades as a green-with-EXIT=1 run.
      "ci.local": [
        &arm_ci_local_result_capture/1,
        "deps.get",
        # `mix cmd --cd <relative>` RECURSES into every umbrella child (Mix marks
        # `cmd` recursive), so the relative `--cd` is resolved against each
        # child app's cwd and dies with `spawn: Could not cd to
        # apps/ezagent_web/assets` on the first child (Mix 1.19
        # `run_in_children_projects` → `File.cd!/2`). A plain alias FUNCTION step
        # runs ONCE from the umbrella root, so pnpm install lands in each assets
        # dir exactly once. See `pnpm_install_assets/1`.
        &pnpm_install_assets/1,
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "precommit",
        "ezagent.check_invariants",
        "ezagent.uri_query.scan",
        # Gate-parity: the ci.yml `gate` job runs `mix world.e2e.fixtures --check`
        # (asserts the committed world E2E fixtures still match the generator), but
        # `ci.local` did NOT — so a local pre-push `ci.local` + the main full-suite
        # both MISSED world-fixture drift that only the PR `gate` would catch. Add it
        # here so `ci.local` is a true SUPERSET of the gate. Deterministic; the code
        # is already compiled by `precommit` above. Raises (non-zero) on drift.
        "world.e2e.fixtures --check",
        # T2-3 — socialware Definition conformance gate. It queries the
        # ConfigStore (DB), so it CANNOT run in this same BEAM right after `test`:
        # `mix test` leaves the Ecto SQL Sandbox in `:manual` mode, and this mix
        # task's process owns no checked-out connection → `DBConnection.Ownership
        # Error`. Run it in a FRESH `mix` process (a clean BEAM with a normal
        # pool) — the same way the CI `gate` job runs it standalone-green. See
        # `run_socialware_check/1`.
        &run_socialware_check/1,
        # FINAL step — deterministic exit. Reaching here means every gate above
        # passed (each raises on failure). The app kept real OS subprocesses
        # alive during `test` (erlexec-backed PtyServers, python ports, sidecars);
        # on graceful VM shutdown these are reaped ASYNCHRONOUSLY and an erlexec
        # port that EXITs mid-teardown (a known OTP-26-era race, erlexec 2.3.0)
        # pollutes the VM exit code to 2 even with 0 test failures — a flake that
        # reddens main and blocks the canary deploy. The exit code must reflect
        # the CHECK RESULTS, not shutdown timing, so we halt(0) explicitly. New
        # gates MUST be added ABOVE this step — anything after halt/0 never runs.
        &finalize_ci_local/1
      ],
      # #1476-followup — `mix gate.arch` runs ONLY the deterministic arch/invariant
      # ExUnit subset (`@arch_invariant_test_paths`). It is the SINGLE source the CI
      # gate (`docker/ci-runner.sh` `gate)`) invokes as `mix gate.arch`, so the path
      # list lives in exactly one place and CI + the alias can never drift. Not for
      # direct dev use — use `mix ci.fast`.
      "gate.arch": ["test " <> Enum.join(@arch_invariant_test_paths, " ")],
      # #1476-followup — `mix ci.fast` is the FAST local gate: the exact
      # deterministic subset the CI `gate` job runs (check_invariants +
      # socialware.check + the arch/invariant ExUnit subset), and NOTHING else. It
      # finishes in ~1-2 min (vs the SLOW full `ci.local`/full-suite's 500s+), so an
      # agent can ALWAYS run it locally before pushing instead of leaning on CI —
      # closing the gap where a red arch test slipped to review because the full
      # suite was killed at the default ~120s bash-tool timeout before the
      # arch/invariant tests ran. It catches THAT class of failure (never-flaky arch
      # scans + invariant gates); the SLOW full `ci.local`/`precommit` stays the
      # pre-push / push-to-main gate. Run it as:
      #
      #     mix ci.fast                              # auto MIX_ENV=test (cli/0)
      #     MIX_TEST_PARTITION=$USER mix ci.fast     # private DB, concurrent-safe
      #
      # ecto.create/migrate up front make it self-contained from a cold test DB;
      # socialware.check runs in a FRESH `mix` process (`run_socialware_check/1`)
      # for the same SQL-Sandbox reason as `ci.local`. check_invariants + socialware
      # run BEFORE the ~90s test subset so a violation fails fast.
      "ci.fast": [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "ezagent.check_invariants",
        &run_socialware_check/1,
        "gate.arch"
      ]
    ]
  end

  # The three JS-asset dirs whose node_modules must exist before `precommit`'s
  # `mix compile` (esbuild resolves react/zod from them). Kept in sync with the
  # `.github/workflows/ci.yml` full-suite "Install JS deps" step.
  @assets_dirs [
    "apps/ezagent_web/assets",
    "apps/ezagent_plugin_world/assets",
    "apps/ezagent_plugin_hello/assets"
  ]

  # `pnpm install` in each assets dir, run ONCE from the umbrella root (an alias
  # function step does not recurse into child projects the way `mix cmd` does).
  # Fails LOUD on a non-zero pnpm exit so a broken install cannot masquerade as a
  # green run.
  defp pnpm_install_assets(_args) do
    Enum.each(@assets_dirs, fn dir ->
      {_out, status} =
        System.cmd("pnpm", ["install", "--no-frozen-lockfile"],
          cd: dir,
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      if status != 0 do
        Mix.raise("pnpm install failed in #{dir} (exit status #{status})")
      end
    end)
  end

  # The cc-headless SDK worker's pure-helper unittest suite, run ONCE from the
  # umbrella root (an alias function step does not recurse into child projects
  # the way `mix cmd` does — see the `precommit` note). `python -m unittest` wants
  # a DOTTED module name resolved from cwd, NOT a path, so we `cd:` into the
  # script dir (anchored to this mix.exs via `__DIR__`, not the caller's cwd) and
  # pass the bare module `test_ezagent_cc_sdk_worker`. `uv run --no-project` gives
  # a stdlib-only interpreter (the worker guards its `claude_agent_sdk` import, so
  # no SDK is needed). Fails LOUD on a non-zero exit so a broken suite cannot
  # masquerade as a green run.
  defp run_cc_sdk_worker_tests(_args) do
    py_dir = Path.expand("apps/ezagent_plugin_cc/priv/python", __DIR__)

    {_out, status} =
      System.cmd(
        "uv",
        ["run", "--no-project", "python", "-m", "unittest", "test_ezagent_cc_sdk_worker"],
        cd: py_dir,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("cc-headless SDK worker unittest suite failed (exit status #{status})")
    end
  end

  # `mix ezagent.socialware.check` in a FRESH `mix` process. It must not run in
  # the `ci.local` BEAM after `test`, because `mix test` leaves the Ecto SQL
  # Sandbox in `:manual` mode and the task's DB query (ConfigStore.resolve) then
  # dies with `DBConnection.OwnershipError` (no ownership for the task process).
  # A child `mix` boots a clean app with a normal pool — identical to how the CI
  # `gate` job runs it green as its own step. Inherits MIX_ENV/MIX_TEST_PARTITION
  # from the environment, so it hits the same test DB `ecto.create` already made.
  defp run_socialware_check(_args) do
    {_out, status} =
      System.cmd("mix", ["ezagent.socialware.check"],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("ezagent.socialware.check failed (exit status #{status})")
    end
  end

  # ci.local honesty capture — see EzagentCore.CiLocalResult + finalize_ci_local/1.
  # Runs BEFORE `precommit`'s recursive `test` so every umbrella child's
  # ExUnit.start/1 (same BEAM) inherits the `:after_suite` hook. Empirically
  # validated: a pre-set `:ex_unit`/`:after_suite` app env fires ONLY after
  # `ensure_loaded/1`. The remote capture is load-safe before the app compiles.
  defp arm_ci_local_result_capture(_args) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ezagent_ci_local_result.#{System.get_env("MIX_TEST_PARTITION", "")}.sentinel"
      )

    System.put_env("EZAGENT_CI_LOCAL_SENTINEL", path)
    File.rm_rf!(path)

    Application.ensure_loaded(:ex_unit)
    existing = Application.get_env(:ex_unit, :after_suite, [])

    Application.put_env(
      :ex_unit,
      :after_suite,
      [(&EzagentCore.CiLocalResult.record_result/1) | existing]
    )

    :ok
  end

  # Deterministic exit for `mix ci.local` — see the `&finalize_ci_local/1` note
  # in the alias. Every gate above raises on failure, so reaching here == all
  # green. `halt(0)` exits IMMEDIATELY, skipping the graceful app shutdown that
  # reaps erlexec-backed OS-process ports asynchronously — that shutdown is
  # exactly what pollutes the exit code to 2 (OTP-26-era erlexec port EXIT race)
  # despite 0 test failures. Skipping it makes the code reflect the CHECK
  # results, not shutdown timing. (We deliberately do NOT `Application.stop/1`
  # first: it is synchronous and could itself hang on a wedged port, and halt/0
  # already prevents the racy teardown by never running it. CI tears down PG +
  # the container afterward, so leaked child PIDs are reaped by the runner.)
  defp finalize_ci_local(_args) do
    if EzagentCore.CiLocalResult.failed?() do
      IO.puts("✗ ci.local: mix test reported failures (scroll up for the ExUnit output) — exit 1")
      System.halt(1)
    else
      IO.puts("✓ ci.local: all gates passed — deterministic exit 0")
      System.halt(0)
    end
  end
end
