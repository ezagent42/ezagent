# Task 2 Report — Anti-stub regression gate (agent_create_appears_in_list)

## Status: DONE

## What was done

Created `apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs`.

The test contains two test cases:

**Test 1 (`@tag :integration`):** Creates a `curl`-flavor agent via `Ezagent.Workspace.create_agent/3`, then asserts its URI appears in `IdentityData.list_entities(workspace_uri, "agents")`. Also asserts the row shape, workspace isolation (not visible under a different workspace), and filter correctness (not visible under `"users"`).

**Test 2:** Asserts `cc` + empty `cwd` returns `{:error, :cwd_required_for_cc}` — the server-side guard is real, not a silent success.

## Interface verification findings

- `list_entities/2` uses `KindRegistry.list_all()` (live processes) — NOT a DB query. A stub that returned `{:ok, _}` without spawning the agent would be absent from the list, making this a true structural gate.
- Return map key is `"uri"` (string-keyed) — confirmed at line 191 of `identity_data.ex`.
- `create_agent/3` signature confirmed: `(workspace_uri, args_map, ctx_map)`.
- `cwd_required_for_cc` error confirmed in `agent_create.ex`.

## Flavor selection rationale

The brief said "flavor `echo`" but `echo` requires the `echo.agent` Template Class from `ezagent_plugin_echo`, which is NOT a dependency of `ezagent_plugin_world`. Using `echo` would cause `{:error, {:no_template_class, "echo.agent"}}`. Used `curl` instead (direct-spawn, no template class, no cwd required) — the same flavor used for happy-path integration tests in `create_agent_dispatch_test.exs`. The gate property is flavor-independent.

## Test command and output

```
POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs --seed 0

Running ExUnit with seed: 0, max_cases: 48

..
Finished in 0.1 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
```

## Files touched

- `apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs` (created)
- `.superpowers/sdd/task-2-report.md` (this file)

No production code modified.

## Concerns

None. The `EzagentCore.DataCase` sandbox works in the world plugin test suite because `Ecto.Adapters.SQL.Sandbox` starts in `:manual` mode by default when configured as the pool in `config/test.exs`. The world plugin's `test_helper.exs` does not call `Sandbox.mode/2` explicitly but this is not required.

---

## Review-finding fixes (2026-06-24)

Three review findings resolved in the same file:

### Finding 1 (Important) — Silent-pass skip-guard removed

**Before:** Lines 50-53 wrapped the entire test body in `if not …registered_schemes… do IO.puts(:stderr, …); :ok end`. When the entity scheme was absent, ExUnit received `:ok` from the test function — recorded as a PASSING test, so the anti-stub gate was silent.

**After:** The bootstrap (`Application.ensure_all_started(:ezagent_domain_session)` + resolver registration) moved to `setup`, followed by:
```elixir
assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
       "entity spawn scheme not registered after starting :ezagent_domain_session — ..."
```
If the scheme is absent after starting the domain app, this is a loud failure in `setup` — no test body runs, ExUnit reports an error (not a pass), which is the correct behavior for a broken environment.

### Finding 2 (Minor) — Static agent name in cwd-error test made unique

**Before:** `name: "no-cwd-probe"` (hardcoded, collision-prone under parallel runs).

**After:** `name: "no-cwd-probe-#{System.unique_integer([:positive])}"` — consistent with the happy-path test's uniqueness pattern.

### Finding 3 (Minor) — Double `list_entities` call deduplicated

**Before:** Lines 72 and 82 both called `IdentityData.list_entities(workspace_uri, "agents")` separately — two scans of `KindRegistry.list_all()`.

**After:** Called once in the integration test, bound to `agent_rows`, reused for both the URI membership assertion and the `Enum.find/2` row-shape check.

### Test command and output

```
POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs

Running ExUnit with seed: 215088, max_cases: 48

..
Finished in 0.1 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
```

Also run with `--include integration` to confirm the `@tag :integration` test body executed:

```
POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs --include integration

Running ExUnit with seed: 220788, max_cases: 48
Including tags: [:integration]

..
Finished in 0.1 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
```

Both passes confirm the assertions ran (setup hard-assert would have failed if `entity` scheme was absent; `Workspace.create_agent` + `IdentityData.list_entities` assertions ran inside the test body).
