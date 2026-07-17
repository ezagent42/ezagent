import Config

config :ezagent_domain_identity, Ezagent.Entity.Token,
  current_version: 1,
  peppers: %{1 => "test-only-pat-pepper-v1-32-bytes-minimum"}

# Phase-4 capability signing uses a deterministic test-only seed. Production
# continues to require `EZAGENT_SIGNING_SEED_V<N>` through the runtime provider.
config :ezagent_core, Ezagent.Cap,
  signing: [
    seed_provider: fn
      1 -> {:ok, "0123456789abcdef0123456789abcdef"}
      _version -> {:error, :missing_test_seed}
    end,
    active_key_version: 1,
    require_signature: false
  ]

# Keep TEST host routing aligned with local development: world routes are still
# scoped to world.localhost/world.* unless a test deliberately overrides it.
config :ezagent_web, :world_host_scope, "world."

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ezagent_core, EzagentCore.Repo,
  username: System.get_env("POSTGRES_USER", "ezagent_pg_compat"),
  password: System.get_env("POSTGRES_PASSWORD", "ezagent_pg_compat"),
  hostname: System.get_env("POSTGRES_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "55432")),
  database: "ezagent_pg_compat_test#{System.get_env("MIX_TEST_PARTITION")}",
  priv: "priv/repo_pg",
  # Phase 9 (Allen 2026-05-21): integration tests that exercise the
  # full dispatch pipeline now hit the Repo from:
  #   - test-process sandbox checkout
  #   - Audit.Writer GenServer (per-invocation audit row)
  #   - Step 5.6 cap-loading (Identity slice read)
  #   - PR-6 per-tenant write paths (messages, kind_snapshots)
  # Pool of 5 was enough for unit-level tests but exhausts under
  # integration-level concurrency. Bumped to 20 and KEPT at 20.
  #
  # #52 Mode-C NOTE: the design proposed trimming the pool 20→~10 "(measure)"
  # to cut connect-time write-lock contention. MEASURED: the reduction
  # REGRESSES heavier suites — the `ezagent_domain_session` suite
  # (many concurrent globally-supervised Kinds, each `start_owner_stable!`
  # checking out one connection) STARVES at pool_size 15 (`DBConnection`
  # `:queue_timeout` after ~10 s in `start_owner_stable!`), and the
  # boot-time `Workspace.create_session` seed deadlocks at 12. So the pool
  # stays at 20. The real Mode-C levers are (a) removing the Mode-B
  # boot-writer (gating `system://routing/default`'s boot-spawn out of
  # `:test`, which deletes the unsynchronized boot-time `kind_snapshots`
  # writer) and (b) the raised `busy_timeout` below — NOT a smaller pool.
  #
  # 20→40 (CapBAC transient-identity-read fix, belt-and-suspenders): the
  #   fire-and-forget delivery/materialization Tasks (#1339 drains them in
  #   teardown but they pressure the pool DURING the run) can starve the pool
  #   enough that a live identity Kind's `get_slice` call queues behind its own
  #   blocked DB work — the TRANSIENT read the correctness fix now handles
  #   fail-loud (`Ezagent.Kind.default_holds_cap?/2`). A subagent measured a
  #   failing WorldConversationTest seed going 3→0 at 20→60; 40 is a conservative
  #   headroom bump that stays well under connection limits (RAISING the pool is
  #   safe — only LOWERING regressed the heavier suites above). This is SECONDARY:
  #   the correctness fix is the actual fix (a transient never becomes a silent
  #   `:unauthorized`); this just reduces how often the retry path is hit.
  pool_size: 40,
  pool: Ecto.Adapters.SQL.Sandbox,
  # Extend queue timeout — under load tests can legitimately wait briefly for a
  # connection.
  queue_target: 1000,
  queue_interval: 5000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ezagent_web, EzagentWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3v32NqyJT1oDLVf9Qcg2pz9caQu68+W737xqtaGSUPsaw6dDqwqXIC8VCQCSGLpy",
  server: System.get_env("PHX_SERVER") == "true"

# Resource-unification P2 — upload download-token signing secret (core-owned
# config key), wired to the same value as the web endpoint's secret_key_base.
config :ezagent_core, Ezagent.Uploads.DownloadToken,
  secret_key_base: "3v32NqyJT1oDLVf9Qcg2pz9caQu68+W737xqtaGSUPsaw6dDqwqXIC8VCQCSGLpy"

# cc-deepseek credential (#1324): the orchestrator flavor's ONLY credential is
# the DEEPSEEK_API_KEY env var (no OAuth, no `.credentials.json`). Its
# credential pre-check (`Provider.ensure_api_key/1` at `instantiate/3`) runs in
# EVERY env — it is NOT test-stubbed — so keyless CI cannot materialize the
# orchestrator and the socialware-install lane skips it. A clearly-fake DUMMY
# key satisfies that pre-flight check WITHOUT ever reaching the network: in
# `:test` the real `claude` subprocess is short-circuited
# (`SpawnPlan.build_pty_params_for_env(_, _, _, :test)` returns `test_mode:
# true`, so `build_claude_cmd/3` — which would embed the key — is never called,
# and `PtyServer.handle_continue(:spawn_pty, %{test_mode: true})` never runs
# `:exec.run`). Preserve a real ambient key if the operator set one.
System.put_env(
  "DEEPSEEK_API_KEY",
  System.get_env("DEEPSEEK_API_KEY") || "sk-test-dummy-deepseek-not-a-real-key"
)

# Print only warnings and errors during test
config :logger, level: :warning

# Test env: keep error page debug section hidden so tests can assert
# clean "Something went wrong" without internal details.
config :ezagent_web, :show_error_debug, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Readiness-await bound for Kind.spawn (remediation SPEC 2026-05-30 C-A).
# Prod default is 500ms; the ExUnit sandbox / DBConnection checkout can
# stretch a Kind post-init/activate well past that, so give tests headroom.
config :ezagent_core, :spawn_await_ready_ms, 5_000

# task #87 — email transport in test uses the in-memory Local adapter so
# confirmation/reset emails work without any SMTP config. The Mailer treats
# the Local adapter as unconditionally "ready" (see EzagentWeb.Mailer).
config :ezagent_web, EzagentWeb.Mailer, adapter: Swoosh.Adapters.Local
config :ezagent_plugin_email, Ezagent.Email.Mailer, adapter: Swoosh.Adapters.Test

# task #87 — tests use no cookie domain (host-bound session cookie).
config :ezagent_web, :session_cookie_domain, nil

# Manifest deploy-seed scan is a dev/prod boot lane. Tests exercise it directly
# with temp priv dirs so boot remains deterministic.
config :ezagent_domain_session, :socialware_manifest_boot_scan, false

# PTY supervisor intensity — TEST ONLY (2026-07-13).
#
# The respawn-breaker suites drive REAL crash-looping children through the REAL
# app supervisor (that frozen-child-spec replay is the whole point — a private
# supervisor would not exercise it). Each halt costs `max_failures` restarts, and
# a handful of such tests in one 60 s window blows past the production ceiling of
# 20, at which point OTP tears the subtree down and every LATER test finds a
# supervisor that no longer restarts anything — a failure that looks like a
# breaker bug and is not.
#
# Production keeps its bounded 20/60 s (a real crash-loop MUST still escalate);
# tests get headroom so the suite measures the breaker, not OTP's ceiling.
config :ezagent_domain_pty,
  supervisor_max_restarts: 1_000,
  supervisor_max_seconds: 1
