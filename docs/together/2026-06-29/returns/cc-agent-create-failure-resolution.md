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

After switching to the template path, a second issue appeared: bridge-backed cc agents keep public `ReadyGate` as `:not_ready` until their external transport bridge joins. Seed/materialization still needs to perform internal initialization before that bridge is ready:

- write the agent sandbox state with `sandbox.write_path`
- grant delegated caps with `identity.grant_cap`

Those internal initialization calls should not wait for chat transport readiness, but they must still preserve Runtime authorization, validation, effects, snapshot commit, and audit behavior.

## Framework Constraint

The framework does not have a blanket rule that every in-VM call must only use `Invocation.dispatch/1` or `Router.dispatch/1`.

The stricter rules are:

- Business/cross-Kind dispatch should go through `Invocation.dispatch/1` or `Router.dispatch/1`.
- Grant/revoke dispatch construction must stay in `Ezagent.Identity.Grant`.
- Capability checks must stay at the dispatch chokepoint or explicitly allowlisted read/ctx-construction sites.
- Lifecycle handlers must not directly call engine internals; they should emit effects.

`Kind.Server`'s `{:ezagent_dispatch, inv}` message is a core internal protocol. Domain code should not depend on that message shape directly.

## Decision

Keep the functional fix, but move the local dispatch exception into `ezagent_core`.

Add a narrow core-owned internal seam:

```elixir
Ezagent.Invocation.dispatch_registered_local(inv)
```

Semantics:

- target Kind must already be registered locally in `KindRegistry`
- no lazy spawn
- no public ReadyGate wait
- no external transport readiness wait
- still enters `Kind.Server -> Kind.Runtime.handle_dispatch/4`
- still preserves CapBAC, args validation, effects, snapshot commit, and audit
- intended only for materialization/bootstrap/internal initialization paths

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
generic role create, but only the bridge-backed flavors directly need the
local-registered dispatch seam to initialize before public transport readiness.

## Implemented Changes

1. `scripts/autoservice_tier1_seed.exs`

   For `flavor == "cc"` and `role == "orchestrator"`, AutoService no longer calls generic `Workspace.create_agent/3`. It reads `template://system/agent/cc-orchestrator`, overrides cwd/role, and calls `Ezagent.Entity.Agent.spawn_from_template_content/5`.

2. `apps/ezagent_core/lib/ezagent/invocation.ex`

   Added `Ezagent.Invocation.dispatch_registered_local/1` as the core-owned local dispatch seam.

3. `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`

   `record_sandbox_state/3` now writes `sandbox.write_path` through `dispatch_registered_local/1`, so cc template materialization can persist sandbox state before the bridge joins.

4. `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`

   `Identity.Grant` remains the only grant/revoke dispatch construction chokepoint. When an imperative grant targets a locally registered but public-not-ready Kind, it uses `dispatch_registered_local/1` instead of directly calling `Kind.Server`.

5. `apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`

   `load_orchestrator_caps/1` reads durable delegated caps via `Ezagent.Identity.read_entity_caps/1`, avoiding public ReadyGate-gated `Identity.list_caps_for/1` for bridge-backed orchestrators.

## Verification

Commands run:

```bash
mix format apps/ezagent_core/lib/ezagent/invocation.ex \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
  apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex \
  apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex \
  scripts/autoservice_tier1_seed.exs

env SHELL=/bin/bash mix test \
  apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs \
  apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs \
  apps/ezagent_core/test/ezagent/invocation_activate_budget_test.exs
```

Result:

```text
6 tests, 0 failures
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
