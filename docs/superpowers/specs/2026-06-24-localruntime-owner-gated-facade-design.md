# `Ezagent.LocalRuntime` — owner-gated plugin runtime facade

> **Status:** design approved (Allen, 2026-06-24). Task #95.
> **Supersedes the "pending owner-gated wrapper" debt** recorded in
> `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`.

## Problem

The workspace-locality gate (#947, `Ezagent.WorkspaceOwnerGate` + `WorkspacePlacement`
+ `RuntimeIdentity`) established the **gate** (inside `Invocation.dispatch` and
`SpawnRegistry.spawn`) and a **static contract** that flags plugins reaching into
core local-runtime registries directly. But it deferred the clean plugin-facing
APIs, so ~37 call sites across `advisor`/`cc`/`codex`/`echo`/`feishu` still call:

- `Ezagent.KindRegistry.lookup(uri)` — "is this Kind alive?" liveness probes.
- `Ezagent.SpawnRegistry.spawn[_detailed](uri)` — spawn/ensure the Kind.

These are recorded as debt in the contract allowlist (`total ≈ 37`).

**Why a facade and not raw registry calls (the load-bearing rationale).**
Raw `KindRegistry.lookup/1` is a **local-only** read: single-node it is correct,
but under a **decentralized (multi-node) deployment** — the direction
`RuntimeIdentity`/`WorkspacePlacement` exist to enable — an agent owned by another
node returns `:error` (not found locally) even though its Kind is alive on the
owner node. A liveness probe that reads that `:error` makes a **wrong** decision
(e.g. spurious respawn). The gate makes the locality assumption **explicit**:
single-node it is a no-op; multi-node it returns a structured non-owner result
instead of a misleading `:error`. **The decentralization assumption is a
fundamental architectural change** — plugins must stop assuming "the Kind is on my
node".

Beyond function, the facade serves the **plugin-isolation north-star**: plugin
authors get ONE owner-gated entry point and never reference core registries
(`KindRegistry`/`SpawnRegistry`) directly. (This is why the contract flags even the
already-gated `SpawnRegistry.spawn` — it wants layering purity, not just gating.)

## Non-goals

- Not building the multi-node resolver itself (still `LocalResolver` → local node).
- Not gating `genserver_to_pid` (sidecar/executor) calls — see Decision 2.
- Not changing `WorkspaceOwnerGate`/`WorkspacePlacement`/`RuntimeIdentity`.

## Decisions

**Decision 1 — `Ezagent.LocalRuntime` facade (new core module).**
`apps/ezagent_core/lib/ezagent/local_runtime.ex`:

```elixir
@doc "Owner-gated liveness probe: is the Kind for `uri` alive on its owner runtime?"
@spec kind_alive?(URI.t()) :: boolean()
def kind_alive?(%URI{} = uri) do
  case Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(uri, {:liveness, uri}) do
    :ok ->
      case Ezagent.KindRegistry.lookup(uri) do
        {:ok, _pid} -> true
        :error -> false
      end

    {:error, _} ->
      # Non-owner (multi-node): not alive HERE. Distinct from a local :error —
      # callers must NOT treat this as "dead, respawn locally".
      false
  end
end

@doc "Owner-gated ensure: spawn the Kind for `uri` if absent (delegates to the gated SpawnRegistry)."
@spec ensure_started(URI.t()) :: {:ok, :started | :already_started} | {:error, term()}
def ensure_started(%URI{} = uri), do: gate_then(uri, fn -> Ezagent.SpawnRegistry.spawn(uri) end)

@spec ensure_started_detailed(URI.t()) ::
        {:ok, :started | :already_started, pid()} | {:error, term()}
def ensure_started_detailed(%URI{} = uri),
  do: gate_then(uri, fn -> Ezagent.SpawnRegistry.spawn_detailed(uri) end)
```

(`gate_then/2` runs `assert_local_owner_for_uri` then the thunk; on a gate error
returns `{:error, {:not_local_owner, uri}}`.) Return shapes mirror the existing
`SpawnRegistry.spawn[_detailed]` so callers change only the module name + the
liveness call shape (`case lookup do {:ok,_}->true; :error->false end` → `kind_alive?/1`).

**Open question for review:** `kind_alive?/1` collapses "non-owner" and "locally
dead" both to `false`. Single-node that is correct (gate is no-op). Multi-node a
caller that wants to *respawn-if-dead* must not respawn a non-owner agent. Since
`ensure_started/1` is ALSO gated (a non-owner ensure returns `{:error,
{:not_local_owner,_}}`, never spawns a foreign agent locally), the
probe-then-ensure pattern is safe even with the collapsed boolean. We keep the
boolean for ergonomics; the gate on `ensure_started` is the real safety net.

**Decision 2 — `genserver_to_pid` (sidecar/executor) EXEMPTED, not wrapped.**
The flagged `GenServer.call(pid, …)` sites are:
- cc `SdkSidecar` (`recent_output`, `query`) + codex `BridgeSidecar` (`recent_output`)
  — per-agent Python subprocess managers registered in the *plugin's own*
  `DynamicSupervisor` (NOT `KindRegistry`, not workspace-bound Kinds).
- orchestrator `mcp_server` executor (`{:run_tool, …}` to the SessionManager pid).

These are **agent-local subprocess / executor IPC**, not workspace-bound Kind
resolution. The locality boundary is enforced when the AGENT is resolved/spawned
(already gated); by the time a plugin holds a sidecar pid the agent was already
located on its owner. Wrapping each sidecar status call in an owner-gate is
gating-for-gating's-sake. → Reclassify: the contract **exempts** the
`genserver_to_pid` key for sidecar/executor (documented as "agent-local IPC;
locality enforced at agent resolution"), rather than holding it as migratable debt.

**Decision 3 — contract changes (`plugin_workspace_locality_contract_test.exs`).**
- `kind_registry_lookup` + `spawn_registry`: once a site migrates to
  `LocalRuntime`, its allowlist entry is **removed** (debt → 0 for these keys).
  `LocalRuntime` itself lives in core and IS allowed to call KindRegistry/SpawnRegistry
  (it's the one sanctioned chokepoint) — add a single core-internal allow/scope so
  the lint targets only `apps/ezagent_plugin_*`.
- `genserver_to_pid`: drop the regex/key (Decision 2) OR convert its entries to a
  documented permanent-exempt list with the "agent-local IPC" reason.
- The non-env-gated hard-assert tests must stay green at every step (allowlist
  exact + no un-allowlisted bypass).

## Migration sites (from the current allowlist)

| plugin | file | calls |
|---|---|---|
| advisor | `advisor_session.ex` | lookup |
| cc | `orchestrator/cc_orchestrator_seed.ex` | lookup×2, spawn |
| cc | `orchestrator/mcp_server.ex` | spawn×2 (+ executor genserver = exempt) |
| cc | `template/cc_agent.ex` | lookup |
| cc | `template/cc_agent/spawn.ex` | spawn |
| cc | `template/cc_headless_agent.ex` | lookup |
| cc | `mix/tasks/ezagent.demo.seed_cc_agent.ex` | lookup×2, spawn×2 |
| cc | `mix/tasks/ezagent.demo.seed_cc_sandbox.ex` | lookup, spawn |
| cc | `plugin_cc/sdk_sidecar.ex` | genserver = exempt |
| codex | `template/codex_agent.ex` | lookup, spawn |
| codex | `template/codex_remote_agent.ex` | lookup, spawn |
| codex | `plugin_codex/bridge_sidecar.ex` | genserver = exempt |
| echo | `template/echo_agent.ex` | lookup, spawn |
| echo | `ezagent_plugin_echo/application.ex` | spawn (boot) |
| feishu | `plugin_feishu/binding_policy.ex` | lookup, spawn |
| feishu | `plugin_feishu/sender_resolver.ex` | lookup, spawn |

(Demo `mix` tasks are operator tooling, not the hot runtime — migrate too for
consistency / to zero the allowlist, but lowest risk.)

## Phasing (one PR per group, each precommit + check_invariants green)

1. **PR-1 (core):** add `Ezagent.LocalRuntime` + unit tests (single-node: gate
   no-op; simulated non-owner via a test resolver: `kind_alive?`→false,
   `ensure_started`→`{:error,{:not_local_owner,_}}`); scope the contract lint to
   `apps/ezagent_plugin_*` so core's own `LocalRuntime` is exempt; apply Decision 2
   (exempt `genserver_to_pid`). No plugin migration yet — allowlist still covers
   the unmigrated lookup/spawn sites. Gate green.
2. **PR-2 cc**, **PR-3 codex**, **PR-4 echo**, **PR-5 feishu+advisor**: migrate each
   plugin's lookup/spawn to `LocalRuntime`; remove the corresponding allowlist
   entries. Each PR keeps the hard-assert invariants green.
3. **PR-final:** allowlist `kind_registry_lookup`/`spawn_registry` plugin entries =
   0; update the moduledoc; **update the `ezagent-developer` skill** (mandatory,
   Allen): document `LocalRuntime`, the rule "plugins never call
   KindRegistry/SpawnRegistry directly", and the decentralization/local-owner gate
   semantics.

## Testing

- `LocalRuntime` unit tests with a stub `WorkspacePlacement` resolver to exercise
  the non-owner branch (the only way to test multi-node behavior single-node).
- Each migration PR: the existing plugin behavior tests + the (hard-assert)
  locality contract test, full `mix precommit` (EXIT=0 + every suite 0 failures)
  + `mix ezagent.check_invariants`.
- codex adversarial review of THIS spec before PR-1; codex review per PR.

## Risks

- **Boot-time lookups before `WorkspacePlacement` is ready** (e.g. echo
  `application.ex` boot spawn). Verify the default `LocalResolver` answers during
  boot; if not, `ensure_started` must tolerate a not-yet-ready resolver (fall back
  to local in observe mode). Check in PR-1.
- **Return-shape drift** at migrated sites (liveness `case lookup` → `kind_alive?`
  boolean). Mechanical; covered by each plugin's existing tests.
