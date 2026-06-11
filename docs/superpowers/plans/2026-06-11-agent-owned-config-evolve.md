# Agent-Owned Config-Evolve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move config-application (today `Ezagent.Behavior.ConfigUpdate` on the socialware Session) onto the Agent entity as `Ezagent.Behavior.ConfigEvolve`, dissolving the #607 confused-deputy: the agent writes its own config under its own authority; the socialware Turn only settles the delta and dispatches the apply to the target agent.

**Architecture:** Two steps, two callers (spec rev 3). Step 1 `apply_config_delta` runs ON the agent (gated by the agent's manage-cap), writing the immutable object + pointer to `ConfigStore` (the **durable source of truth**) synchronously and object→pointer ordered. Step 2 is the agent projecting that pointer into its own `Sandbox` cache via a post-commit `DeferredDispatch` self-dispatch under a self-scoped `Sandbox.write_path` cap; a boot reconciliation in `ConfigEvolve.activate` closes the crash window. The Sandbox pointer is demoted from source to spawn-cache, so the spawn read path is untouched.

**Tech Stack:** Elixir umbrella (ezagent), `Ezagent.Lifecycle` behaviors, CapBAC, `Ezagent.Invocation`/`Cmd`/`DeferredDispatch`, Ecto/`Ezagent.Repo`, ExUnit. Spec: `docs/superpowers/specs/2026-06-11-agent-owned-config-evolve-design.md`.

**Working tree:** `/private/tmp/config-evolve` on branch `config-evolve-to-agent` (off origin/main). Each PR below = its own commit series; codex-review + admin-merge after each. Full umbrella `mix test` from the worktree root is the gate. TEST DB only — never `mix ecto.migrate` against dev/prod.

> **⚠ REV-4 CORRECTIONS (codex round-3 — these OVERRIDE the task bodies below where they conflict; see spec rev-4 STATUS):**
> - **H1 (PR-2 Task 2.1/2.3):** there is **no `project_cascade_to_sandbox` action**. Step 1 (`apply_config_delta`, which `reads_siblings([:sandbox])`) computes the new `respawn_template_data` in-handler and emits `{:dispatch_after_commit, Cmd(self, :write_path, rtd)}` **directly to `sandbox.write_path`**. `required_caps`: `apply_config_delta`/`repoint_config` → `cap(:agent, Manage, :any)`; `reconcile_cascade` → `cap(:agent, ConfigEvolve, :reconcile_cascade)`; the emitted sandbox write is gated by `cap(:agent, Sandbox, :write_path)`. Agent base self-caps gain TWO entries: `cap(:agent, Sandbox, :write_path, instance: self)` AND `cap(:agent, ConfigEvolve, :reconcile_cascade, instance: self)`.
> - **H2 (PR-2 Task 2.4):** boot reconciliation is NOT in `activate/2` (no effects/siblings). Use `post_init/2 → {:continue, :reconcile_cascade} → handle_continue/3` (ExternalMirror precedent, `external_mirror.ex:73`) which schedules a deferred self-dispatch to the `reconcile_cascade` action (`reads_siblings([:sandbox])`) that compares ConfigStore↔Sandbox and emits `Cmd(self, :write_path, rtd)` if divergent.
> - **H3 (PR-3 Task 3.2):** recovery must NOT bootstrap-launder. Record the **approver URI** on the durable settlement at normal settlement; on recovery, re-dispatch with the **approver's re-loaded caps** (re-validated against the agent's manage-cap) — skip+log if the approver no longer holds it. **⚠ awaits Allen's confirmation** (default: this re-validate option; fallback: exclude config-apply from recovery entirely).

---

## File Structure

| File | PR | Responsibility |
|---|---|---|
| `apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex` (moved) | 1 | immutable object + pointer + rollback ledger (durable source) |
| `apps/ezagent_domain_identity/lib/ezagent/socialware/config_object.ex` (moved) | 1 | Ecto schema (table unchanged) |
| `apps/ezagent_domain_identity/lib/ezagent/socialware/config_projection.ex` (moved) | 1 | `object_uri` + spawn-time `resolve_config_dir`/`render_soul` + `register/0` |
| `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex` (new) | 2 | the Agent behavior: step-1 apply/repoint, step-2 projection, boot reconcile |
| `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` (modify) | 2 | register `ConfigEvolve`; grant self-scoped `Sandbox.write_path` cap |
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex` (modify) | 3 | rewire `config_update_effects` → dispatch step-1 to the target agent + recovery principal |
| `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` (modify) | 3/4 | recovery-settlement principal (add); drop #607 `cap(:agent, Sandbox, :read)` |
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/config_update.ex` (delete) | 4 | removed |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/cascade_repoint.ex` (delete) | 4 | folded into ConfigEvolve step 2 |
| `apps/ezagent_domain_socialware/lib/ezagent/entity/socialware_session.ex` (modify) | 4 | remove `ConfigUpdate` from `behaviors/0` |
| `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex` (modify) | 4 | drop `config_updates`/`ConfigUpdate` entries; add `ConfigEvolve` |

**Sequencing rationale:** the OLD path (Turn→ConfigUpdate→ConfigStore+escalated sandbox write) keeps working until PR-3 cuts over, then PR-4 deletes it. Each PR is green on its own.

---

## PR-1 — Relocate ConfigStore / ConfigObject / ConfigProjection to identity (behavior-preserving move)

**Goal:** Move the three durable-config modules from `ezagent_domain_socialware` to `ezagent_domain_identity`, keeping behavior identical (the old `ConfigUpdate` on the session still calls them). `socialware` already depends on `identity`, so the Turn/ConfigUpdate references still resolve. The `config_object` **table is unchanged** (its migration lives in `apps/ezagent_core/priv/repo/migrations/20260618000500_add_socialware_config_store.exs` — leave it).

### Task 1.1: Move the three modules + boot registration

**Files:**
- Move: `apps/ezagent_domain_socialware/lib/ezagent/socialware/config_store.ex` → `apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`
- Move: `…/socialware/config_object.ex` → identity (same relative path)
- Move: `…/socialware/config_projection.ex` → identity
- Move tests: `apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs` → `apps/ezagent_domain_identity/test/ezagent/socialware/config_projection_test.exs`
- Modify: `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:17-20` (remove the `ConfigProjection.register()` call)
- Modify: `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` (add `:ok = Ezagent.Socialware.ConfigProjection.register()` in `start/2`)

- [ ] **Step 1: Move the files with `git mv` (module names UNCHANGED — keep `Ezagent.Socialware.ConfigStore/.ConfigObject/.ConfigProjection`).** Keeping the module names means every caller (`turn.ex`, `config_update.ex`, the relocated `config_store.ex` internal refs) resolves unchanged; only the owning app changes.

```bash
cd /private/tmp/config-evolve
git mv apps/ezagent_domain_socialware/lib/ezagent/socialware/config_store.ex apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex
git mv apps/ezagent_domain_socialware/lib/ezagent/socialware/config_object.ex apps/ezagent_domain_identity/lib/ezagent/socialware/config_object.ex
git mv apps/ezagent_domain_socialware/lib/ezagent/socialware/config_projection.ex apps/ezagent_domain_identity/lib/ezagent/socialware/config_projection.ex
git mv apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs apps/ezagent_domain_identity/test/ezagent/socialware/config_projection_test.exs
mkdir -p apps/ezagent_domain_identity/lib/ezagent/socialware
```

- [ ] **Step 2: Remove the boot register from socialware's application.ex.** Delete the `:ok = ConfigProjection.register()` line at `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:17-20` and its `alias` if now unused.

- [ ] **Step 3: Add the boot register to identity's application.ex.** In `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` `start/2`, after the supervisor children start (or in the same `:ok` sequence the socialware app used), add:

```elixir
:ok = Ezagent.Socialware.ConfigProjection.register()
```

(Match the exact placement pattern socialware used — it called `register()` after `Supervisor.start_link`. Identity must call it at the same lifecycle point.)

- [ ] **Step 4: Verify the move compiles + the UriQuery resolver still registers.** The coupling to core's `FsResolver` is runtime via `Ezagent.UriQuery` (not a compile dep), so no cycle. Run:

```bash
cd /private/tmp/config-evolve && mix compile --warnings-as-errors 2>&1 | tail -20
```
Expected: clean compile (no "module not available", no cycle).

- [ ] **Step 5: Run the relocated + dependent tests.**

```bash
mix test apps/ezagent_domain_identity/test/ezagent/socialware/config_projection_test.exs \
         apps/ezagent_domain_socialware/test/integration/config_consume_test.exs \
         apps/ezagent_domain_socialware/test/integration/config_update_test.exs 2>&1 | tail -20
```
Expected: all PASS (behavior identical; only the owning app changed).

- [ ] **Step 6: Run the UriQuery arch scan** (the resolver ownership moved):

```bash
mix ezagent.arch.scan uri_query 2>&1 | tail -10
```
Expected: green (the `:socialware_config_dir` resolver still registers, now from identity).

- [ ] **Step 7: Commit.**

```bash
git add -A && git commit -m "refactor(config): relocate ConfigStore/ConfigObject/ConfigProjection socialware->identity

Behavior-preserving move (module names unchanged; table unchanged). Boot
register moves to identity. socialware->identity dep already exists, so Turn/
ConfigUpdate references resolve. Prereq for agent-owned config-evolve."
```

### Task 1.2: PR-1 gate — full suite + arch fitness, then codex + merge

- [ ] **Step 1: Full umbrella test + arch gates.**

```bash
cd /private/tmp/config-evolve && mix test 2>&1 | tail -15
mix ezagent.check_invariants.lifecycle 2>&1 | tail -5
mix ezagent.arch.scan 2>&1 | tail -10
```
Expected: all green.

- [ ] **Step 2: Push + codex review + admin-merge.** Orchestrator action (NOT the implementing subagent): push the branch, `/codex:adversarial-review`, address findings, then `gh pr merge --admin --squash` per the established cadence. Feishu heads-up before push.

---

## PR-2 — `Ezagent.Behavior.ConfigEvolve` on the Agent (step 1 + step 2 + boot reconcile)

**Goal:** Add the new Agent behavior with the full two-step apply, fully unit-tested in isolation. NOT yet wired into Turn (that is PR-3), so the old path still runs. Grant the agent its self-scoped `Sandbox.write_path` cap.

### Task 2.1: Behavior skeleton + slice + manage-cap gate (step-1 authority, no side effects yet)

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs`
- Modify: `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` (register `Ezagent.Behavior.ConfigEvolve` in `behaviors/0`)

- [ ] **Step 1: Write the failing authority test.**

```elixir
defmodule Ezagent.Behavior.ConfigEvolveTest do
  use Ezagent.DataCase, async: false
  alias Ezagent.{Invocation, URI}
  alias Ezagent.Entity.Agent

  setup do
    agent = URI.entity(:team_alpha, :agent, "ce-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    %{agent: agent}
  end

  test "apply_config_delta is DENIED without the agent's manage-cap", %{agent: agent} do
    target = URI.new!("#{URI.to_string(agent)}?action=config_evolve.apply_config_delta")
    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: target, mode: :call, args: %{turn_id: "t1"},
               ctx: %{caller: URI.entity(:team_alpha, :user, "stranger"), caps: MapSet.new(), reply: {:caller_inbox, self()}}
             })
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`config_evolve.apply_config_delta` action does not exist):

```bash
mix test apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs -v 2>&1 | tail -10
```
Expected: FAIL (no such action / behavior not registered).

- [ ] **Step 3: Create the behavior with the manage-cap-gated actions (no side effects yet — return `{:ok, %{}, []}`).**

```elixir
defmodule Ezagent.Behavior.ConfigEvolve do
  @moduledoc """
  Agent-owned config evolution (spec 2026-06-11 rev 3). Two steps:
  STEP 1 `apply_config_delta`/`repoint_config` — gated by the agent's manage-cap;
  writes the immutable object + pointer to ConfigStore (durable source), then
  emits a post-commit projection. STEP 2 `project_cascade_to_sandbox` — the
  agent projects the pointer into its own Sandbox cache (self-scoped cap).
  Owns the `:config_evolve` slice (applied-turn markers).
  """
  use Ezagent.Lifecycle, state_slice: :config_evolve
  alias Ezagent.Socialware.{ConfigStore, ConfigProjection}

  reads_siblings([:sandbox])

  action(:apply_config_delta, args: %{turn_id: :string},
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:apply_config_delta], modes: [:call],
    description: "Apply a settled config delta to THIS agent (step 1, durable)")

  action(:repoint_config,
    args: %{layer: :atom, workspace_uri: :uri, subject_uri: :uri, key: :string, config_id: :string},
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:repoint_config], modes: [:call],
    description: "Rollback/advance THIS agent's config pointer (step 1)")

  action(:project_cascade_to_sandbox, args: %{},
    returns: %{projected: :boolean}, caps: [:project_cascade_to_sandbox], modes: [:cast],
    description: "Project the durable pointer into this agent's Sandbox cache (step 2, self)")

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{applied: %{}}}

  def required_caps do
    %{
      apply_config_delta: Ezagent.Capability.cap(:agent, Ezagent.Behavior.Manage, :any),
      repoint_config: Ezagent.Capability.cap(:agent, Ezagent.Behavior.Manage, :any),
      project_cascade_to_sandbox: Ezagent.Capability.cap(:agent, Ezagent.Behavior.Sandbox, :write_path)
    }
  end

  def data_owner(%URI{scheme: "entity"} = agent_uri), do: agent_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  def handle_apply_config_delta(_args, _ctx), do: {:ok, %{}, []}
  def handle_repoint_config(_args, _ctx), do: {:ok, %{}, []}
  def handle_project_cascade_to_sandbox(_args, _ctx), do: {:ok, %{projected: true}, []}
end
```

- [ ] **Step 4: Register on the Agent Kind.** In `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` `behaviors/0`, add `Ezagent.Behavior.ConfigEvolve` to the list (after `Sandbox`).

- [ ] **Step 5: Run the test — expect PASS** (the action exists + the manage-cap gate denies the stranger):

```bash
mix test apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs -v 2>&1 | tail -10
```
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add -A && git commit -m "feat(config-evolve): ConfigEvolve behavior skeleton + manage-cap gate on Agent"
```

### Task 2.2: Step-1 durable apply (port write_config + put_pointer, MINUS the sandbox repoint)

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex`
- Reference (port FROM): `apps/ezagent_domain_socialware/lib/ezagent/behavior/config_update.ex:88-220` (`handle_apply_delta`, `handle_repoint`, `validate_and_normalize`, `settled_turn`, `config_delta`, `attrs_from_delta`) — port everything EXCEPT the `repoint_agent_layer/2` call (that is step 2).

- [ ] **Step 1: Write the failing test — apply writes object + pointer, idempotency marker recorded.**

```elixir
test "apply_config_delta writes the immutable object + pointer (manager authorized)", %{agent: agent} do
  manager = grant_manage_cap(agent)            # helper: mint cap(:agent, Manage, :any, instance: agent) to manager
  turn_id = seed_settled_turn(agent, %{"soul_md" => "v2"})  # helper: a settled turn carrying a config_delta for `agent`
  target = URI.new!("#{URI.to_string(agent)}?action=config_evolve.apply_config_delta")
  assert {:ok, %{config_id: cid}} =
           Invocation.dispatch(%Invocation{target: target, mode: :call, args: %{turn_id: turn_id},
             ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}})
  assert {:ok, _object} = Ezagent.Socialware.ConfigStore.fetch_object(cid)
  assert Ezagent.Socialware.ConfigStore.applied_for_turn?(turn_id)
end
```
(Write `grant_manage_cap/1` + `seed_settled_turn/2` helpers in the test module, porting the fixtures from `config_update_test.exs:260-360`.)

- [ ] **Step 2: Run — expect FAIL** (handler is a stub; no object written).

- [ ] **Step 3: Implement `handle_apply_config_delta`/`handle_repoint_config` by porting `config_update.ex` step 1.** Port `validate_and_normalize`, `settled_turn`, `config_delta`, `attrs_from_delta`, `ConfigStore.merge_delta` → `write_config` → `put_pointer`, and the applied-marker slice write. **Remove** the `repoint_agent_layer(attrs, object.id)` call (step 2 replaces it). After `put_pointer`, append the step-2 trigger effect:

```elixir
# ...after {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(...)
applied = ctx.read.(:applied, %{})
reply = %{config_id: object.id, previous_config_id: previous}
step2 = Ezagent.Cmd.new(ctx.self_uri, :project_cascade_to_sandbox, %{}, %{caller: ctx.self_uri, caps: ctx.caps, reply: :ignore})
{:ok, reply, [{:set, :applied, Map.put(applied, turn_id, reply)}, {:dispatch_after_commit, step2}]}
```

(Confirm the `:dispatch_after_commit` effect tuple shape against `apps/ezagent_core/lib/ezagent/behavior/effects.ex` — codex confirmed `{:dispatch_after_commit, %Ezagent.Cmd{}}` is accepted. The `validate_and_normalize` confused-deputy authority guard from config_update.ex is now REDUNDANT — the manage-cap gate + self-subject replace it — but keep the field validation/normalization, drop only the subject-authority predicate.)

- [ ] **Step 4: Run — expect PASS.**

```bash
mix test apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs -v 2>&1 | tail -15
```

- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "feat(config-evolve): step-1 durable apply (object+pointer) + post-commit step-2 trigger"
```

### Task 2.3: Step-2 sandbox projection (self-dispatch) + self-scoped Sandbox cap grant

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex` (`handle_project_cascade_to_sandbox`)
- Reference (port FROM): `apps/ezagent_domain_socialware/lib/ezagent/socialware/cascade_repoint.ex:57-140` (the read-modify-write of `respawn_template_data.cascade_resolution.user_layer_uri`)
- Modify: the agent self-cap grant site (`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` — the `grant_initial_caps` path around `agent.ex:93`)

- [ ] **Step 1: Write the failing test — after apply, the agent's Sandbox cascade pointer is refreshed.**

```elixir
test "step-2 projects the pointer into the agent's own Sandbox cache", %{agent: agent} do
  manager = grant_manage_cap(agent)
  turn_id = seed_settled_turn(agent, %{"soul_md" => "v2"})
  {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id)   # helper wrapping the dispatch
  # the deferred cast runs on the next mailbox turn; sync the agent's mailbox:
  :ok = Ezagent.KindServerTestSync.drain(agent)                     # helper: call a noop to flush the deferred cast
  sandbox = read_sandbox(agent)
  uri = get_in(sandbox, [:respawn_template_data, "cascade_resolution", "user_layer_uri"])
  assert uri == URI.to_string(Ezagent.Socialware.ConfigProjection.object_uri(workspace_of(agent), cid))
end
```

- [ ] **Step 2: Run — expect FAIL** (projection is a stub; cascade pointer unchanged).

- [ ] **Step 3: Implement `handle_project_cascade_to_sandbox`** by porting `CascadeRepoint`'s read-modify-write, but as the agent's OWN handler: read the current `ConfigStore` pointer for `(self, :user, key)`, read `cascade_resolution` via `ctx.siblings[:sandbox]` (the `reads_siblings([:sandbox])` injection), compute the new `user_layer_uri`, and self-dispatch `sandbox.write_path`:

```elixir
def handle_project_cascade_to_sandbox(_args, ctx) do
  with {:ok, object_id} <- ConfigStore.current_user_object(ctx.self_uri),     # current pointer for (agent,:user,key)
       sandbox when is_map(sandbox) <- get_in(ctx, [:siblings, :sandbox]),
       object_uri <- ConfigProjection.object_uri(Ezagent.Capability.workspace_of(ctx.self_uri), object_id),
       updated_rtd <- put_user_layer(sandbox[:respawn_template_data], object_uri) do
    cmd = Ezagent.Cmd.new(ctx.self_uri, :write_path,
            %{config_dir_path: sandbox[:config_dir_path], template_class: sandbox[:template_class], respawn_template_data: updated_rtd},
            %{caller: ctx.self_uri, caps: ctx.caps, reply: :ignore})
    {:ok, %{projected: true}, [{:dispatch, cmd}]}
  else
    _ -> {:ok, %{projected: false}, []}   # logged via DeferredDispatch's cast-error logging; boot reconcile heals
  end
end
```
(Port `put_user_layer/2` from `cascade_repoint.ex:91-96`. Add `ConfigStore.current_user_object/1` if not present — a thin wrapper over `resolve(:user, ...)` returning the object id.)

- [ ] **Step 4: Grant the agent its self-scoped `Sandbox.write_path` cap at create.** In the agent's `grant_initial_caps` path (`agent.ex` ~93), add to the seeded caps:

```elixir
Ezagent.Capability.cap(:agent, Ezagent.Behavior.Sandbox, :write_path, instance: agent_uri, workspace_uri: workspace_uri)
```
(So the step-2 self-dispatch — caller == the agent — matches via `match.ex` instance equality; `runtime.ex:436` resolves the needed-cap instance from the dispatch target == self.)

- [ ] **Step 5: Run — expect PASS.**

- [ ] **Step 6: Commit.**

```bash
git add -A && git commit -m "feat(config-evolve): step-2 sandbox projection (self-dispatch) + self-scoped Sandbox cap"
```

### Task 2.4: Boot reconciliation in `activate`

**Files:** Modify `config_evolve.ex` (`activate/2`)

- [ ] **Step 1: Write the failing test — crash between commit and projection, boot reconciles.**

```elixir
test "boot reconciliation re-projects when the Sandbox cache diverges from ConfigStore", %{agent: agent} do
  manager = grant_manage_cap(agent)
  turn_id = seed_settled_turn(agent, %{"soul_md" => "v2"})
  {:ok, %{config_id: cid}} = apply_delta_drop_step2(agent, manager, turn_id)  # helper: apply but suppress the deferred cast
  assert stale_sandbox_pointer?(agent)                                        # cache NOT yet refreshed
  :ok = restart_agent(agent)                                                  # triggers activate
  uri = sandbox_user_layer(agent)
  assert uri == URI.to_string(ConfigProjection.object_uri(workspace_of(agent), cid))
end
```

- [ ] **Step 2: Run — expect FAIL** (default `activate` is a noop).

- [ ] **Step 3: Implement `activate/2` reconciliation.**

```elixir
@impl Ezagent.Lifecycle
def activate(state, ctx) do
  case ConfigStore.current_user_object(ctx.self_uri) do
    {:ok, object_id} ->
      sandbox = get_in(ctx, [:siblings, :sandbox])
      current = sandbox && get_in(sandbox, [:respawn_template_data, "cascade_resolution", "user_layer_uri"])
      want = URI.to_string(ConfigProjection.object_uri(Ezagent.Capability.workspace_of(ctx.self_uri), object_id))
      if current != want do
        cmd = Ezagent.Cmd.new(ctx.self_uri, :project_cascade_to_sandbox, %{}, %{caller: ctx.self_uri, caps: ctx.caps, reply: :ignore})
        {:ok, state, [{:dispatch_after_commit, cmd}]}
      else
        {:ok, state}
      end
    _ -> {:ok, state}
  end
end
```
(Confirm `activate/2` may return effects; if the lifecycle only allows `{:ok, state}`, emit the reconcile via the `activated/2` hook or a `handle_continue`-style post_init instead — check `lifecycle.ex:83` callback contract and adapt. `reads_siblings([:sandbox])` makes `ctx.siblings[:sandbox]` available at activate.)

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit.** Then PR-2 gate (full `mix test` + lifecycle/arch scans) + codex + admin-merge (orchestrator).

```bash
git add -A && git commit -m "feat(config-evolve): boot reconciliation closes the crash window in activate"
```

---

## PR-3 — Rewire Turn to dispatch step-1 to the target agent (cut over)

**Goal:** `Turn.config_update_effects` stops self-dispatching `apply_delta` to the session and instead dispatches `config_evolve.apply_config_delta` to the **target agent** (`subject_uri` from the delta), carrying a caller that holds the agent's manage-cap. Handle the recovery path's principal. After this, the old `ConfigUpdate` is dead code (deleted in PR-4).

### Task 3.1: Rewire the normal settlement path

**Files:** Modify `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex:569-597`

- [ ] **Step 1: Write the failing test — a settled turn dispatches the apply to the target agent and the agent's config is evolved.** (Port from `config_update_test.exs`, but assert the dispatch targets the AGENT and the agent's ConfigStore pointer advances; the manager who settles holds the agent's manage-cap.)

- [ ] **Step 2: Run — expect FAIL** (Turn still self-dispatches `:apply_delta` to the session).

- [ ] **Step 3: Implement the rewire.** Change `config_update_effects` to extract `subject_uri` from the matched `delta` and target the agent's `config_evolve.apply_config_delta`:

```elixir
defp config_update_effects(turn_id, %{result: %{config_delta: %{} = delta}}, ctx, dispatch_kind) do
  case Map.get(delta, :subject_uri) || Map.get(delta, "subject_uri") do
    nil -> []
    subject ->
      target = subject |> ensure_uri()
      [effect(dispatch_kind, Cmd.new(target, :apply_config_delta, %{turn_id: turn_id}, dispatch_ctx(ctx)))]
  end
end
defp config_update_effects(_turn_id, _turn, _ctx, _dispatch_kind), do: []
```
(`ensure_uri/1` = pass-through for `%URI{}` / `URI.new!/1` for binaries. The dispatch carries `dispatch_ctx(ctx)`'s caller+caps — the settling manager.)

- [ ] **Step 4: Run — expect PASS.** **Step 5: Commit.**

### Task 3.2: Recovery-path principal

**Files:** Modify `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex` (`dispatch_ctx`/recovery) + `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`

- [ ] **Step 1: Write the failing test — a settlement RECOVERY (no original caller) still applies to the agent** (recovery path must carry a principal that holds the agent's manage-cap). Drive `handle_signal({:ezagent_recover_settlements}, _)` and assert the agent's config advances.

- [ ] **Step 2: Run — expect FAIL** (recovery defaults caller to the session with bootstrap caps → manage-cap denied).

- [ ] **Step 3: Implement.** Add a scoped system principal for settlement-recovery config application that holds `cap(:agent, Ezagent.Behavior.Manage, :any)` (mirroring how `system://agent-internal` is declared in `catalog.ex`), and make the recovery `dispatch_ctx` use it for the `apply_config_delta` dispatch. (Keep the NORMAL path on the settling caller.)

- [ ] **Step 4: Run — expect PASS.** **Step 5: Commit.** Then PR-3 gate + codex + admin-merge.

---

## PR-4 — Delete the old path + metadata cleanup

**Goal:** Remove `ConfigUpdate`, `CascadeRepoint`, the #607 escalation, and the stale behavior-set/SocialwareSession metadata. Pure deletion + green.

### Task 4.1: Delete ConfigUpdate + CascadeRepoint; update SocialwareSession + behavior_set

**Files:**
- Delete: `apps/ezagent_domain_socialware/lib/ezagent/behavior/config_update.ex`, `apps/ezagent_domain_socialware/lib/ezagent/socialware/cascade_repoint.ex`
- Delete/relocate tests: `apps/ezagent_domain_socialware/test/integration/config_update_test.exs` (its cases now live in `config_evolve_test.exs` + the Turn rewire test — remove the file)
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/entity/socialware_session.ex:15-21` (remove `Ezagent.Behavior.ConfigUpdate` from `behaviors/0`)
- Modify: `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex:165-183` (remove `config_updates: ConfigUpdate` + the `ConfigUpdate => %{turns: :required, chat: :required}` `@required_reads` entry; add `config_evolve: Ezagent.Behavior.ConfigEvolve` to the slice map and `Ezagent.Behavior.ConfigEvolve => %{sandbox: :required}` to `@required_reads`)

- [ ] **Step 1: Delete the two modules + the old integration test file.**

```bash
git rm apps/ezagent_domain_socialware/lib/ezagent/behavior/config_update.ex \
       apps/ezagent_domain_socialware/lib/ezagent/socialware/cascade_repoint.ex \
       apps/ezagent_domain_socialware/test/integration/config_update_test.exs
```

- [ ] **Step 2: Remove `ConfigUpdate` from `SocialwareSession.behaviors/0`** (and any now-unused alias).

- [ ] **Step 3: Update `behavior_set.ex`** — drop the `config_updates`/`ConfigUpdate` entries, add the `ConfigEvolve` slice + `%{sandbox: :required}` read closure.

- [ ] **Step 4: Compile — expect a few unused-alias warnings to fix, no missing-module errors** (all callers were rewired in PR-3):

```bash
mix compile --warnings-as-errors 2>&1 | tail -15
```

- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "refactor(config): delete ConfigUpdate/CascadeRepoint; update SocialwareSession + behavior_set"
```

### Task 4.2: Drop the #607 `system://agent-internal` Sandbox:read escalation

**Files:** Modify `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:247-271`

- [ ] **Step 1: Write/adjust the test — `system://agent-internal` no longer grants `cap(:agent, Sandbox, :read)`** (the #607 entry), and config-evolve still works (it uses the self-cap + in-process sibling read). A focused catalog test asserting the principal's cap list excludes `cap(:agent, Sandbox, :read)`.

- [ ] **Step 2: Run — expect FAIL** (entry still present).

- [ ] **Step 3: Remove the `Capability.cap(:agent, Sandbox, :read)` entry** added for #607 (keep `:write_path` — still used by `Agent.do_record_sandbox_state/3`). Replace the #607 comment block with a note that the read was dropped when config-evolve moved to the agent (mirror the ApiKeys-flip comment style).

- [ ] **Step 4: Run — expect PASS.** **Step 5: Commit.**

```bash
git add -A && git commit -m "refactor(catalog): drop #607 system://agent-internal Sandbox:read (config-evolve is agent-owned now)"
```

### Task 4.3: PR-4 gate

- [ ] **Step 1: Full suite + all arch gates + the confused-deputy regression.**

```bash
cd /private/tmp/config-evolve && mix test 2>&1 | tail -15
mix ezagent.check_invariants.lifecycle 2>&1 | tail -5
mix ezagent.arch.scan 2>&1 | tail -12
```
Expected: all green; `cap_check_only_at_chokepoint`, `oversized_modules_gt_1000`, `uri_query`, `cross_file_duplicate_fn`, lifecycle all pass.

- [ ] **Step 2: codex + admin-merge** (orchestrator). After merge, config-evolve is done; proceed to P5 (the union no longer contains `ConfigUpdate`).

---

## Self-Review

**Spec coverage:** §2 seam → PR-1 (relocate) + PR-2/3 (move apply to agent). §3 two-step → PR-2 (step1+step2+boot reconcile). §4 authority → PR-2 (manage-cap gate, self-cap) + PR-3 (recovery principal). §5 data flow → PR-3 (Turn rewire). §6 migration → PR-1 (table unchanged, register move), PR-4 (catalog, behavior_set, SocialwareSession), PR-2 (replay marker moves with the store, used in apply). §7 tests → each task's TDD test maps to a §7 item (authority 1/3b → 2.1/3.1; step-2 projection 2 → 2.3; no-escalation 3 → 4.2; eventual-consistency+reconcile 3c → 2.4; ordering 4 → 2.2; replay 5 → 2.2; confused-deputy regression 6 → 4.1; E2E SW-UPD 7 → 3.1). All covered.

**Placeholder scan:** ports are referenced by exact `file:line` (config_update.ex:88-220, cascade_repoint.ex:57-140) rather than re-transcribed — acceptable for a behavior-preserving port, with the NEW logic (step-2 trigger, projection, reconcile, Turn rewire, recovery principal) shown in full. Helpers (`grant_manage_cap`, `seed_settled_turn`, etc.) are named with their port source.

**Type consistency:** `ConfigEvolve` actions `apply_config_delta`/`repoint_config`/`project_cascade_to_sandbox` used consistently; `ConfigStore.current_user_object/1` introduced in 2.3 and reused in 2.4; the self-cap `cap(:agent, Sandbox, :write_path, instance: self)` defined in 2.3 matches `required_caps` in 2.1.

**Open verification carried into execution (flagged, not deferred-silently):** (a) the exact `:dispatch_after_commit` effect-tuple shape vs `effects.ex`; (b) whether `activate/2` may return effects or the reconcile must use `activated/2`/post_init — both checked at the first failing-test run of their task and adapted in-step.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-06-11-agent-owned-config-evolve.md`. Per the autonomous mandate, execution proceeds **subagent-driven** (fresh subagent per task, two-stage review, ezagent worktree), each PR codex-reviewed + admin-merged by the orchestrator before the next.
