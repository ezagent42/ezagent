# Agent Console Route-Level Tests Return

> returned_at: 2026-07-02
> deadline: 2026-07-02 EOD
> deadline_status: on_time
> branch: `work/agent-console-route-tests-0702`

## Summary

Added web LiveView route-level coverage for the shipped Agent Console surfaces in
`apps/ezagent_web/test/ezagent_web/world_agent_console_routes_test.exs`.

## Tests Added

- `/identities/agents` mounts the real World LiveView `agents_table` route and
  sends current-workspace agent list state to the React island.
- `/identities/agents/new` mounts `agent_new_form` and exposes dynamic flavor
  schemas, script-required flavor metadata, cwd policy, and nil create error.
- `/identities/agents/:uri` and `/identities/agents/:uri/config` mount detail and
  config states for a real curl agent, including config fields, granted caps,
  config path, and config schema.
- Bound-agent delete failure through `world:dispatch` remains on the agent detail
  route and pushes an operator-visible `action_error`.

## Bugs Found

No product-code bug found. One test helper expectation was adjusted during the
red/green pass because `session.join` currently returns `{:ok, %{members: ...}}`,
not only `:ok` / `{:ok, :joined}`.

## Verification

Commands run from `.worktrees/agent-console-route-tests-0702`:

```bash
SHELL=/bin/bash mix test apps/ezagent_web/test/ezagent_web/world_agent_console_routes_test.exs
SHELL=/bin/bash mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs
node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs
```

Results:

- `world_agent_console_routes_test.exs`: 4 tests, 0 failures
- `routes_test.exs`: 10 tests, 0 failures
- `world_ui_structure_test.mjs`: all assertions passed

Additional gate attempted:

```bash
SHELL=/bin/bash mix precommit
```

Result:

- First run failed while starting `ezagent_plugin_world`: `identity.grant_cap`
  bootstrap dispatch timed out and Phoenix Tracker shutdown reported a missing
  ETS table.
- Second run completed the umbrella test sweep but exited 2 because
  `ezagent_core` architecture scan tests hit 13 timeouts in
  `Mix.Tasks.Ezagent.Arch.Scan` / `EzagentCore.ArchitectureCase`. The timed-out
  tests include `CcBridgeShimTest`, `ManifestRatchetTest`,
  `SpawnChokepointTest`, `RawPortSpawnTest`, `CrossFileDuplicateFnTest`,
  `HardcodedDeployDomainTest`, `RespawnRoundTripTest`,
  `ResourceKindAsGenserverTest`, `OversizedModulesTest`,
  `DuplicatedResolutionTest`, `EffectDisciplineTest`, `RuntimeOrderingTest`,
  and `RawHomePathTest`.
- Subsequent app suites after `ezagent_core` completed with 0 failures,
  including `ezagent_plugin_world`, `ezagent_web`, and `ezagent_cli`.

## Notes

The new worktree needed local setup before tests could run:

- `mix deps.get`
- `pnpm install` in `apps/ezagent_web/assets`
- `pnpm install` in `apps/ezagent_plugin_world/assets`

`SHELL=/bin/bash` is required in this worktree for `erlexec` startup during Mix
test runs.
