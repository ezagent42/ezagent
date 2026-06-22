import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ezagent_core, EzagentCore.Repo,
  database: Path.expand("../ezagent_core_test.db", __DIR__),
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
  pool_size: 20,
  pool: Ecto.Adapters.SQL.Sandbox,
  # #52 Mode-C fix: RAISE busy_timeout above the 2_000 ms ecto_sqlite3
  # default (NOT "add WAL" — WAL + a 2 s busy_timeout are already the
  # adapter defaults and config/test.exs overrides neither). A contending
  # writer now WAITS up to 5 s for the single-writer lock instead of
  # immediately raising `Exqlite.Error: database is locked`. journal_mode
  # is left at the adapter default `:wal`.
  busy_timeout: 5_000,
  # Extend queue timeout for the same reason — under load tests can
  # legitimately wait briefly for a connection.
  queue_target: 1000,
  queue_interval: 5000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ezagent_web, EzagentWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3v32NqyJT1oDLVf9Qcg2pz9caQu68+W737xqtaGSUPsaw6dDqwqXIC8VCQCSGLpy",
  server: false

# Resource-unification P2 — upload download-token signing secret (core-owned
# config key), wired to the same value as the web endpoint's secret_key_base.
config :ezagent_core, Ezagent.Uploads.DownloadToken,
  secret_key_base: "3v32NqyJT1oDLVf9Qcg2pz9caQu68+W737xqtaGSUPsaw6dDqwqXIC8VCQCSGLpy"

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
