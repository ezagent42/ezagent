# Lifecycle API — the SOLE developer surface (post 2026-05-29)

> **Authoritative source**: SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` (Phase A/B/C). ARCHITECTURE.md §6.0.7 is the load-bearing project doc; Decision Log #153 is the landmark. This file supersedes `references/new-contract.md` for ANY developer writing a Behavior — `new-contract.md` now describes the INTERNAL engine the Lifecycle macro compiles down to.

This file is REQUIRED reading before writing any Behavior, modifying an existing Behavior, or reviewing PRs that touch `apps/ezagent_*/lib/ezagent/behavior/`.

## The one rule

**Developer code uses `use Ezagent.Lifecycle`. It NEVER uses `use Ezagent.ActionSet`, never declares `state_slice/0`, never implements `init_slice/1` / `invoke/4` / `post_init/2` / `handle_continue/3` / `on_ready/2` / `reconcile_after_load/2`.** Router / Behavior / Kind (R/B/K) are the *internal engine*; Lifecycle is the *public API* it compiles down to (R10-3). The Phase C grep gate `mix ezagent.check_invariants.lifecycle` HARD-fails CI if a developer-tier file re-introduces the old surface.

## Why the change

Five framework concepts (`state_slice/0`, `init_slice/1`, snapshot-merge semantics, five persistence strategies, FOUR boot hooks `post_init`/`handle_continue`/`on_ready`/`reconcile_after_load`) produced a recurring expensive bug class: **a resource is rebuilt on fresh spawn but NOT on cold-load-from-snapshot** (the rebuild was written in the "wrong" one of four boot hooks). Concrete instances: #110 orchestrator MCP ETS row, #113 codex bridge subprocess, #114 AgentLineage ETS. Every one is "fresh works, restart doesn't." Root cause: persistent state and transient handles lived in the SAME `slice` map, separated only by author discipline.

## The two-container model (the core idea)

| | `state` | `transients` |
|---|---|---|
| Persisted? | YES — framework auto-snapshots | NEVER — no serialization path exists |
| Holds | domain data (members, conversation, config, caps) | PIDs, refs, ETS handles, ports, subprocess handles, monitor refs, cached connections |
| Built by | `create/1` (first-ever) + `{:set, k, v}` effects from handlers | `activate/2` (rebuilt EVERY start) + `{:set_transient, k, v}` effects |
| Read via | `ctx.read.(key, default)` (the bracket form `ctx[:read]` is ALSO kept — same closure) | `ctx.transients[key]` |
| Survives restart? | YES (durable) | NO — `activate` rebuilds from `state` (+ external SoT) |

Two structural guarantees:

1. A transient **cannot be accidentally persisted** — there is no code path that serializes `transients`. Only the `state` sub-key is handed to `SnapshotStore`.
2. A transient **cannot be forgotten on restart** — `activate/2` is the ONLY place a transient can be built, and `activate` runs on EVERY process start: fresh spawn, supervisor restart, AND cold-load-from-snapshot. There is no separate "restart" / "on_load" / "on_ready" rebuild hook to write it in the wrong one.

## The lifecycle hooks

```elixir
defmodule MyAgent.Lifecycle do
  use Ezagent.Lifecycle

  # ---- Action + effect declarations (UNCHANGED grammar — see below) ----
  action :send, args: %{recipient: :uri, body: :string}, returns: %{ok: :boolean},
    caps: [:send], modes: [:cast], description: "Send a message."

  # ---- COARSE hooks (OTP-grounded). All OPTIONAL except handle_<action>. ----

  # create/1 — FIRST-EVER existence of this URI (runs ONCE in history,
  # gated by the `ever_created` kind_snapshots column). Build initial
  # PERSISTENT state. MUST NOT build transients.
  def create(args), do: {:ok, %{...}}

  # activate/2 — EVERY process (re)start (OTP init/1 semantics). The
  # UNIFIED start hook: fresh spawn, supervisor restart, AND cold-load.
  # Rebuild ALL transients here from `state` (+ external SoT). Self-heal
  # (orphan-reap prior-incarnation resources) — destroy is best-effort.
  # Runs PRE-`:ready`. 3-arity return reconciles state (subsumes
  # reconcile_after_load).
  def activate(state, ctx)            # {:ok, transients} | {:ok, transients, state}

  # handle_<action>/2 — one per declared action. Pure (args, ctx) fn
  # returning the effect list. UNCHANGED from the engine contract.
  def handle_send(args, ctx)          # {:ok, result, [effect]}

  # handle_signal/2 — non-action GenServer messages (:DOWN, PubSub
  # deliveries, self-deferred mailbox messages). Successor to the old
  # handle_kind_message/3. Returns the same effect list as handle_*.
  def handle_signal(message, ctx)     # [effect] | :ignore

  # activated/2 — runs AFTER the ReadyGate flips (POST-`:ready`). RARE —
  # only for reachability broadcasts that invite peer :call round-trips.
  # Rename of the engine's on_ready/2.
  def activated(state, ctx)           # {:ok, transients}

  # pre_handle/3 — BEFORE the matched handler (authz / arg-rewrite).
  def pre_handle(action, args, ctx)   # :cont | {:cont, args} | {:halt, result} | {:error, reason}

  # post_handle/4 — AFTER the handler, BEFORE effects execute (audit /
  # effect injection). Fires even when the handler returned no effects.
  def post_handle(action, result, effects, ctx)  # {:ok, result, effects} | :cont

  # deactivate/2 — graceful stop; the ENTITY PERSISTS (NOT destroy).
  # :ok-ONLY (F5): runs through OTP terminate AFTER the final snapshot,
  # so it CANNOT mutate persisted state. Side-effecting cleanup only.
  def deactivate(reason, ctx)         # :ok

  # destroy/2 — PERMANENT deletion. Framework clears `state` from disk +
  # flips the ever-created marker off. Best-effort — cleanup that MUST
  # happen even on a brutal kill belongs in the next activate's self-heal.
  def destroy(reason, ctx)            # :ok
end
```

`ctx` (framework-injected; never plumbed by the author): `:self_uri`, `:kind` / `:kind_module`, `:caller`, `:reply`, `:caps`, `:state` (read view), `:transients` (read view), `:siblings` (opt-in via `reads_siblings/0`), plus `ctx.read.(key, default)`.

## §10 binding rules (codex adversarial review — non-negotiable)

- **R10-1 — self-deferred boot work.** If your old `handle_continue/3` did `send(self(), msg)` to defer work PAST `:ready` (canonical: `ExternalMirror` worker-spawn — the workers' `subscribe_from` `:call` hits `:not_ready` if spawned pre-ready), that body does NOT go in `activate` (which is pre-`:ready`). It goes in `activated/2` OR the `activate → send(self(), msg) → handle_signal(msg, ctx)` pattern. `activate` may only do the `send`; `handle_signal` does the deferred work after the mailbox drains (post-`:ready`).
- **R10-2 — commit atomicity.** `{:set, ...}` and `{:set_transient, ...}` in one handler return are pure pre-commit map reductions: both new maps are computed BEFORE `Snapshot.commit`; only `state` is snapshotted; if commit fails NEITHER advances. A `transients` change never triggers a snapshot write.
- **R10-3 — engine contract stays.** `Ezagent.ActionSet` is the macro's compile target. Don't delete it, its callback definitions, or `Kind.Runtime`'s use of it. "No shims" (AC-5) means no developer-facing back-compat, NOT removal of the engine.
- **R10-4 — wipe cutover is ordered.** Snapshot cutover = stop ALL nodes → deploy → DELETE `kind_snapshots` (confirm empty) → restart (create/activate rebuild from durable SoT). Never start a new-code node against a DB holding old merged-slice rows.

## Bug-fix-by-construction (the three historical cases)

```elixir
# #110 orchestrator MCP ETS row — the row is a TRANSIENT, rebuilt every start:
def activate(state, ctx) do
  if orchestrator?(state) do
    Ezagent.Orchestrator.McpRegistry.register(ctx.self_uri, session_uri: ctx.self_uri, ...)
  end
  {:ok, %{}}
end

# #113 codex bridge subprocess — the bridge handle is a TRANSIENT, re-spawned + orphan-reaped:
def activate(state, ctx) do
  _ = EzagentPluginCodex.OrphanReaper.reap(ctx.self_uri)        # self-heal prior incarnation
  {:ok, bridge_pid} = EzagentPluginCodex.BridgeSidecar.ensure(ctx.self_uri, state.bridge_params)
  {:ok, %{bridge: bridge_pid}}
end

# #114 AgentLineage — `spawned_by` is durable STATE; the ETS index is a TRANSIENT rebuilt from it:
def create(args), do: {:ok, %{spawned_by: Map.get(args, :spawned_by), ...}}
def activate(state, ctx) do
  if state.spawned_by, do: Ezagent.AgentLineage.record(ctx.self_uri, state.spawned_by)
  {:ok, %{}}
end
```

In all three the developer writes one obvious line in `activate`; the container split makes omitting it structurally impossible (the resource has no other home).

## Action macro grammar + effect vocabulary (UNCHANGED)

The `action :name, args:, returns:, caps:, modes:, description:, data_owner:, workspace_scoped?:` grammar is VERBATIM the engine's `Ezagent.ActionSet.action/3`. The effect vocabulary is VERBATIM, plus one additive effect:

| Effect | Shape | Meaning |
|---|---|---|
| `:set` | `{:set, key, value}` | Update PERSISTENT `state` key (framework snapshots) |
| `:set_transient` | `{:set_transient, key, value}` | Update VOLATILE `transients` key — NEVER snapshotted (OQ-2) |
| `:emit` | `{:emit, event_name, payload}` | Append to EventLog |
| `:dispatch` | `{:dispatch, %Ezagent.Cmd{}}` | Cross-Kind dispatch; framework re-enters Router |
| `:notify` | `{:notify, topic, payload}` | `Phoenix.PubSub.broadcast` fire-and-forget |
| `:effect` / `:effect_returning` | `{:effect, mfa, args}` / `{:effect_returning, mfa, args, bind_as: :n}` | side-effect; `{:ref, :n, [path]}` substitution |
| `:saga` | `{:saga, %SagaRunner.Saga{}}` | linear saga + best-effort compensation |
| `:terminate` | `{:terminate, :self \| URI.t()}` | schedule Kind termination after reply |
| `:halt` | `{:halt, reason}` | short-circuit; remaining effects skipped; no snapshot |

Bucket execution order (fixed): `State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations`. For the full grammar see `references/new-contract.md` §"Effect vocabulary" (the engine reference).

## §11 naming principles (NP-1/2/3) — enforced by the Phase C lint

The `Lifecycle → AdminControl → TerminateWorker → Terminable` rename journey (OQ-6) exposed a recurring failure mode: a module gets a name that promises more (or names the wrong layer) than the code delivers, because it was **named by birth-context / host, not by responsibility + layer**.

- **NP-1 — Name by responsibility, at the narrowest accurate scope.** A name describes WHAT IT DOES, not what it attaches to or the PR that birthed it. A single-action Behavior's name tracks that action's intent. (`Terminable`, not `Lifecycle`.)
- **NP-2 — Name in the vocabulary of the module's own layer.** A module in `ezagent_core` (R/B/K layer) may name only core-layer concepts (`Kind`, `Router`, `Behavior`, `effect`, `slice`/`state`). It must NOT name upper-layer composition concepts (`Agent`, `Session`, `Orchestrator`, `Workspace`, `Worker`, `Feishu`, `Cc`, `Codex`, `Np`, `Curl`). Capability-style names in the `Enumerable`/`Collectable` idiom fit core well. (`Terminable`, not `AgentTermination`.)
- **NP-3 — Width match.** A name whose semantic scope is clearly broader than its `action`s is over-promise; narrower is under-describe. Aim for equality. A generic name (`Lifecycle`/`Admin`/`Manager`/`Control`/`Handler`/`Service`/`Worker`) on a ≤1-action module is the smell.

The lint (in `mix ezagent.check_invariants.lifecycle`): (1) layer-vocab — flags `ezagent_core` module names containing an upper-layer word (explicit allowlist for genuine registry/index exceptions); (2) width — flags a `use Ezagent.Lifecycle` module whose name is a generic word but which declares ≤1 action. **Phase B rename audit**: while converting a module, check its name against NP-1/2/3 and REPORT any violation — do NOT silently rename (a rename touches call sites + snapshot slice keys; treat it with `Terminable`-level care).

## DOs and DON'Ts

### DO
- `use Ezagent.Lifecycle` for any Behavior. Declare actions via `action/3`.
- Put PERSISTENT data in `create/1` + `{:set, ...}`; put PIDs/refs/ETS/ports/subprocesses/monitors in `activate/2` + `{:set_transient, ...}`.
- Rebuild EVERY transient in `activate/2`; self-heal (orphan-reap) there too.
- Use `handle_signal/2` for `:DOWN` / PubSub / self-deferred messages.
- Use `activated/2` ONLY for post-`:ready` reachability broadcasts.
- Read state via `ctx.read.(key, default)`; read transients via `ctx.transients[key]`.
- Declare sibling-state reads via `reads_siblings/0` (explicit keys; never `:all_slices`) — surfaced as `ctx.siblings`.
- Use the `state_slice:` macro option + `# lifecycle:state_slice_override` marker ONLY when snapshot-key stability requires it.

### DON'T
- Don't `use Ezagent.ActionSet` (engine-only). Don't declare `state_slice/0` as a `def` (use the macro option). Don't implement `init_slice/1` / `invoke/4` / `post_init/2` / `handle_continue/3` / `on_ready/2` / `reconcile_after_load/2`.
- Don't put a PID/ref/ETS/port in `state` — it gets snapshotted then rehydrated as a dead reference.
- Don't do self-deferred (`send(self(), …)`) post-`:ready` work in `activate` (R10-1) — use `activated`/`handle_signal`.
- Don't `Phoenix.PubSub.broadcast` / `Ezagent.Invocation.dispatch/1` / `Ezagent.SnapshotStore.*` / `Ezagent.EventLog.append` from inside a handler — emit `{:notify, ...}` / `{:dispatch, %Cmd{}}` / `{:set, ...}` / `{:emit, ...}` effects.
- Don't name a core module after an upper-layer concept (NP-2) or give a single-action module a generic name (NP-3).

## Testing

Handlers are pure `(args, ctx)` functions, directly callable. For the cold-restart invariant use `Ezagent.LifecycleCase.assert_transients_rebuilt/2` (SPEC §6): drive the Kind to a non-trivial state, brutal-kill it (`Process.exit(pid, :kill)` — skips `deactivate`/`destroy`), demand-spawn the same URI, assert `state` rehydrated AND `transients` rebuilt to LIVE equivalents (no stale PID/ref from the prior incarnation). This test FAILS exactly when a transient was persisted or its `activate` rebuild deleted — i.e. when the cold-restart bug class reappears.

```elixir
ctx = %{
  self_uri: URI.parse("entity://user/team-alpha/alice"),
  caller:   URI.parse("entity://user/team-alpha/alice"),
  reply:    :none,
  read:     fn key, default -> Map.get(state, key, default) end,   # mock state reader
  transients: %{},
  caps:     MapSet.new()
}
assert {:ok, %{ok: true}, effects} = MyAgent.Lifecycle.handle_send(args, ctx)
```

## See also

- **ARCHITECTURE.md §6.0.7** — Lifecycle API as the sole developer surface (load-bearing project doc)
- **SPEC** `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` — normative source (§0 decisions, §2 contract, §3 R/B/K mapping, §9 OQ decisions, §10 codex rules, §11 naming)
- **Decision Log #153** in `ARCHITECTURE.md` Appendix B
- **`references/new-contract.md`** — the INTERNAL engine (R/B/K) the Lifecycle macro compiles down to; consult only when working on the engine itself
- **GLOSSARY.md** — `Lifecycle` + `Behavior` (now engine-internal) + Effect entries
- **Phase C gate**: `mix ezagent.check_invariants.lifecycle` — the HARD invariant test
- `references/architecture-invariants.md` invariants 18 (sibling reads, now `reads_siblings/0`), 19 (cap normalize), 20 (reconcile, now folded into `activate`)
