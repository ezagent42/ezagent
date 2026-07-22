# Single source of truth for the CI full-suite SHARD split.
#
# Consumers (ALL read THIS file so they can never drift):
#   * `EzagentCore.CiShards`             — bakes these rules at compile time and
#                                          assigns every test file to a shard.
#   * `mix.exs` `aliases/0`              — generates one `mix ci.shard.<name>`
#                                          alias per test shard from the names here.
#   * `.github/workflows/ci.yml`         — the full-suite matrix legs (`matrix.shard`).
#   * `mix ci.shard.verify` + the arch   — PROVE the union of shards == the monolith.
#     `ci_shard_parity_test.exs`
#
# Assignment (see `EzagentCore.CiShards.assign/1`): a test file's umbrella-root-
# relative path (e.g. "apps/ezagent_core/test/ezagent/foo_test.exs") is assigned to
# the FIRST shard below whose ANY pattern is a SUBSTRING of the path
# (first-match-wins). Ordering is load-bearing:
#
#   * `e2e` is FIRST so every app's `test/e2e/**` is carved into the one cross-
#     cutting e2e shard regardless of which app owns it — this is where the slow /
#     flaky E2E suites (incl. the known-red `EzagentPluginKb.E2E.AutoserviceTier1
#     SeedTest`) isolate, re-runnable ALONE.
#   * `core` / `session` / `web` name the specific heavy apps.
#   * the catch-all `plugin` / `domain` (bare `apps/ezagent_plugin_` /
#     `apps/ezagent_domain_`) auto-absorb NEW plugin/domain apps — so adding a
#     plugin does NOT need a manifest edit, its non-e2e tests just land in `plugin`.
#
# A brand-new top-level app that matches NO rule (e.g. `apps/ezagent_edge/...`) is
# left UNASSIGNED, which `mix ci.shard.verify` + the `ci_shard_parity_test` arch
# gate HARD-FAIL on (empty-allowlist enumerator) — forcing an explicit shard
# decision instead of silently dropping its tests from the full-suite.
#
# NOTE: this only splits the *test* step. The deterministic non-test gates
# (compile --warnings-as-errors --force, deps.unlock, format, check_invariants,
# uri_query.scan, world.e2e.fixtures, cc-sdk python, socialware.check) run ONCE in
# the separate `ci.shard.static` shard (defined in mix.exs, not here).
%{
  test_shards: [
    {"e2e", ["/test/e2e/"]},
    {"core", ["apps/ezagent_core/test/"]},
    {"session", ["apps/ezagent_domain_session/test/"]},
    {"web", ["apps/ezagent_web/test/", "apps/ezagent_cli/test/"]},
    {"plugin", ["apps/ezagent_plugin_"]},
    {"domain", ["apps/ezagent_domain_"]}
  ]
}
