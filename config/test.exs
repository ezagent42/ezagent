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
  # integration-level concurrency. Bumping to 20 — SQLite handles
  # concurrent readers fine; the limit is per-connection serialization
  # of writes (which sandbox checkouts already serialize per test).
  pool_size: 20,
  pool: Ecto.Adapters.SQL.Sandbox,
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
