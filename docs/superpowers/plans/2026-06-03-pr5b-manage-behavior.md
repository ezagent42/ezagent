# PR-5b: `Ezagent.Behavior.Manage` — uniform management surface (#533 §3.4/§3.5)

> REQUIRED SUB-SKILL: superpowers:test-driven-development. Steps are checkboxes.

**Goal:** A core `Ezagent.Behavior.Manage` registered on every Kind, exposing two cap-gated management actions — `:delete` and `:reconfigure` — so management authority is uniform across all Kinds. The manage-cap that authorizes these is granted at create by **5c** (not here); 5b builds the surface they gate.

**Status:** branch `feat/pr5b-manage-behavior` off main (03a6b002, includes 5a). NOT to be auto-merged — 5b is part of the security-adjacent PR-5 set; open PR + codex review + Allen review before merge.

---

## Key design decisions (the non-obvious parts — found during 5a)

### D1. `:delete` cannot self-destroy — use a detached Task (model: `Terminable`)
`manage.delete` is dispatched **into the target Kind's own process** (`runtime` routes `?action=manage.delete` to the target pid). But `Ezagent.Lifecycle.destroy/2` **rejects self-destroy** (`{:error, :cannot_self_destroy}` — a Kind can't run its own destroy hooks while it's the process executing them).

Resolution — mirror `Ezagent.Behavior.Terminable.handle_terminate/2` (`terminable.ex:143-169`): the handler returns its reply `{:ok, :deleted}` plus an `{:effect, {__MODULE__, :schedule_delete}, [self_uri, reason]}` effect. `schedule_delete/2` spawns an **unlinked Task** that (after a small delay so the dispatch reply wins the race) calls `Ezagent.Lifecycle.destroy(self_uri, reason)` from an EXTERNAL process → the self-destroy guard passes, and destroy runs hooks → terminate → delete (the 5a-corrected order). The Class teardown (undo durables, §5) runs INSIDE destroy's developer-destroy-hooks path, OR is composed here before scheduling — see D4 / defer the full teardown contract to 5g; 5b's `:delete` = "schedule Lifecycle.destroy", teardown composition lands in 5g.

### D2. `:reconfigure` is a NEW Manage action over a `:spec` slice (§3.5)
Manage owns a small `:spec` slice recording the `template_data` the Kind was created/last-reconfigured with. `handle_reconfigure(%{template_data: new}, ctx)`:
1. Resolve the Kind's Template Class; run `Class.validate/1` on `new`; reject immutable-identity changes (OQ-3).
2. `{:set, :spec, new}` — same-behavior slice write (legal; `behavior.ex` `{:set,...}` writes the current behavior's slice).
3. Execute the Class's optional `reconfigure/4` callback's returned `{:dispatch, %Ezagent.Cmd{}}` effects (self-dispatches; `caller: self_uri`).
A Class without `reconfigure/4` → `{:error, :reconfigure_unsupported}`.
**5b scope:** ship the `:spec` slice + `:reconfigure` action + the `{:error, :reconfigure_unsupported}` default + validate/identity-guard. The per-Class `reconfigure/4` implementations (Agent/Session/etc.) can be incremental (5b ships the contract + the unsupported default; concrete Class hooks follow as needed).

### D3. Register on EVERY Kind (§3.4)
There is no global "all Kinds" list; registration is per-Kind in `application.ex` (e.g. `register_presence_behavior`). Add a `register_manage_behavior` that registers `Manage` `:delete` + `:reconfigure` against each Kind module (User, Agent, Session, Workspace, System, Templates, + the cc/codex/curl Kinds). Enumerate them explicitly (mirror how Presence/Notifications register per-Kind). Add a CI invariant (5g) that every Kind type has Manage registered.

### D4. `required_caps` — `cap(:any, Manage, :any)` resolved per-instance
`required_caps[:reconfigure] = required_caps[:delete] = Ezagent.Capability.cap(:any, __MODULE__, :any)` (§3.4) resolved against the target instance at dispatch. The manage-cap `cap(:<kind>, Manage, :any, instance)` (granted by 5c) satisfies both. Use `:any` **action** (not `:manage`) per §3.3 — dispatch overwrites needed-cap action with the concrete action, so a held `:manage` wouldn't match `:reconfigure`/`:delete`.

## Files
- Create `apps/ezagent_core/lib/ezagent/behavior/manage.ex` — `use Ezagent.Lifecycle` (or `Ezagent.Behavior`), `:spec` slice via `create/1` → `%{spec: %{}}` (actually slice key `:spec`), actions `:delete` + `:reconfigure`, `required_caps/0`, `handle_delete/2` (Terminable-style detached destroy), `handle_reconfigure/2`, `schedule_delete/2`.
- Modify `apps/ezagent_core/lib/ezagent_core/application.ex` — `register_manage_behavior/0` registering Manage on every Kind.
- Add the optional `reconfigure/4` callback to the Template Class behaviour contract (where Template Classes are defined) — optional, default → `:reconfigure_unsupported`.
- Tests: `apps/ezagent_core/test/ezagent/behavior/manage_test.exs` (delete schedules destroy + Kind gone; reconfigure unsupported default; reconfigure writes :spec + runs Class dispatch when supported; required_caps shape). Use `Ezagent.LifecycleCase` + a fixture Kind.

## Tasks (TDD, bite-sized) — summary
1. Manage behavior skeleton + `:spec` slice + `required_caps` (test: registered shape).
2. `:delete` via detached `Lifecycle.destroy` Task (test: dispatch `manage.delete` → reply `{:ok,:deleted}` → Kind gone + snapshot row gone; assert NOT self-destroy-rejected).
3. `:reconfigure` default `{:error, :reconfigure_unsupported}` (test).
4. `:reconfigure` happy path: `:spec` write + Class `reconfigure/4` dispatch effects (test with a fixture Class exporting reconfigure/4).
5. `register_manage_behavior` on every Kind + boot wiring (test: each Kind type resolves Manage caps).
6. Plan→codex review (static)→address→open PR (do NOT auto-merge; Allen review).

## Out of scope (later sub-PRs)
- 5c: the `kind.create` authorized entry + manage-cap grant at create (the heart; security-critical → held review).
- 5d: converge the ~7 ad-hoc create paths + bridge-join `exists_durably?`.
- 5e: Workspace + User Template Classes.
- 5f: narrow the default user `:session/:any/:any` cap (HIGHEST blast — held review, audit first).
- 5g: teardown/rollback contract (Class teardown ∘ destroy) + full CI invariants + OQ-2 migration.
