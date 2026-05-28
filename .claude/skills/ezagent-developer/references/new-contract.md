# Router / Behavior / Kind — the new contract (post 2026-05-28)

> **Authoritative source**: SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` (PR #445, r3). This file is the navigable reference for plugin authors; the SPEC is normative. ARCHITECTURE.md §6.0 is the load-bearing project doc; Decision Log #147-#152 are the per-phase landmarks.

This file is REQUIRED reading before writing any new Behavior, modifying an existing Behavior, or reviewing PRs that touch `apps/ezagent_*/lib/ezagent/behavior/`. The contract changed structurally on 2026-05-28 — every reference to `Behavior.invoke/4` you may find in older docs / forensic notes / tutorials is **stale**.

## Phase chronology (all merged to main)

| Phase | PR | What landed |
|---|---|---|
| **Phase 1** | #451 (with sub-PRs #447 EventLog / #448 SnapshotStore / #449 SagaRunner / #450 Router+Behavior+Kind+LegacyAdapter) | Router primitive, new Behavior contract macros, Kind URI lifecycle, dispatch-equivalent LegacyBehaviorAdapter |
| **Phase 1.5** | #453 | `Kind.Runtime` wires new-contract dispatch through `apply_new_contract_effects/4` |
| **Phase 1.5b** | #454 | Effect executor complete — `:effect_returning` + `{:ref, ...}` substitution |
| **Phase 2** | #462 (7 sub-PRs) | 28+ domain Behaviors migrated — chat / identity / external-mirror / workspace / plugin Behaviors all on new contract |
| **Phase 2.5** | #463 | 6 remaining core Behaviors migrated (Lifecycle / Routing / Presence / Sandbox / Notifications + cap-only) |
| **Phase 3** | #464 | `LegacyBehaviorAdapter` DELETED; `Behavior.invoke/4` retired to `@optional_callbacks` |
| **Phase 4** | #469 | `Kind.Server` attach metadata + `read_graph` cleanup + `Audit.uri_to_str(:system)` fix |
| **E2E tests** | #465-#468 | 165 passing E2E tests across the new pipeline; categories 4/5/7/10/17 + scenarios #24/#25/#30/#5-7 |
| **Scenarios catalog** | #452 | `docs/scenarios/` — 30 documented scenarios; the actual completion gate per `feedback_completion_requires_invariant_test` |

## The 3 core primitives

| Primitive | Owns | Plugin-author touches |
|---|---|---|
| **Router** (`Ezagent.Router`) | dispatch envelope `%Ezagent.Cmd{}`, URI canonicalisation, idempotency, cap check, workspace isolation, audit, effect application | NEVER calls directly; transport adapters (LV / CLI / Channel) build `%Cmd{}` and hand to `Router.dispatch/1` |
| **Behavior** (`use Ezagent.Behavior`) | action namespace + how each action's effects are computed | declares `action :foo, args: %{...}, returns: ..., caps: [...]` macro + writes `def handle_foo(args, ctx) → {:ok, result, [effects]}` |
| **Kind** (`@behaviour Ezagent.Kind`) | URI identity, process lifecycle, attached Behavior list, composition pattern | declares Kind module + attaches Behaviors |

## The 3 composition patterns

A Kind picks one — declared via `pattern:` (`:session | {:resource, :hot} | {:resource, :cold} | :entity`):

| Pattern | Semantics | Default `persistence` policy | Examples |
|---|---|---|---|
| **Session** | Temporary, time-bounded, binds a set of external resources | `:on_terminate` (framework) | `Ezagent.Entity.Session` |
| **Entity** | Long-lived, `@behaviour Principal`, holds capabilities | `every-N events + on-terminate` | `Ezagent.Entity.User`, `Ezagent.Entity.Agent` |
| **Resource (cold)** | Operation target, no Principal; surfaces when operated on, settles to disk between ops | `every-N events + on-terminate` (`on_change`-equivalent) | `Ezagent.Entity.Workspace`, `template://...` resources |
| **Resource (hot)** | High-volume Resource (Worker Kinds, publishers) | `:ephemeral` default + opt-in periodic (codex r2 HIGH-3) | `Ezagent.Entity.ExternalMirrorWorker` |

## Minimal new-contract Behavior

```elixir
defmodule Ezagent.Behavior.EntitySend do
  use Ezagent.Behavior

  action :send,
    args:        %{recipient: :uri, body: :string},
    returns:     %{ok: :boolean},
    caps:        [:send],
    modes:       [:cast],
    description: "Send a message to another entity."

  # Required state slice — framework manages, plugin doesn't read directly
  def state_slice, do: :outbox
  def init_slice(_args), do: %{sends: 0}

  # Compile-time invariant: every `action :foo` MUST have `def handle_foo/2`
  def handle_send(%{recipient: r, body: b}, ctx) do
    current = ctx[:read].(:sends, 0)
    {:ok, %{ok: true},
     [
       {:set, :sends, current + 1},
       {:dispatch, %Ezagent.Cmd{
          target: r,
          action: :receive,
          args:   %{from: ctx[:caller], body: b},
          ctx:    %{caller: ctx[:self_uri], reply: :none}
        }},
       {:notify, "entity:#{ctx[:self_uri]}:sends", %{recipient: r}},
       {:emit, :message_sent, %{recipient: r}}
     ]}
  end
end
```

## Action macro grammar

```elixir
action :name,
  args:             %{<field> => <type_spec>},          # REQUIRED (validates inbound)
  returns:          %{<field> => <type_spec>},          # REQUIRED (validates handler return)
  caps:             [<cap_name | {cap_name, opts}>],    # optional — default [name]
  modes:            [:call | :cast | :call_stream],     # optional — default [:call]
  description:      "human-readable string",            # optional — surfaced in /admin/caps + CmdK
  data_owner:       :self | :any | :no_owner | {:scope, atom, URI},  # optional — default :no_owner
  workspace_scoped?: true | false                       # optional — default true
```

`args` / `returns` use Elixir-style type tuples consumed by `Ezagent.InterfaceValidator` (e.g. `:string`, `:integer`, `{:tuple, :integer, :integer}`, `{:list, :uri}`, `{:option, :string}`, `:map`, `:uri`, `%{<field> => <ty>}`). The `:uri` primitive matches `%URI{}` struct ONLY — rejects bare strings (invariant from Decision #92).

Multiple caps per action (e.g. `caps: [:send, :send_to_session_member]`) ARE allowed and supported — the new `__action_spec__(name).caps` returns the full list; the derived legacy `required_caps/0` collapses to the first cap for back-compat with old registry consumers.

## Effect vocabulary (SPEC §4.4 normative)

The handler's return contract is `{:ok, result, [effect]} | {:ok, result} | {:error, reason}`.

| Effect | Shape | Meaning |
|---|---|---|
| `:set` | `{:set, key, value}` | Update this Kind's slice key (framework commits via SnapshotStore) |
| `:emit` | `{:emit, event_name, payload}` | Append a row to `EventLog` (audit + EventSubscriber consumers) |
| `:dispatch` | `{:dispatch, %Ezagent.Cmd{}}` | Cross-Kind dispatch; framework re-enters Router |
| `:notify` | `{:notify, topic, payload}` | `Phoenix.PubSub.broadcast` fire-and-forget |
| `:effect` | `{:effect, mfa_or_fun, args}` | Side-effect fire-and-forget (caller wraps try/rescue) |
| `:effect_returning` | `{:effect_returning, mfa_or_fun, args, bind_as: :name}` | Value-returning side-effect; result bound to `returning[:name]`, referenced in later effects via `{:ref, :name, [path]}` |
| `:saga` | `{:saga, %SagaRunner.Saga{}}` | Hand a linear saga to `Ezagent.SagaRunner` for forward + best-effort compensation |
| `:terminate` | `{:terminate, :self \| URI.t()}` | Schedule a Kind termination AFTER reply lands (idempotent) |
| `:halt` | `{:halt, reason}` | Short-circuit; remaining effects skipped; SnapshotStore never sees the would-be new slice |

**Ordering**: effects within each phase fire in declared order. The `Kind.Runtime` bucket execution order across phases is fixed:

```
State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations
```

- **State** — `:set` effects applied eagerly inside `apply_effects/2` so downstream `{:ref, ...}` substitutions see new values.
- **Halt** — `{:halt, reason}` short-circuits → `{:error, {:halt, reason}}`; remaining effects NOT executed.
- **Saga** — runs BEFORE cross-Kind dispatches because the saga IS the orchestration boundary; its compensation must not race siblings.
- **Dispatches** — sequential, in declared order; `{:error, _}` from any dispatch propagates up.
- **Notifies** — `Phoenix.PubSub.broadcast` fire-and-forget.
- **Events** — `EventLog.append`. Audit failures DO NOT halt dispatch (a warning is logged; pipeline continues).
- **Terminations** — last, so audit + notify happen against the still-live Kind.

## What plugin authors DO NOT touch

Plugin code MUST NOT import / call directly:

- `Ezagent.Router` internal functions (only `dispatch/1` from adapters)
- `Ezagent.EventLog.append/4` — emit `{:emit, _, _}` effect instead
- `Ezagent.SnapshotStore` (any function) — framework writes on slice change
- `Ezagent.Kind.StateRebuilder` — framework calls on KindRegistry miss
- `Ezagent.EventSubscriber` machinery — declare via `use Ezagent.EventSubscriber` macro, not direct calls
- `Ezagent.SagaRunner.execute/2` — hand a `%Saga{}` to `{:saga, _}` effect
- `Ezagent.Invocation.dispatch/1` from inside a handler — emit `{:dispatch, %Cmd{}}` effect
- `Phoenix.PubSub.broadcast/3` from inside a handler — emit `{:notify, topic, payload}` effect
- `Ezagent.Kind.terminate/1` from inside a handler — emit `{:terminate, target}` effect
- The `slice` map directly — use `ctx[:read].(key, default)` to read, return `{:set, key, value}` effects to write

These are SPEC §11 grep gates; CI fails if a plugin module (under `apps/ezagent_plugin_*` or `apps/ezagent_domain_*`) references them.

## Compile-time invariants the macro enforces

1. **Every `action :foo` MUST have `def handle_foo(args, ctx)`** — `@before_compile` raises CompileError otherwise.
2. **Action spec keys validated**: `:args` and `:returns` are REQUIRED; `:caps`, `:modes`, `:description`, `:data_owner`, `:workspace_scoped?` are optional.
3. **`:description` MUST be a binary** — used in `/admin/caps` + CLI tree + CmdK.
4. **`:modes` MUST be a list** — e.g. `[:call]`, `[:cast]`, `[:call, :cast]`, `[:call_stream]`.
5. **`def handle_<name>/2` is the only handler arity** — not `/3` or `/4`. `args` is map, `ctx` is map (framework injects `:read`, `:self_uri`, `:kind_module`, `:caller`, `:reply`, `:caps`, `:sibling_slices`).

## DOs and DON'Ts

### DO

- `use Ezagent.Behavior` for any new Behavior; declare via `action/3` macro.
- Write pure `handle_<action>/2` functions; return `{:ok, result, [effect]}` for side-effecting actions.
- Read slice via `ctx[:read].(key, default)`; write via `{:set, key, value}` effects.
- Use `{:notify, topic, payload}` for view fan-out (LV chat stream, presence updates).
- Use `{:dispatch, %Cmd{}}` for cross-Kind dispatch with `target: URI, action: :name, args: %{}, ctx: %{caller: ctx[:self_uri], reply: :none}` shape.
- Declare multi-cap actions via `caps: [:foo, :bar]` when an action has multiple authorization axes.
- Implement `reads_sibling_slices/0` (invariant 18) only with explicit declared keys — never `:all_slices`.
- Implement `reconcile_after_load/2` (invariant 20) on Behaviors whose slice is backed by a DB projection.

### DON'T

- Don't implement `invoke/4` callback (Phase 3 PR #464 retired it to `@optional_callbacks`; production code never consults it).
- Don't import `Ezagent.EventLog` / `Ezagent.SnapshotStore` / `Ezagent.Kind.StateRebuilder` / `Ezagent.Router` internals — SPEC §11 grep gate fails CI.
- Don't `Phoenix.PubSub.broadcast` from inside a handler — use `{:notify, _, _}` effect.
- Don't `Ezagent.Invocation.dispatch/1` from inside a handler — use `{:dispatch, %Cmd{}}` effect (exception: result-dependent in-handler dispatch where you need the dispatch return value, e.g. `ReadMarker.mark` after successful chat.receive — see `Ezagent.Behavior.Chat.handle_send/2` for the pattern).
- Don't tune snapshot policy per Behavior — framework decides via `SnapshotStore` (every N events + on-terminate). Legacy `Kind.persistence/0` enum still exists for Phase 2 migrated Kinds in coexistence, but Phase 2+ new Kinds don't declare it.
- Don't manually plumb `ctx[:self_uri]` or `ctx[:kind_module]` — `Kind.Runtime` injects them immediately before handler firing.

## Testing a new-contract Behavior

```elixir
defmodule Ezagent.Behavior.EntitySendTest do
  use ExUnit.Case, async: true

  test "handle_send returns effects in declared order" do
    args = %{recipient: URI.parse("entity://user/default/bob"), body: "hi"}
    ctx = %{
      read: fn :sends, default -> default end,    # mock framework's slice reader
      self_uri: URI.parse("entity://user/default/alice"),
      caller: URI.parse("entity://user/default/alice"),
      reply: :none
    }

    assert {:ok, %{ok: true}, effects} = Ezagent.Behavior.EntitySend.handle_send(args, ctx)

    assert [
             {:set, :sends, 1},
             {:dispatch, %Ezagent.Cmd{action: :receive}},
             {:notify, _, %{recipient: _}},
             {:emit, :message_sent, _}
           ] = effects
  end
end
```

Handlers are pure — directly callable in ExUnit. The bucketiser `Ezagent.Behavior.apply_effects/2` is also pure + testable without process/IO setup. Integration tests through `Ezagent.Router.dispatch/1` cover the full pipeline.

## OQ decisions (the 8 OQs from SPEC §8)

| OQ | Decision | Rationale |
|---|---|---|
| **OQ-1** | Resource URI = `resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>` | workspace segment mandatory (MED-1 closure) |
| **OQ-2** | Pattern enforcement compile-time via Kind macro `pattern:` arg | `@before_compile` rejects unknown patterns |
| **OQ-3** | PubSub ordering — `:notify` effects fire in declared order within their phase | normative ordering across buckets |
| **OQ-4** | Multi-cap action declarations supported via `caps: [list]` | each action can require multiple authorization axes |
| **OQ-5** | Flat action namespace (no per-Behavior prefix) | compile-time collision check between Behaviors attached to same Kind |
| **OQ-6** | Worker Kinds use `:hot_resource` pattern; default `:ephemeral` + opt-in periodic | high-volume Workers (ExternalMirrorWorker etc) can't afford on_change |
| **OQ-7** | `:dispatch_call` removed from effect grammar; saga is the only synchronous chaining | LOW-1 closure |
| **OQ-8** | StateRebuilder lazy-on-first-load | Router calls `rebuild/1` on KindRegistry miss, NOT at app boot |

## See also

- **ARCHITECTURE.md §6.0** — the load-bearing project doc; §6.0.5 covers framework machinery
- **SPEC** `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` — normative source
- **GLOSSARY.md** — entries for `Ezagent.Cmd`, Effect, EventLog, EventSubscriber, Router, SagaRunner, SnapshotStore, StateRebuilder, `handle_<action>` handler, LegacyBehaviorAdapter (historical), updated Behavior + Slice + Snapshot entries
- **Decision Log** #147-#152 in `ARCHITECTURE.md` Appendix B
- `references/slice-and-snapshot.md` — still load-bearing for sibling-slice reads + DB projections
- `references/architecture-invariants.md` invariants 18 (sibling slices), 19 (cap normalize), 20 (reconcile_after_load) — unchanged by 2026-05-28 migration
- `references/how-to-recipes.md` "How-to: add a Behavior" — operational recipe (currently lists Phase 2 migration steps; consult this file first if writing greenfield Behavior post-2026-05-28)
- `docs/scenarios/README.md` — 30 E2E scenarios; scenario #30 ("Plugin author DX") is the canonical greenfield-Behavior end-to-end exercise
