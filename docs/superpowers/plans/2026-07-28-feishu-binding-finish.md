# Feishu Binding Finish Implementation Plan

> Execution target: isolated B1/B2/deploy worktrees only. Never modify the
> coordination-only main worktree and never operate the online canary.

**Goal:** Finish the Feishu initial-user-binding path against current main by
connecting B1 to the sanctioned production dispatch seam, aligning B2 to the
current `Cmd`/`Router` boundary, and making deploy PR #8 supply the required
runtime configuration without hardcoding a principal.

**Architecture:** B1 remains a strict parse/preflight/dispatch importer. Its
default production function port delegates to a thin adapter that reads an
operator URI from runtime config, validates that it is the canonical admin
supported by main's reviewed operator seam, creates `Cmd.trusted_internal/5`
commands with a bare workspace target and explicit action, and dispatches
inside `Invocation.with_admin_operator/2`. No capability is constructed, no
raw storage is read or written, and tests may continue to inject a fake port.
B2 uses `Cmd.authenticated_external/5` for presenter-authenticated reads.
Deploy enables the seed only when both the seed file and a separate
operator-URI secret file are present, failing closed otherwise.

**Tech Stack:** Elixir/OTP, ExUnit, Ezagent Cmd/Router/CapBAC, Bash, Docker
Compose.

---

## Task 1: B1 production dispatch adapter

**Files:**
- Modify: `apps/ezagent_plugin_feishu/test/ezagent/plugin_feishu/user_binding_seed/dispatch_adapter_test.exs`
- Modify: `apps/ezagent_plugin_feishu/test/integration/boot_dispatch_feasibility_test.exs`
- Modify: `apps/ezagent_plugin_feishu/test/integration/boot_seed_wiring_test.exs`
- Modify: `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/dispatch_adapter.ex`
- Modify: `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed.ex`
- Modify: `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex`
- Modify: `config/runtime.exs`

1. Replace the placeholder-raises tests with configuration validation tests
   and real synchronous dispatch acceptance tests.
2. Run the focused tests and record the expected RED failures.
3. Implement strict runtime operator parsing and canonical-admin validation.
4. Dispatch `:list_feishu_bindings` and `:bind` through
   `Cmd.trusted_internal/5 |> Router.dispatch/1`, within
   `Invocation.with_admin_operator/2`.
5. Make `UserBindingSeed` use the production adapter by default while
   preserving explicit test-port injection.
6. Parse `EZAGENT_FEISHU_SEED_ENABLED` and
   `EZAGENT_FEISHU_SEED_OPERATOR_URI` in runtime config.
7. Run focused tests until GREEN.

## Task 2: B1 architecture and regression verification

1. Run formatter and the Feishu plugin test suite.
2. Run locality/architecture/URI scanners and regenerate only an officially
   required generated baseline.
3. Run `mix ci.fast`.
4. Run `mix precommit`; report any timeout or environmental failure exactly.
5. Commit the reviewed B1 changes.

## Task 3: Align B2 with current main and rewritten B1

1. Rebase B2 on the new B1 head.
2. Add or update tests requiring `Cmd.authenticated_external/5` and
   `Router.dispatch/1`.
3. Confirm presenter caps are loaded fresh and no direct `%Invocation{}`
   construction remains.
4. Run focused B2 tests, `mix ci.fast`, and `mix precommit`.
5. Commit the B2 alignment.

## Task 4: Update ezagent-deploy PR #8

1. Rebase the PR #8 branch on latest deploy main in an isolated worktree.
2. Add failing tests for the seed/runtime coupling.
3. When the seed YAML is present, require a non-empty operator-URI secret
   file, export `EZAGENT_FEISHU_SEED_ENABLED=1`, and export its value as
   `EZAGENT_FEISHU_SEED_OPERATOR_URI` without logging it.
4. Keep a missing seed fully inert and never include a real principal value.
5. Run all deploy repository checks and commit.

## Task 5: Publish and hand off

1. Review diffs and verify each worktree is clean.
2. Push B1, B2, and deploy PR #8 using exact `--force-with-lease` protection
   only where rebases rewrote history.
3. Remove stale auth-convergence labels only after evidence is green.
4. Report exact heads, checks, residual risks, and merge/deploy order:
   B1 → B2; deploy PR #8 may merge after B1 but must not be deployed against
   an application image that lacks B1.
