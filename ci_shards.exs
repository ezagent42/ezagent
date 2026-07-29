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
#   * `plugin_world` carves the `ezagent_plugin_world` non-e2e suite (heavy
#     PtyServer/erlexec boot) into its OWN leg BEFORE the `plugin` catch-all: a
#     world-boot BEAM crash (OTP-26 erlexec port-EXIT shutdown race) must not be
#     able to truncate the sibling plugin apps that would otherwise share its BEAM.
#   * the `domain_*_lifecycle` legs carve the NODE-GLOBAL-teardown lifecycle tests
#     (whole-app `Application.stop(:ezagent_domain_*)` and the node-global
#     `EzagentCore.EtsOwner` kill) into ONE-AGGRESSOR-PER-LEG isolation BEFORE the
#     `domain` catch-all: these teardowns are self-restoring for the app UNDER
#     test, but poison every OTHER domain app that shares their BEAM (the
#     ~510-failure #189 cascade — `absorb_not_committed`, `no process: *Registry`,
#     ETS ArgumentError) — AND each other, so they cannot share even one carved
#     leg. The `NodeGlobalTeardownIsolationTest` enumerator gate (empty-allowlist)
#     PROVES no such file silently lands outside a `*_lifecycle` leg.
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
    {"actor", ["apps/ezagent_actor/test/"]},
    {"core", ["apps/ezagent_core/test/"]},
    # Isolated ONE-file leg for the tag-excluded real-boot-seed regression: it
    # `regenesis`-es the VM-GLOBAL genesis-admin singleton and spawns a durable
    # SessionTemplate Kind whose async persist escapes the sandbox — corrupting
    # sibling session tests. Carved BEFORE `session` (first-match-wins) so it runs
    # ALONE (own BEAM + DB partition), and `run_shard_tests` passes
    # `--include real_boot_seed_path` so its `@moduletag :real_boot_seed_path`
    # (excluded by default in the session test_helper) actually RUNS here.
    {"session_boot_seed",
     ["apps/ezagent_domain_session/test/integration/stale_admin_pre_epoch_seed_test.exs"]},
    {"session", ["apps/ezagent_domain_session/test/"]},
    {"web", ["apps/ezagent_web/test/", "apps/ezagent_cli/test/"]},
    {"plugin_world", ["apps/ezagent_plugin_world/test/"]},
    {"plugin", ["apps/ezagent_plugin_"]},
    # ONE aggressor per `*_lifecycle` leg — each runs ALONE in its own BEAM. A
    # single combined leg was tried and empirically CROSS-POISONS: provider_
    # connection's application_test kills the node-global EzagentCore.EtsOwner +
    # deletes/restores the shared cap/behavior tables + stops its app, which
    # corrupts the git/workspace boot tests sharing its BEAM (git 3/8, workspace
    # 2/2 red). Splitting per-app removes every same-BEAM neighbour. The
    # `_lifecycle` suffix is load-bearing: `NodeGlobalTeardownIsolationTest`
    # treats every `*_lifecycle` shard as a carved isolation leg.
    {"domain_provider_connection_lifecycle",
     ["apps/ezagent_domain_provider_connection/test/ezagent_domain_provider_connection/application_test.exs"]},
    {"domain_git_lifecycle",
     ["apps/ezagent_domain_git/test/ezagent_domain_git/application_boot_test.exs"]},
    {"domain_workspace_lifecycle",
     ["apps/ezagent_domain_workspace/test/ezagent_domain_workspace/application_boot_test.exs"]},
    {"domain", ["apps/ezagent_domain_"]}
  ]
}
