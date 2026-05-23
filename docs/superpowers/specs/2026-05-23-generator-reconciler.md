# Generator → Reconciler (SessionTemplate `converge-to-spec`)

> **Status**: DRAFT rev 1 — 2026-05-23. Author: Claude, per Allen Feishu
> 2026-05-22: *"Generator 现在'原子多步 + 失败回滚'的模型是错的抽象 — 正确的是
> 声明式 SessionTemplate + reconciler(`spawn_from_template/2` 变成 `docker-compose
> up`-style 收敛到 spec 的命令;残留状态是预期的;再跑一次从失败点继续)."*
>
> **Supersedes**: `docs/superpowers/specs/2026-05-22-phase-7-completion.md` §§ that
> describe `do_spawn/4`'s "irreversible side effects + cleanup" model and the
> `cleanup_partial/1` saga (the §"Spawn phase (MEDIUM-5)" framing). Phase-7
> SPEC's *design intent* — the Generator turns a SessionTemplate into a live
> team — stands; this SPEC replaces only the *failure-handling abstraction*.
>
> **Precedent**: `Ezagent.Workspace.Loader` (`apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex`)
> is already this pattern for Workspace templates — load all, re-spawn missing
> members, idempotent re-run, `{:already_started, _}` → no-op, `fresh?`-gated
> bind, errors logged not raised. The Generator should follow the same shape.
>
> **Non-goal**: this SPEC contains NO code changes. The implementation plan is
> in `docs/superpowers/plans/2026-05-23-generator-reconciler-plan.md`.

---

## §0 Why — the abstraction mismatch

`Session.spawn_from_template/2` today is an **atomic-multi-step-then-cleanup**
saga. The latest revision (Phase-7 PR-1..6 + 10 rounds of `cleanup_partial`
hardening) reached this shape:

1. `do_spawn/4` runs a `with` chain of 8 side-effecting steps, each wrapped in
   `guard/2` so any step's failure invokes `cleanup_partial/1`.
2. `cleanup_partial/1` enumerates the side-effect stores it knows about and
   tears each down: live `KindRegistry` pids, `WorkspaceRegistry` bindings,
   `AgentLineage` rows, committed `routing_rules` rows (via the threaded
   `routing_rule_ids`), and (for `update_agent_template`) the Session-Kind
   `template_working_copy` slot tuple.
3. Each codex round expanded the enumeration as a new store / a new failure
   window surfaced (round 7: gate post-spawn obligations on `fresh?`; round 8:
   verify `fresh?: false` ownership; round 9: gated load bind on Loader;
   round 10: spawner-cleans-its-own-spawn).

**Why this never converged.** The enumeration is unbounded. Every new Kind
type, every new registry, every new persistence side-channel adds a store the
Generator and `update_agent_template` must learn to roll back. `cleanup_partial`
has to KNOW about all of them — and a missed store leaves residue that the
NEXT Generator run cannot resolve, because the next run also "rolls back its
own work + leaves the prior residue alone". HIGH count never dropped because
"one more store" remained findable on every audit pass.

**Allen 2026-05-22's model — the right one.** A SessionTemplate is a
**declarative desired-state spec** (set of agent slots + routing rules +
orchestrator + caps + working copy). The Generator's job is **`converge(spec,
current_state)`** — `docker-compose up` semantics:

- partial residue from a previous failed run is the **expected intermediate
  state**, not a corruption;
- re-running the Generator with the same `(SessionTemplate URI, owner URI)`
  pair **continues from the partial state** — already-converged components
  are detected and SKIPPED; missing components are spawned; mis-installed
  routing rules are corrected;
- each per-Kind operation is **already independently atomic** (`SpawnRegistry.spawn`
  is one `DynamicSupervisor.start_child` call; `RuleStore.add` is one SQL
  insert inside one transaction; `WorkspaceRegistry.bind` is one ETS
  upsert);
- the Generator is therefore a **SCRIPT, not a transaction**. Saga rollback
  is the wrong primitive — the right primitive is **idempotent forward
  progress**.

**The precedent already in the codebase.** `Ezagent.Workspace.Loader.load_one/1`
+ `invoke_template/2` already work this way for workspace templates:

```
defp load_one(%{name: name} = decoded) do
  case Workspace.spawn_workspace(name, %{...}) do
    {:ok, _pid} -> instantiate_via_dispatch(decoded.uri) |> spawn_each_child()
    {:error, {:already_started, _pid}} -> instantiate_via_dispatch(...) |> spawn_each_child()
    {:error, reason} -> Logger.warning(...); {name, []}
  end
end
```

— a workspace re-load on phx restart: already-started Workspace → keep it; for
each declared member URI, `SpawnRegistry.spawn(uri)` → `{:already_started, _}`
is the IDEMPOTENT signal; errors logged not raised. The Loader has no
"cleanup_partial" because it does not need one — partial state is the EXPECTED
input, and re-running produces convergence.

The Generator is the exact same shape applied to one SessionTemplate instead
of one Workspace. This SPEC retires the saga and adopts the Loader pattern.

---

## §1 The reconciler contract

### 1.1 Entry point — `Session.spawn_from_template/2` is REPLACED in place

**Decision: replace, not side-by-side.** Phase-7 just landed and there are no
V1-stable external callers of the strict-atomic-or-error contract. The
current call sites are:

| Caller | File | Strict-atomic expectation? |
|---|---|---|
| `EzagentPluginLiveview.SessionLive.handle_event("create_from_template", ...)` | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/session_live.ex` | No — uses `{:ok, _}/{:error, _}` for flash messages; partial+pending is strictly more useful for the UI. |
| `EzagentDomainChat.GenericSessionAcceptance` / test fixtures | `apps/ezagent_domain_chat/test/` | No — assertions are `assert {:ok, %{session_uri: _, orchestrator_uri: _}} = ...`. The reconciler keeps the same success return shape (§1.2). |
| `mix ezagent.session.create` (if any) | `apps/ezagent_core/lib/mix/tasks/` | Audit in PR-A; expected None. |
| `Workspace.Loader` (potential — none today) | — | The Loader instantiates *workspace member templates*, not SessionTemplates. No call. |

No caller depends on "either succeed fully or roll back to zero". Side-by-side
introduction (`reconcile_from_template/2` next to `spawn_from_template/2`)
would create two paths the system has to support; the cost is real (every
future change touches both). **`spawn_from_template/2` becomes the reconciler
in place.** The old code is deleted in the same PR that introduces the new
behaviour, not in a follow-up.

The function name `spawn_from_template/2` is retained — `docker-compose up`
is still called `up`, not `reconcile`. The CHANGE is internal: the function
becomes idempotent and re-entrant.

### 1.2 Signature and return shape

```elixir
@spec spawn_from_template(URI.t(), URI.t()) ::
        {:ok,
          %{
            session_uri: URI.t(),
            orchestrator_uri: URI.t(),
            slots: [{slot_name :: String.t(), worker_uri :: URI.t()}]
          }
        }
      | {:partial,
          %{
            session_uri: URI.t() | nil,
            orchestrator_uri: URI.t() | nil,
            completed: [step_atom()],
            pending: [step_atom()],
            errors: [{step_atom(), term()}]
          }
        }
      | {:error, term()}
```

- **`{:ok, %{...}}`** — full convergence. Identical to today's success shape
  with the addition of the `slots` list (already an internal value; the
  caller previously had to dispatch `chat.read_working_copy` to retrieve
  it — exposing it here keeps the LiveView flash message + the test
  assertion honest without an extra round-trip). Same as today's: idempotent
  re-run of a fully-converged template returns `{:ok, %{...}}` with the
  same URIs.

- **`{:partial, %{...}}`** — one or more steps could not converge in this
  pass, but the failures are **completable** (template Kind not yet alive,
  AgentTemplate slice empty, a slot worker's plugin not yet booted, …). The
  result names exactly what got done (`completed`), what did NOT (`pending`),
  and the per-step error (`errors`). The caller's job is to surface the
  partial state to the operator and decide whether to re-invoke; re-invoking
  with the same `(template URI, owner URI)` continues from where this run
  stopped.

- **`{:error, reason}`** — REFUSED UP FRONT. Reserved for failures that mean
  *no convergence is possible without operator intervention beyond re-running*:
  - `:unauthorized` — owner-cap preflight failed (owner lacks
    `template:instantiate` authority on the SessionTemplate's workspace);
  - `:cross_workspace_denied` — SessionTemplate's workspace ≠ resolved
    `default_workspace_uri` or ≠ a slot's AgentTemplate's workspace
    (the round-2 workspace-isolation invariant; un-completable by re-running);
  - `:session_template_not_populated` — the SessionTemplate Kind has no
    `:template` slice content (a broken template; re-running can't fix it);
  - `:invalid_routing_matcher` / `:invalid_default_workspace_uri` /
    `:invalid_workspace_name` — structural validation failures.

  Critical distinction: `{:error, _}` means *no Session was created*. `{:partial,
  _}` ALWAYS includes a `session_uri` (the Session Kind always converges first,
  see §2 step 3 — the moment the Session URI exists, partial-convergence
  becomes the contract).

### 1.3 The convergence guarantee

For any input `(session_template_uri, owner_uri)` and any current system state:

> **Re-running `spawn_from_template/2` with the same args makes monotonic
> progress toward the SessionTemplate's desired state, terminating in either
> `{:ok, _}` (fully converged) or `{:partial, _}` (some step blocked by an
> external fact the operator must resolve).**

Specifically:

1. **No duplicate spawns.** Already-spawned Session, orchestrator, and slot
   worker Kinds are detected (via the deterministic URI + `KindRegistry.lookup`
   + `AgentLineage.lookup`) and SKIPPED. Convergence with the desired state is
   the gate, not "did this run create it".
2. **No re-installed routing rules.** Already-installed rules (matcher+receivers+scope
   present in `RuleStore.list/1`) are SKIPPED.
3. **No duplicate caps.** `Identity.grant_cap` is already idempotent on
   identical `%Capability{}` (caps are a `MapSet`, set insert).
4. **Routing-install batch atomicity is RETAINED.** The reconciler's *per-rule*
   convergence check decides whether a rule needs adding; the *adding* of any
   missing rules still happens inside one `Repo.transaction` so partial
   routing state cannot survive a mid-batch failure (Phase-7 round-4 HIGH-1
   invariant — the routing-row state space is small enough for one txn).
5. **Errors are NEVER raised in steady-state failure paths.** A step that
   cannot converge on this pass returns a tagged `{:error, reason}` and
   accumulates into `:pending` / `:errors`. The function returns
   `{:partial, _}`; the caller decides whether to retry.

### 1.4 Re-run trigger — explicit only in V1

V1 answer: **the operator (or orchestrator) re-invokes `spawn_from_template/2`
explicitly**. No auto-retry, no Session-Kind-on-restart auto-reconcile, no
background loop. Rationale:

- explicit re-invocation is debuggable (one operator-initiated dispatch
  per attempt);
- the operator sees the `{:partial, _}` report and decides whether the
  pending step is now resolvable (typically yes: "the AgentTemplate's
  plugin booted late, try again");
- auto-reconcile would compound with the current owner-cap preflight (which
  workspace caps were the owner's at the time of re-run?) — Phase-7's CapBAC
  model assumes one-call-one-authority-check. V2 may add an auto-retry hook
  via a scheduler Kind, scoped explicitly.

LiveView affordance: `SessionLive` renders a `Retry instantiation` button when
the latest result was `{:partial, _}`, which re-invokes `spawn_from_template/2`
with the SAME `(template URI, owner URI)`. Operator-facing copy:
*"Instantiation paused. <reason>. Retry to continue from where it stopped."*

---

## §2 The reconcile loop

Given `(session_template_uri, owner_uri)`, the reconciler executes the
following sequence. Each step is INDEPENDENTLY IDEMPOTENT (an already-converged
step is a no-op). A step that cannot converge in this pass populates
`pending` + `errors`; subsequent steps that depend on it ALSO skip and
populate `pending`, but steps that DO NOT depend on it continue (so one
blocked slot does not prevent other slots from converging).

### Step 0 — Preflight (UNCHANGED from Phase-7 round-1..3)

The structural / authority gates run identically to today, BEFORE any side
effects. A failure here returns `{:error, reason}` — these are the
un-completable failures:

- `ensure_template_alive(session_template_uri)` — idempotent demand-spawn;
  `{:already_started, _}` accepted;
- `owner_instantiate_preflight(session_template_uri, owner_uri)` — owner
  must hold `template:instantiate` authority on the SessionTemplate's
  workspace;
- `read_template_content(session_template_uri)` — `template.read` dispatch;
- `resolve_target_workspace(template_content)` — honour
  `default_workspace_uri` (Phase-7 round-1 HIGH-4);
- `preflight_workspace_isolation/3` — the same-workspace rule (Phase-7
  round-2 CRITICAL: SessionTemplate workspace ≡ `default_workspace_uri` ≡
  every slot's AgentTemplate workspace);
- `preflight_agent_slots/1` — every slot's AgentTemplate Kind resolvable;
- `preflight_slot_name_uniqueness/1` — slot name collisions rejected (round
  3);
- `preflight_routing_rules/1` — every matcher round-trips through
  `Matcher.to_json/1`.

These are NOT incremental — they validate the SessionTemplate IS a coherent
spec. A re-run repeats them (cheap; pure reads + a structural validation).

### Step 1 — Ensure Session Kind

```
def ensure_session(template_content, workspace_uri):
  candidate_session_uri = derive_session_uri(template_content, workspace_uri)
  case KindRegistry.lookup(candidate_session_uri):
    {:ok, _pid}            -> {:ok, candidate_session_uri, :already_present}
    :error                 -> SpawnRegistry.spawn(candidate_session_uri)  # idempotent
```

**The deterministic Session URI is the key new property.** Today's
`spawn_fresh_session/1` uses a `System.system_time(:millisecond) +
unique_integer/1` suffix — so every Generator call produces a DIFFERENT
session URI, which makes idempotent re-run impossible. The reconciler MUST
derive the session URI from STABLE inputs:

- For V1 the proposal is `session://<template_class>/<workspace>/<owner_name>-<sessiontemplate_name>`
  (e.g. `session://generic/default/admin-customer-support`) — stable per
  `(template, owner)`, so re-invocation finds the same Session. Trade-off: an
  owner cannot have two concurrent sessions from the same SessionTemplate.
- **Alternative (open question §7-1)**: allow an explicit `session_slug:` opt
  for the caller to disambiguate two concurrent sessions of the same template
  (`session://generic/default/admin-customer-support--shift-2`).

Workspace-bind: `WorkspaceRegistry.bind(session_uri, workspace_uri)` —
already idempotent (the registry's `bind/2` is an ETS put; identical pair is
no-op).

### Step 2 — Ensure Orchestrator

```
def ensure_orchestrator(session_uri, workspace_uri, owner_uri):
  candidate_orchestrator_uri = derive_orchestrator_uri(session_uri)
  # Same shape as today: "cc_orchestrator-#{session_name}"
  case AgentLineage.lookup(candidate_orchestrator_uri) ++ KindRegistry.lookup(...):
    both present + matches expected lineage (spawned_by: owner) -> SKIP
    otherwise                                                    -> Agent.spawn(orch_template, name, ws, owner)
```

`Agent.spawn/4` already returns `{:error, {:already_started, _pid}}` and
the `spawn_or_resume/1` clause maps it to `{:ok, pid}` — INHERENTLY
idempotent. Plus the `{spawned_by: owner_uri}` lineage check ensures we don't
adopt a foreign orchestrator at the same URI (which would mean a corrupted
prior state — surface as `{:error, :orchestrator_foreign_lineage}` →
`{:partial, _}`, operator decides).

### Step 3 — Reconcile each agent slot

For each slot in `template_content.agent_slots`, INDEPENDENTLY:

```
def reconcile_slot(slot_name, agent_template_uri, session_uri, workspace_uri, orchestrator_uri):
  expected_worker_uri = derive_worker_uri(slot_name, session_uri, workspace_uri, agent_template_uri)
  case (KindRegistry.lookup(expected_worker_uri),
        AgentLineage.lookup(expected_worker_uri),
        WorkspaceRegistry.lookup(expected_worker_uri)):
    {{:ok, _pid}, {:ok, ^orchestrator_uri}, {:ok, ^workspace_uri}} ->
      :already_converged  # skip — slot worker exists, lineage + binding match expected
    _ ->
      # one or more facts diverge from desired state — converge via dispatch:
      dispatch(template.instantiate, agent_template_uri, %{
        instance_name: derive_instance_name(slot_name, session_uri),
        workspace_uri: workspace_uri,
        spawned_by: orchestrator_uri
      })
      # The instantiate result's {:ok, workers: [_], fresh?: true|false} drives:
      # - fresh?: true  -> lineage + binding established by spawn_from_template_content/4 (round 7); OK.
      # - fresh?: false -> verify ownership (round 8); if foreign -> {:error, :slot_candidate_not_owned}
      #                    accumulates into pending — operator decides (the OTHER slots still proceed).
```

Slots are reconciled SEQUENTIALLY but INDEPENDENTLY — one slot's failure
does NOT halt the loop. A failed slot becomes a `pending` entry; the next
slot is still reconciled. The reconciler's per-pass output for slots:

```
slots: [
  {"customer-bot",    {:ok,      worker_uri_a}},
  {"escalation-bot",  {:ok,      worker_uri_b}},
  {"compliance-bot",  {:error,   :agent_template_slice_not_populated}}
]
```

`pending` carries `compliance-bot`; the next re-invocation tries again
(presumably after the AgentTemplate's slice was populated). The two
already-converged slots are correctly SKIPPED.

### Step 4 — Reconcile routing rules

For each `(matcher_ast, [slot_name])` in `template_content.routing_rules`:

```
def reconcile_routing_rule(matcher_ast, slot_names, slot_uri_by_name, workspace_uri, owner_uri):
  receiver_uris = slot_names |> Enum.map(&slot_uri_by_name[&1]) |> Enum.reject(&is_nil/1)
  existing_rules = RuleStore.list(table) |> Enum.filter(scope_matches?(_, workspace_uri))
  matching = Enum.find(existing_rules, &(rule.matcher == matcher_ast and rule.receivers == receiver_uris))
  if matching, do: :already_converged, else: {:add, matcher_ast, receiver_uris}
```

After collecting every `{:add, ...}` for this pass, ALL adds run inside ONE
`Repo.transaction` (the Phase-7 round-4 invariant is preserved at the
*batch-of-this-pass* level — a mid-batch failure rolls back ALL of THIS
pass's adds; rules added by PRIOR converged passes are NOT touched).
`load_into_registry/1` runs once after commit.

**A receiver `slot_name` not yet resolved (its slot is `pending`)** — the
matching rule's `receiver_uris` is partially populated; we DEFER adding it
this pass (else we'd install a half-receiver rule that drops the unresolved
target). Deferred rules go into `pending` and are retried next pass.

### Step 5 — Populate `template_working_copy`

`chat.set_working_copy` is a slice replace today; the reconciler writes the
desired-state working copy on every pass (idempotent: identical content =
no slice change = no snapshot row write per the `:on_change` policy). The
`agent_slots` list passed in is the CONVERGED slots from step 3 (so a
`pending` slot's tuple is the prior pass's value, NOT a freshly-empty
entry — convergence MUST be monotonic from the working-copy's perspective).

### Step 6 — Grant scoped caps to orchestrator

Caps #1 (`{:within_session, S}`) and #2 (`{:spawned_by, orch}`) and
the delegable subset of caps #3/#4 (the template caps gated by owner-cap
preflight, Phase-7 round-1 §1.4) all dispatch via `identity.grant_cap`.
`grant_cap` is ALREADY idempotent (User-Kind caps are a `MapSet`; granting
the same cap twice is a set insert — no-op). No reconciler-side check
needed: just dispatch the four grants every pass; idempotent.

### Step 7 — Register MCP context

`Ezagent.Orchestrator.McpRegistry.register/2` is an ETS put keyed by
orchestrator URI. Same value twice = no observable change. Idempotent;
just call it every pass.

### Outcome assembly

After all 7 steps:

- if `pending == []` and `errors == []` → `{:ok, %{session_uri, orchestrator_uri, slots: [{name, uri}, ...]}}`
- otherwise → `{:partial, %{session_uri, orchestrator_uri, completed, pending, errors}}`

A pass that's purely a successful re-run of a fully-converged template
returns `{:ok, _}` with `completed: [:session, :orchestrator, :slot_*,
:routing, :working_copy, :caps, :mcp_context]` and zero pending — useful
for the LV "everything is healthy" indicator.

---

## §3 What goes away — the `cleanup_partial` saga

The following code is **DELETED** in the rewrite PR (§6 PR-B). Specific
file:line references against today's `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`
(lengths from a 2026-05-23 read):

| Symbol | Lines | Why deleted |
|---|---|---|
| `do_spawn/4` (the `with` chain wrapped in `guard/2`) | session.ex:317-442 | Replaced by `reconcile_loop/3` that calls 7 independently-idempotent step fns. |
| `guard/2` (all 3 clauses) | session.ex:456-467 | The accumulator scaffolding for the saga; reconciler has no accumulator (each step's outcome merges into `pending`/`errors` directly). |
| `cleanup_partial/1` | session.ex:497-542 | The 5-store teardown enumeration; partial residue is now the expected input to the next pass. |
| `terminate_kind/1` | session.ex:549-563 | Only the saga teardown calls it from Generator code. Other call sites (test fixtures) use `Ezagent.Kind.terminate/1` directly; the wrapper is dead. |
| `safe/1` | session.ex:565-571 | Only used by `cleanup_partial/1`. |

**The following code is KEPT** (Phase-7 round-1..3 + round-7..10 invariants
that survive the model change):

| Symbol | Why retained |
|---|---|
| `owner_instantiate_preflight/2` | The owner-cap gate — the un-completable failure case. The reconciler still refuses up-front. |
| `preflight_workspace_isolation/3` + `same_workspace/3` + `slots_in_workspace/2` | The cross-workspace invariant. Un-completable; rejected up-front. |
| `preflight_agent_slots/1`, `preflight_slot_name_uniqueness/1`, `preflight_routing_rules/1` | Structural validation of the SessionTemplate as a spec. Cheap pure reads — re-run-safe. |
| `resolve_target_workspace/1`, `validate_workspace_name/2` | The HIGH-4 honouring of `default_workspace_uri`. Pure resolution. |
| `read_template_content/1` | Dispatched read — idempotent. |
| `session_discriminator/1`, `agent_template_flavor/1` | Pure URI derivation helpers used by slot reconciliation. |
| `instantiate_one_slot/5` (minus its `{:error, reason, partial_slots}` 3-tuple plumbing) — the body that dispatches `template.instantiate` + `verify_slot_candidate_ownership/5` | The per-slot dispatch. The reconciler still uses it; only the partial-accumulator return form goes away (the reconciler accumulates outcomes itself). |
| `verify_slot_candidate_ownership/5` | The round-8 ownership gate for `fresh?: false` workers. Still needed: an adopted worker MUST be ours to count as converged. |
| `install_routing_rules/5` → renamed `add_missing_routing_rules/5` | Body restructured (no more "commit + thread IDs for cleanup"). The Phase-7 round-4 SQL-transaction-per-pass invariant STAYS: this pass's adds are atomic. |
| `populate_working_copy/5` | Idempotent slice replace. |
| `grant_scoped_caps/3` + `delegable_template_caps/3` | Idempotent grants. |
| `register_orchestrator_mcp_context/5` | Idempotent ETS put. |

The `Workspace.Loader.gated_load_bind/3` + `bind_one_gated/3` + the
`fresh?: false → adopt-only-if-owned` discipline are KEPT (the Loader is the
PRECEDENT; the Generator adopts the same gating in §2 step 3).

---

## §4 `update_agent_template` under the reconciler model

The same "wrong abstraction" diagnosis applies to `Orchestrator.Tools.update_agent_template/3`.
Today it is a **two-phase rollback-safe swap** (Phase-7 PR-5 §2.1 row 3 +
round 4 HIGH-1 + round 5-7 manual-repair machinery). The state space is
identical to the Generator's: a slot has a (slot_name, agent_template_uri,
worker_uri, generation) tuple; the desired state is "(slot_name,
new_template_uri, new_worker_uri, generation+1)"; existing state is the
current tuple. Converge.

### 4.1 The reconciler shape for per-slot update

```
def update_agent_template(slot_name, new_agent_template_uri, opts):
  session_uri = opts[:session_uri]
  workspace_uri = opts[:workspace_uri]
  owner_uri = opts[:caller]
  current_slot = find_slot_tuple(session_uri, slot_name)  # {name, src, worker, gen}

  desired_state = %{
    slot_name: slot_name,
    template_uri: new_agent_template_uri,
    generation: current_slot.generation + 1,
    worker_uri: derive_worker_uri(slot_name, session_uri, new_agent_template_uri, current_slot.generation + 1),
    routing_target: <as above>
  }

  reconcile_slot_to(desired_state, current_slot, session_uri, workspace_uri, owner_uri)
```

The convergence routine:

1. **Detect** — if `current_slot.worker_uri == desired_state.worker_uri` AND
   the worker is alive AND lineage matches: **already converged**, return
   `{:ok, current_slot.worker_uri}`. (This is the cc→cc same-flavor case
   that today's `update_agent_template` handles via the generation bump;
   the reconciler handles it via "already converged" — no work needed.)

2. **Ensure new worker exists** — `template.instantiate` on
   `new_agent_template_uri` with the generation-bumped instance name
   (idempotent: existing = adopted-if-owned, missing = freshly created).
   The Phase-7 round-5..7 `require_fresh_candidate` discipline is preserved
   for the SWAP path — adopting a foreign worker would re-parent it, the
   round-8 ownership gate prevents that.

3. **Repoint routing** — for every rule whose receiver is
   `current_slot.worker_uri`, the desired state is "receiver
   = desired_state.worker_uri". The Phase-7 round-4 ONE-TRANSACTION-FOR-ALL-REPOINTS
   invariant is KEPT (a partial repoint is observable; the swap of two
   receiver URIs must be atomic at the routing layer). On rollback of THIS
   transaction the swap REMAINS at "new worker exists, but routing didn't
   move" — which on a re-invocation is detected: still incomplete, repoint
   again. The pre-reconciler "revert slot + terminate new worker on
   routing failure" is GONE — the reconciler just leaves the new worker
   alive and the next invocation completes the repoint.

4. **Commit slot tuple** — `chat.set_working_copy_slot` writes the new
   tuple. Idempotent at the slice level (already-set = no slice change =
   no snapshot write).

5. **Terminate old worker** — once routing + slot both confirm the new
   worker, the OLD worker is no longer reachable. `Ezagent.Kind.terminate(old_worker_uri)`.
   Already idempotent (terminating a dead pid is `{:error, :not_found}`).
   Failure to terminate is logged + `:pending`-noted, not fatal.

**What goes away from `update_agent_template`:**

- `abort_swap_after_repoint_rollback/_` (tools.ex:1123-1188) — the post-rollback
  manual revert. The reconciler doesn't revert; it just re-runs and continues.
- `halt_routing_revert_failed/_` (tools.ex:1189-1221) — the FAIL-SAFE halt
  for recovery-of-recovery double-failure. There is no recovery in the
  reconciler model; there is only "did this step converge".
- `manual_repair_error/_` (tools.ex:1222-1261) — the safe-degraded
  `{:update_needs_manual_repair, _}` error path. Replaced by `{:partial, _}`
  with the per-step diagnostics — operator sees exactly what state the
  system is in, re-invokes to converge.
- `rollback_slot_to_old/_` (tools.ex:1262-1309) — slot revert. Same logic.
- `compensate_orphan_worker/4` (tools.ex:301-...) — the orphan teardown
  on slot-commit failure. The reconciler treats the new worker as a
  valid intermediate state (it's lineaged + bound; the slot just hasn't
  moved yet); next invocation completes the move.

**What stays:**

- `do_update_agent_template/8` body, restructured around the reconcile loop
  above. Still uses `preflight_template_read/_`, `preflight_swap_uniqueness/_`,
  `preflight_candidate_uri_free/_`, the generation-bump, the
  `commit_slot_step2/_` slot-write (via `set_working_copy_slot`).
- `repoint_routing_rules/2` body (tools.ex:910-965) — the SQL transaction
  routing repoint. Still atomic at the SQL layer; what changes is what
  happens on its failure (nothing — the next pass retries).
- `maybe_terminate_old/4` (tools.ex:1310-1330) — the post-success
  termination. Becomes step 5 above.

The result: `update_agent_template` shrinks from ~900 lines (lines 379-1330)
to ~250 lines, all linear, no `case`-branching for recovery paths.

---

## §5 Per-Kind idempotency audit

Each Kind type the reconciler touches must satisfy: **"already-present means
no-op + return the existing URI; otherwise create."** The audit:

| Kind | Idempotency status | Action required |
|---|---|---|
| **Session Kind** (`Ezagent.Entity.Session`) | NEEDS WORK: today's `spawn_fresh_session/1` always allocates a NEW URI (`gen-<millis>-<unique_int>`); reconcile-by-URI requires a DETERMINISTIC URI from `(template, owner)`. | PR-A: introduce `derive_session_uri(template_content, workspace_uri, owner_uri)`. Stable per `(template, owner)`. See §7-1 for the slug-disambiguation question. |
| **Orchestrator Agent Kind** (cc-flavor) | ALREADY IDEMPOTENT. `Agent.spawn/4` calls `SpawnRegistry.spawn` which returns `{:error, {:already_started, _pid}}`; `spawn_or_resume/1` already maps that to `{:ok, pid}`. The reconciler additionally checks `AgentLineage.lookup` to confirm the existing orchestrator is OURS (lineaged from this owner). | NO CHANGE needed. The lineage check is a reconciler-side guard, not an Agent-Kind change. |
| **Worker Agent Kinds** (cc/echo/curl flavors) | ALREADY IDEMPOTENT via the round-6 `{:ok, workers, %{fresh?: false}}` adoption path + round-7 `fresh?`-gated obligations + round-8 ownership gate. The dispatch `template.instantiate` returns the `fresh?` signal; the reconciler uses it to decide adoption-vs-creation. | NO CHANGE in the spawn path. Reconciler-side: implement "expected URI present + ownership matches → :already_converged" detection. |
| **AgentTemplate Kind** (`Ezagent.Entity.AgentTemplate`) | ALREADY IDEMPOTENT (read-only from reconciler's perspective). `:template` slice `:write` is mutable + plain-replace (Phase-7 rev-5 — AgentTemplate is versionless). Reconciler reads only. | NO CHANGE. |
| **SessionTemplate Kind** (`Ezagent.Entity.SessionTemplate`) | ALREADY IDEMPOTENT (write-once + hash-checked, rev-5 CRITICAL). The reconciler READS the SessionTemplate; doesn't write to it. | NO CHANGE. |
| **PtyServer sidecar** (cc plugin) | ALREADY IDEMPOTENT (round-8 returns `fresh?: false` for already-started; no new sidecar OS process). | NO CHANGE. |
| **`WorkspaceRegistry`** | ALREADY IDEMPOTENT (`bind/2` is an ETS upsert; identical (uri, workspace) pair is no-op). | NO CHANGE. |
| **`AgentLineage`** | ALREADY IDEMPOTENT (`record/2` is an ETS upsert). The reconciler LOOKUPS, doesn't re-record. Existing record for our orchestrator + our workspace = ownership confirmed. | NO CHANGE. |
| **`Identity` (grant_cap)** | ALREADY IDEMPOTENT (User caps are a `MapSet`; identical cap = set insert no-op). | NO CHANGE. |
| **`RuleStore`** | PARTIALLY IDEMPOTENT (`add/5` always inserts a NEW row, even if a rule with identical matcher+receivers+scope exists). | PR-A small fix: reconciler uses `RuleStore.list(table)` + filter by scope to detect existing rules; only un-matched rules are added. `RuleStore.add/5` is NOT changed (no "skip if exists" inside it — keeps it simple); the reconciler does the detection. |
| **`McpRegistry`** | ALREADY IDEMPOTENT (ETS put). | NO CHANGE. |
| **`Session.template_working_copy` slice** (`Chat.set_working_copy/2`) | ALREADY IDEMPOTENT at the slice level (`:on_change` snapshot policy — identical content = no row write). | NO CHANGE. |

**Net work for idempotency:** PR-A introduces `derive_session_uri/3` and adds
a `RuleStore.list(table) |> filter |> Enum.find/2` check in the reconciler's
step 4. No Kind-level changes; no Behavior-level changes; no new actions.

---

## §6 Migration plan (PR sequence)

The migration is sequenced so the system is never in a state where the saga
is removed but the reconciler is not yet trusted. **The cutover (PR-B) is
behind a flag IN THE PR for the test suite only, never in production code
paths** — production sees the new behaviour immediately on merge of PR-B.
The flag exists ONLY to let the existing test suite run against the OLD
behaviour during the PR review (the PR converts every Generator test to
reconciler semantics, but the flag lets a reviewer A/B old vs new locally
without separate branches).

### PR-A — `derive_session_uri/3` + `RuleStore.list/1` idempotency probe (NON-BREAKING)

- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`: add
  `derive_session_uri/3` as a NEW private fn (not yet wired into
  `spawn_from_template/2`).
- `apps/ezagent_core/lib/ezagent/routing/rule_store.ex`: confirm `list/1`
  returns workspace-scoped rules (already does); no change.
- Tests: new `session_uri_derivation_test.exs` for determinism + workspace
  scoping; new `rule_store_existing_rule_match_test.exs` for the filter
  helper.
- No behaviour change. Reviewable in isolation.

### PR-B — `spawn_from_template/2` becomes the reconciler (BREAKING — INTERNAL)

- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`: replace
  `do_spawn/4` + `guard/2` + `cleanup_partial/1` + `terminate_kind/1` +
  `safe/1` with `reconcile_loop/3` + the 7 step fns from §2.
- `spawn_from_template/2` retains its signature; return shape gains the
  `{:partial, _}` variant (the old `{:ok, %{session_uri, orchestrator_uri}}`
  is preserved + augmented with `slots`).
- Tests: `apps/ezagent_domain_chat/test/integration/session_spawn_from_template_test.exs`
  rewrites every assertion to reconciler semantics. New tests:
  - `idempotent_re_run_test.exs` — invoke twice, assert second call's
    URIs match first, no duplicate state, no errors;
  - `partial_resume_test.exs` — kill a slot worker mid-spawn, re-invoke,
    assert that slot is re-converged WITHOUT re-spawning the others;
  - `failed_slot_retry_test.exs` — instantiate with a slot whose
    AgentTemplate is temporarily missing (plugin not loaded), assert
    `{:partial, _}` with that slot pending; spawn the plugin, re-invoke,
    assert `{:ok, _}`.
- CapBAC + workspace-isolation invariant tests UNCHANGED (the round-1..3
  preflights still run; the same failures still return `{:error, _}`).
- Migration: existing tests that asserted on `cleanup_partial`-style
  rollback are REWRITTEN to assert reconciler semantics (re-running
  converges from the partial state). The "atomic-or-rollback" assumption
  goes away from the test suite at the same time as the code.

### PR-C — `update_agent_template` becomes per-slot reconciler

- `apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex`: rewrite
  `do_update_agent_template/8` per §4. Delete `abort_swap_after_repoint_rollback`,
  `halt_routing_revert_failed`, `manual_repair_error`, `rollback_slot_to_old`,
  `compensate_orphan_worker`.
- The `{:error, {:update_needs_manual_repair, _}}` return shape is REMOVED;
  replaced by `{:partial, %{slot, completed, pending, errors}}`.
- Tests: `apps/ezagent_domain_chat/test/orchestrator/update_agent_template_test.exs`
  rewrites every "saga rollback" assertion to reconciler semantics.

### PR-D — Docs update (NO code)

- `docs/superpowers/specs/2026-05-22-phase-7-completion.md`: prepend a
  superseded notice pointing at THIS SPEC for the §"Spawn phase (MEDIUM-5)"
  + `cleanup_partial` content. The §"Architectural decisions" 1.0-1.7
  (template Behavior, real `:template` slice, Generator owner preflight,
  workspace isolation) ALL stand; only the failure-handling abstraction
  changed.
- `docs/notes/phase-7-implementation-audit-2026-05-22.md`: append a
  short "Resolution (2026-05-23)" section pointing at this SPEC and at
  the PR sequence above.
- `docs/notes/generator-reconciler-retrospective.md` (NEW): the "what we
  learned: 10 rounds of cleanup hardening proved the abstraction was
  wrong" forensic note. Bilingual (en + zh_cn) per convention.
- `.claude/skills/ezagent-developer/SKILL.md`: update P26 (SessionTemplate
  fork = config only) cross-ref to note the reconciler model for
  instantiation. Add a How-to recipe pointer ("How-to: write a reconcile
  step — idempotent forward progress").

### Sequencing safety

PR-A → PR-B is the cutover. There is no "window where the cleanup is
deleted but the reconciler isn't yet trusted" because PR-B is one
commit: the saga and the reconciler don't coexist. Reviewer's mental
model is "either the old function or the new function is in main —
never both partly-replaced." PR-C is independent of PR-B in code (the
two functions touch different modules) but should LAND AFTER PR-B
because both share the `{:partial, _}` convention; landing PR-C first
would orphan the convention. PR-D is documentation-only and can land
any time after PR-B.

---

## §7 Open questions

### §7-1 — Stable session URI: per `(template, owner)` or per `(template, owner, slug)`?

The reconciler requires the Session URI to be derivable from stable inputs.
Two options:

- **Option A — derive from `(template, owner)` only.** Pro: simplest
  contract; re-invocation is the operator's intent and finds the same
  session. Con: one owner cannot have two concurrent sessions from the
  same SessionTemplate. For V1 SessionTemplates this is FINE (the typical
  SessionTemplate is "the team I work with" — one per owner).
- **Option B — derive from `(template, owner, slug)`** with `slug` defaulting
  to `"default"`. Pro: future-proofs the "multiple concurrent sessions of the
  same template" use case (e.g. "customer support shift 1" + "shift 2"). Con:
  adds a parameter to `spawn_from_template/2`'s signature.

**Recommendation: Option A for V1**; revisit if + when a real two-concurrent-
session use case appears. The slug can be added as a non-breaking
optional 3rd argument later. The "owner with two sessions from the same
template wants to re-run the reconciler against the SECOND one" case is
solvable today by giving the second a forked SessionTemplate (cheap;
SessionTemplates are content-addressed + immutable per Phase-7 rev-5).

**Allen needs to confirm: A or B for V1?**

### §7-2 — `{:partial, _}` return shape, or always `{:ok, _}` with the converged-so-far state?

Two presentations:

- **Three-arm `:ok / :partial / :error`** (this SPEC). Pro: the caller can
  distinguish "everything is healthy" from "still converging" at a glance;
  the LiveView retry-button condition is one match. Con: callers MUST
  pattern-match on `:partial` or silently misinterpret a partial as success.
- **Two-arm `:ok / :error`** where `:ok` carries a `complete?: bool`
  field. Pro: smaller API surface. Con: callers forget to check
  `complete?` and silently treat partial as success (a worse failure
  mode than the saga's "drop everything on any error").

**Recommendation: three-arm `:ok / :partial / :error`** as specified. The
LiveView caller is now part of the test gate (PR-B's
`partial_resume_test.exs` asserts the LV shows the retry button).

### §7-3 — Backward-compat: does any external caller depend on the strict-atomic-or-error contract today?

Audit in PR-A (the non-breaking PR):

- LV callers: surveyed above (§1.1) — none depend on rollback semantics.
- CLI / Mix tasks: grep `Session.spawn_from_template` across `apps/` — V1
  expectation NONE outside `session_live.ex` + tests. PR-A's commit
  message records the audit result.
- External plugins (out-of-tree): no contract publishers in V1; this is
  an internal-only function (no `@external_resource` users).

If the audit surprises with an external caller, PR-A inserts a
deprecation log line in `spawn_from_template/2` warning that the return
shape gains a `:partial` variant in PR-B, with one phx release between
PR-A and PR-B for the warning to land. **For now we assume no surprises;
flag if the PR-A audit finds any.**

---

## §8 Verification — what V1 must pass

The Phase-7 round-1..10 invariants ALL stand (CapBAC, workspace isolation,
slot-name uniqueness, candidate URI freshness, routing-batch atomicity,
`fresh?`-gated obligations, ownership-verified `fresh?: false` adoption).
The reconciler ADDS:

### V1-R1 — Full convergence (regression)

A first invocation of `spawn_from_template(template_uri, owner_uri)` against
a fresh workspace produces the same outcome as today: the expected Session +
orchestrator + all slot workers + routing rules + caps. `{:ok, %{session_uri,
orchestrator_uri, slots: [...]}}`. **Identical to today's behaviour for the
happy path.**

Test: `apps/ezagent_domain_chat/test/integration/spawn_from_template_full_convergence_test.exs`
(repurpose existing test; assert the new `slots:` field too).

### V1-R2 — Idempotent re-run

Two invocations of `spawn_from_template(template_uri, owner_uri)` in
succession produce IDENTICAL outcomes (same session URI, same orchestrator
URI, same slot worker URIs). `KindRegistry`, `AgentLineage`, `WorkspaceRegistry`,
`routing_rules` table contain exactly the rows from invocation 1 — no
duplicates, no extras.

Test: `idempotent_re_run_test.exs` — invoke twice, snapshot every store
between calls, assert byte equivalence.

### V1-R3 — Partial resume

Invocation 1: kill the worker pid for ONE slot mid-spawn (via
`DynamicSupervisor.terminate_child` immediately after `template.instantiate`
returns `fresh?: true`). The other slots converge normally.
Invocation 1 returns `{:partial, %{pending: [{:slot, "X", :worker_dead}]}}`.

Invocation 2: same args. The dead slot is detected (
`KindRegistry.lookup(expected_worker_uri) :error`), respawned. Other
slots are detected as already converged (lineage + binding match
expected) and SKIPPED. Returns `{:ok, _}` with `slots:` complete.

Test: `partial_resume_test.exs`.

### V1-R4 — Failed-slot retry

Invocation 1: one slot's AgentTemplate plugin is not yet booted
(`Application.stop(:ezagent_plugin_curl_agent)` before the test;
SessionTemplate cites a curl slot). Returns `{:partial, %{pending:
[{:slot, "curl-bot", :agent_template_unresolvable}]}}`.

`Application.ensure_all_started(:ezagent_plugin_curl_agent)`.

Invocation 2: returns `{:ok, _}` with all slots present.

Test: `failed_slot_retry_test.exs`.

### V1-R5 — CapBAC + workspace-isolation invariants preserved

The existing Phase-7 round-1..3 invariant tests:

- `workspace_isolation_test.exs` (`apps/ezagent_domain_chat/test/integration/`)
- `cross_workspace_isolation_test.exs`
- `template_caps_test.exs` (`apps/ezagent_core/test/ezagent/`)

— ALL pass without modification. The reconciler does not relax the
authority gates; it just retries on completable failures.

### V1-R6 — `update_agent_template` reconciler semantics

- A successful slot update produces the expected worker + repointed
  routing + old worker terminated (regression from today).
- A re-invocation of `update_agent_template` with the same args after
  a successful update is a no-op (`:already_converged`).
- A failure mid-repoint (force-roll-back the routing transaction) leaves
  the new worker alive + the slot tuple at the OLD URI + routing at
  the OLD URI. Re-invocation detects "new worker present, slot still
  on old, routing still on old" → repoints + commits. The OLD worker
  is then terminated.

Tests: `update_agent_template_reconciler_test.exs`.

### V1-R7 — The INVARIANT TEST: no `cleanup_partial` regrowth

Per Allen's `feedback_completion_requires_invariant_test` (P6): the gate
is a test that FAILS when the architectural goal is unmet. The reconciler's
goal is "no saga rollback code in the Generator." The invariant test:

```elixir
# apps/ezagent_domain_chat/test/invariants/generator_no_saga_rollback_test.exs
test "Generator + update_agent_template have no cleanup_partial-style saga rollback" do
  generator = File.read!("apps/ezagent_domain_chat/lib/ezagent/entity/session.ex")
  tools     = File.read!("apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex")

  refute generator =~ ~r/cleanup_partial|abort_swap|guard\([^,]+,\s*spawned\)/
  refute tools     =~ ~r/abort_swap_after_repoint_rollback|halt_routing_revert_failed|manual_repair_error|rollback_slot_to_old/
end
```

This test FAILS the moment a future PR re-introduces saga rollback under
either function. It is the architectural-rule gate; without it, the next
"one more store" finding would silently re-add `cleanup_partial`.

### V1-R8 — Documentation completeness

`docs/superpowers/specs/2026-05-22-phase-7-completion.md` has the
superseded notice. `docs/notes/generator-reconciler-retrospective.md`
exists in both languages. SKILL.md's How-to recipes include "How-to:
write a reconcile step." (Manual gate; PR-D checklist item.)

---

## Appendix — file:line reference for the deletion set

Recorded against the worktree's current `session.ex` (lines 1-1493) and
`tools.ex` (lines 1-2019) at commit `e709273` (origin/main 2026-05-23):

**session.ex deletions** (≈ 80 lines net):

```
session.ex:317-442  do_spawn/4              (with-chain + guards)        — REWRITE to reconcile_loop/3
session.ex:456-467  guard/2                 (3 clauses)                  — DELETE
session.ex:497-542  cleanup_partial/1                                   — DELETE
session.ex:549-563  terminate_kind/1                                    — DELETE
session.ex:565-571  safe/1                                              — DELETE (only called by cleanup_partial)
session.ex:875-905  instantiate_agent_slots/4 (the 3-tuple {:error, reason, partial_slots} machinery)
                                                                       — RESTRUCTURE: lose the `partial_slots` accumulator-merge return form; the reconciler accumulates per-slot outcomes itself
```

**tools.ex deletions** (≈ 600 lines net — the bulk of `update_agent_template`'s
recovery machinery dissolves):

```
tools.ex:1123-1188  abort_swap_after_repoint_rollback/_                  — DELETE
tools.ex:1189-1221  halt_routing_revert_failed/_                         — DELETE
tools.ex:1222-1261  manual_repair_error/_                                — DELETE
tools.ex:1262-1309  rollback_slot_to_old/_                               — DELETE
tools.ex:301-318    compensate_orphan_worker/4                           — DELETE
tools.ex:532-727    do_update_agent_template/8 body                      — REWRITE per §4 (shrinks from ~195 lines to ~70)
tools.ex:728-765    commit_slot_step2/7 (the GenServer.call-exits guard) — KEEP body (still need it); the surrounding error-handling around it gets simpler
tools.ex:1027-1088  revert_receivers_by_ids_txn/_                        — DELETE (the inverse-repoint transaction; no recovery means no inverse)
```

**Net code reduction**: ~80 lines from `session.ex`, ~600 lines from
`tools.ex`. The 10 rounds of hardening LOC mostly dissolves into "the
reconciler doesn't need it."
