# Scenario 30: Plugin author DX — write a new Behavior with effects

**Category**: 18 — Plugin author DX (Router/Behavior/Kind architecture)
**Status**: ⏳ partially-implemented
**Last verified**: never as a greenfield walkthrough (Phase 1 PR #451 ships LegacyAdapter; Phase 2 exercises this)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Phase 1 (PR #451) merged: `Ezagent.Behavior` macro + `action/3` available
- Developer (plugin author) cloned the umbrella, ready to write a new plugin
- Plugin author's skill loaded (`ezagent-developer` per `feedback_subagent_must_load_project_skills`)

## Actors

- **Caller**: plugin author (developer)
- **Targets**:
  - A new Behavior module
  - The `Ezagent.Behavior` action macro
  - The effects vocabulary (`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:halt` / `:terminate`)

## Steps

### Greenfield Behavior (intended workflow post Phase 2)

1. Create `apps/ezagent_plugin_widget/lib/ezagent/behavior/widget.ex`.
2. Write:
   ```elixir
   defmodule Ezagent.Behavior.Widget do
     use Ezagent.Behavior

     action :do_thing, caps: [{:any, :any, :do_thing, :any, :any}] do
       def handle(args, ctx) do
         {{:ok, %{processed: args.input}},
          [
            {:set, :last_input, args.input},
            {:emit, :widget_processed, %{input: args.input}}
          ]}
       end
     end
   end
   ```
3. Register the Behavior in the plugin's `Ezagent.Plugin` declaration:
   ```elixir
   def behaviors, do: [{Ezagent.Entity.Session, :do_thing, Ezagent.Behavior.Widget}]
   ```
4. `mix compile` runs Compiler-gate validations (per SPEC 2026-05-22 plugin-authoring-contract):
   - `plugin_info/0` returns well-formed map
   - All declared Behaviors implement the contract
   - No `feishu://`-style new top-level scheme attempts (allowlist enforcement)
5. Boot phx; verify the Behavior is registered.

### Dispatch + verify

6. From iex: `Ezagent.Router.dispatch("session://system/sess_a", :do_thing, %{input: "hi"})`.
7. Verify:
   - Cap check passes (any session cap or admin).
   - Handler returns `{:ok, %{processed: "hi"}}`.
   - Effect `{:set, :last_input, "hi"}` updates the slice.
   - Effect `{:emit, :widget_processed, ...}` writes to EventLog.
   - Session subscribers receive the `:widget_processed` event.

### LegacyAdapter migration (intended workflow Phase 2)

8. Take an existing `Behavior.Chat.invoke/4` callsite.
9. Wrap via `LegacyBehaviorAdapter`:
   ```elixir
   {{:ok, result}, effects} = LegacyBehaviorAdapter.wrap(Behavior.Chat, :send, args, ctx)
   ```
10. Verify the adapter produces the same Invocation shape + the result matches the pre-migration baseline.
11. Migrate `Behavior.Chat.invoke/4` to use `use Ezagent.Behavior` + `action :send` directly.
12. Compare before/after: same dispatch shape, same effects, no behavior change.

### Saga compensation (intended)

13. Declare a multi-step saga:
    ```elixir
    action :complex_thing, caps: [...] do
      def handle(args, ctx) do
        {{:ok, %{}},
         [
           {:saga, [
             {:dispatch, "agent://...", :step_a, %{}},
             {:dispatch, "agent://...", :step_b, %{}},
             {:dispatch, "agent://...", :step_c, %{}}
           ], compensate: [
             {:dispatch, "agent://...", :undo_a, %{}},
             {:dispatch, "agent://...", :undo_b, %{}}
           ]}
         ]}
      end
    end
    ```
14. Verify: all three steps succeed → no compensation. If step_b fails → undo_a runs (compensation order is reverse of execution).

## Expected outcomes

- The new Behavior compiles + boots without touching core, registry APIs, or any other plugin.
- Effects are framework-applied in declared order; plugin author never calls `EventLog.write/1` directly.
- Plugin LOC for a new Behavior is ≤30 LOC (SPEC #445 target).
- Per `feedback_north_star_plugin_isolation`, the plugin author touches ZERO core knowledge.

## Failure modes to test

- Declare an action without a matching cap pattern: compile-time error from the macro.
- Return an unknown effect tuple: framework raises `:unknown_effect`.
- Saga step fails + compensation also fails: SagaRunner marks operator-repair (scenario 24).
- Behavior returns malformed `{result, effects}`: compile-time + runtime guards.

## Cross-references

- Related PRs:
  - PR #447 — EventLog + EventSubscriber
  - PR #448 — SnapshotStore + StateRebuilder
  - PR #449 — SagaRunner
  - PR #450 — Cmd, Router, Behavior macro, Kind ext, LegacyAdapter
  - PR #451 — Phase 1 integration
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md` — REV 2 contract
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` — THE governing SPEC for this scenario
- Tests:
  - PR #450 sub-branch tests cover the macro + LegacyAdapter shape (`feat/p1a-core`)
  - No greenfield-Behavior E2E test yet (this is what Phase 2 PR-1 will land)

## Notes

- This is master README §6 priority 1 — Phase 2's done-gate is plugin authors writing new Behaviors without core knowledge. A runnable greenfield E2E + golden file is the gate.
- Per `feedback_completion_requires_invariant_test`, the "plugin-author-isolation" invariant must be expressed as a CI grep gate (per SPEC #445 §11): "plugin code never imports `Ezagent.EventLog`, `Ezagent.SnapshotStore`, etc."
- The LegacyAdapter migration path is the bridge that allows Phase 2 to migrate 22 Behaviors incrementally without big-bang rewrites.
