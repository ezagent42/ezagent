# cc agent creation failure resolution

Date: 2026-06-29
Branch: `fix/cc-agent-create-autoservice`

## Problem

AutoService seed attempted to create the live cc orchestrator agent through the generic workspace path:

```elixir
Workspace.create_agent(workspace_uri, %{flavor: "cc", role: "orchestrator", ...}, admin_ctx)
```

That path failed with:

```elixir
{:role_unsupported_for_flavor, "cc"}
```

## Cause

The failure is expected under the current design.

`Workspace.create_agent/3` is the generic agent creation path. File-backed flavors such as `cc` intentionally do not support `role: "orchestrator"` there. The cc orchestrator must be materialized through the orchestrator AgentTemplate path used by session-create.

After switching to the template path, a second issue appeared: bridge-backed cc agents keep public `ReadyGate` as `:not_ready` until their external transport bridge joins. The old cc materialization path spawned the Agent Kind first, then tried to record the sandbox config through a post-spawn `sandbox.write_path` dispatch. That dispatch is a normal public `:call`, so it waited on public readiness and could time out before the bridge joined.

The sandbox config directory is not transport state. It is Agent creation state: `Ezagent.Behavior.Sandbox.create/1` already accepts `config_dir_path`, `template_class`, and `respawn_template_data` from Kind spawn args. The fix is to use that existing creation contract instead of adding a core dispatch bypass.

## Decision

Do not add `dispatch_registered_local/1` or any other local-dispatch exception.

Instead:

- rename `sandbox.write_path` to `sandbox.update_config`, because the action updates sandbox slice metadata rather than writing a filesystem path;
- pass sandbox config into the Agent Kind at create time so `Sandbox.create/1` initializes the durable slice;
- keep the post-spawn `sandbox.update_config` dispatch only as a fallback for Template Classes that do not initialize sandbox in spawn args;
- keep grant/revoke on the normal `Ezagent.Identity.Grant` chokepoint and normal dispatch path.

## Flavor Scope

The original failure is not a cc-only rule. `cc`, `cc-headless`, `codex`, and
`codex-remote` are all file-backed flavors for the generic role-create gate:

```elixir
@file_flavors ~w(cc cc-headless echo codex codex-remote)
```

Therefore all of these fail if an operator tries to create an orchestrator via
the direct generic role path:

```elixir
Workspace.create_agent(workspace_uri, %{flavor: flavor, role: "orchestrator", ...}, ctx)
```

The correct path for file-flavor orchestrators is template materialization:

```text
template://system/agent/<flavor-orchestrator>
  -> Ezagent.Entity.Agent.spawn_from_template_content/5
```

The reason Codex did not hit the same AutoService failure earlier is that the
Codex orchestrator seed only writes the `codex-orchestrator` AgentTemplate. It
does not require a live `entity://.../agent/...` orchestrator to be materialized
during seed. AutoService has the stronger requirement: after seed,
`entity://autosvc/agent/autoservice` must exist and later `session.send` must be
able to route into the agent answer-loop.

The ReadyGate issue applies by transport class, not by name:

| flavor | Generic `role` create | transport class | ReadyGate/bridge materialization risk |
| --- | --- | --- | --- |
| `cc` | rejected | `:subprocess_ws` | yes; this is the bug fixed here |
| `codex` | rejected | `:subprocess_ws` | yes if a live agent is materialized before bridge join |
| `codex-remote` | rejected | `:subprocess_ws` | yes; same class as codex with remote topic/sidecar |
| `cc-headless` | rejected | `:in_process_sync` | not the same bridge-join risk; main risks are SDK sidecar/auth/result persistence |

`cc-headless` and `codex-remote` are therefore not equivalent. `cc-headless`
uses an in-process synchronous SDK sidecar and persists the returned result via
`Ezagent.Behavior.CcHeadlessAgent`. `codex-remote` delegates to the Codex bridge
adapter, uses an `agent_bridge:codex-remote:<agent_uri>` topic, and replies
asynchronously through the external bridge. Both are file-flavors and must avoid
generic role create, but bridge-backed flavors are where post-spawn public
dispatch is most likely to race transport readiness. Their creation-time
sandbox config must not depend on external transport readiness.

## Implemented Changes

1. `scripts/autoservice_tier1_seed.exs`

   For `flavor == "cc"` and `role == "orchestrator"`, AutoService no longer calls generic `Workspace.create_agent/3`. It reads `template://system/agent/cc-orchestrator`, overrides cwd/role, and calls `Ezagent.Entity.Agent.spawn_from_template_content/5`.

2. `apps/ezagent_core/lib/ezagent/invocation.ex`

   The attempted `Ezagent.Invocation.dispatch_registered_local/1` seam was removed. Core dispatch remains unchanged.

3. `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`

   `record_sandbox_state/3` now first checks whether the worker's live sandbox slice already matches the returned template meta. If it matches, it skips the fallback dispatch. If it does not match, it performs a normal `Invocation.dispatch/1` to `sandbox.update_config`.

4. `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`

   Reverted the local-dispatch branch. `Identity.Grant` remains the only grant/revoke dispatch construction chokepoint and uses normal `Invocation.dispatch/1`.

5. `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`

   `load_orchestrator_caps/1` reads durable delegated caps via `Ezagent.Identity.read_entity_caps/1`, avoiding public ReadyGate-gated `Identity.list_caps_for/1` for bridge-backed orchestrators.

6. `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex`

   `CcAgent` now spawns the Agent Kind directly with sandbox init args: `config_dir_path`, `template_class`, and `respawn_template_data`. The config directory is still materialized only after the caller wins the atomic `:started` branch, preserving the existing "loser does not touch config dir" concurrency invariant.

7. `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex`

   Renamed the action and cap subject from `:write_path` to `:update_config`.

## Verification

Commands run:

```bash
MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps mix format \
  apps/ezagent_core/lib/ezagent/behavior/sandbox.ex \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
  apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex \
  apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex \
  apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex \
  scripts/autoservice_tier1_seed.exs

MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps POSTGRES_PORT=55433 mix test \
  apps/ezagent_core/test/ezagent/behavior/sandbox_test.exs \
  apps/ezagent_core/test/ezagent/behavior/sandbox_migration_parity_test.exs \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs \
  apps/ezagent_domain_session/test/integration/sandbox_destroy_test.exs

MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps POSTGRES_PORT=55433 mix test \
  apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs \
  apps/ezagent_domain_identity/test/ezagent/behavior/config_governance_test.exs \
  apps/ezagent_plugin_curl_agent/test/ezagent/plugin_curl_agent/curl_snapshot_migration_test.exs \
  apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs \
  apps/ezagent_core/test/invariants/sensitive_slice_read_test.exs

MIX_DEPS_PATH=/private/tmp/esr-ng-pr-1099/deps POSTGRES_PORT=55433 mix test \
  apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs \
  apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs \
  apps/ezagent_core/test/ezagent/invocation_activate_budget_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_spawn_invariant_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_test.exs
```

Result:

```text
43 + 1 + 15 tests, 0 failures
28 + 38 + 10 tests, 0 failures
4 + 49 + 2 tests, 0 failures
```

Live verification on port `10144`:

```elixir
uri = URI.new!("entity://autosvc/agent/autoservice")
{
  Ezagent.KindRegistry.lookup(uri),
  Ezagent.ReadyGate.status(uri),
  length(Ezagent.Identity.read_entity_caps(uri)),
  Enum.any?(
    Ezagent.Identity.read_entity_caps(uri),
    &(&1.behavior == Ezagent.Behavior.Kb and Ezagent.Capability.action_of(&1) == :query)
  )
}
```

Observed:

```elixir
{{:ok, #PID<...>}, :failed, 4, true}
```

The agent exists and has durable `kb.query` authority. `ReadyGate.status == :failed` is due to the local Claude Code process not being logged in, so the external bridge does not join.

## Residual Issues

- Claude Code local auth is missing: TUI reports `Not logged in · Run /login`, preventing bridge readiness and real answer-loop replies.
- Chat UI still renders `Unsupported node: container`.
- Dev watcher still fails because `node node_modules/.bin/vite` tries to parse a pnpm shell shim as JavaScript.
