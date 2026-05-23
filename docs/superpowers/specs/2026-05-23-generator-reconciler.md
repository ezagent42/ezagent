# Generator → Reconciler (SessionTemplate `converge-to-spec`)

> **Status**: DRAFT rev 2 — 2026-05-23. Author: Claude, per Allen Feishu
>
> - **rev 1**: initial SPEC.
> - **rev 3**: second `codex adversarial-review` — 2 HIGH + 1 MEDIUM, all
>   addressed: (a) PR-B plan contradicted the rev-2 SPEC by listing
>   `populate_working_copy/5` + `grant_scoped_caps/3` + preflight_agent_slots
>   as `KEPT body, no change` — fixed by rewriting PR-B scope to explicitly
>   reflect the rev-2 rewrites (plan file §"PR-B"); (b) working-copy merge's
>   `prior_slot_still_owned?` predicate only checked KindRegistry +
>   WorkspaceRegistry — extended to require AgentLineage match too (§2
>   step 5); (c) orchestrator adoption gate misclassifies a legitimate
>   concurrent-spawn-race (Agent.spawn spawns → binds → records lineage
>   non-atomically; a second pass reading the process post-spawn but
>   pre-bind reports foreign) — added bounded re-read with retry-delay
>   (§2 step 2).
> - **rev 2**: first `codex adversarial-review` — 6 HIGH, all addressed
>   inline. (a) cap idempotency requires logical equality ignoring
>   `granted_at` — see §2 step 6 + §5 row "Identity grant_cap"; (b) per-slot
>   AgentTemplate resolvability moves out of Step 0 into per-slot
>   reconcile so V1-R4 (failed-slot retry) actually works — see §2 step 0
>   + §2 step 3; (c) `populate_working_copy` becomes a MERGE not a replace
>   so pending slots' prior tuples survive — see §2 step 5; (d)
>   `update_agent_template` no-op detection runs BEFORE generation bump —
>   see §4.1; (e) routing-rule idempotency probe requires `enabled == true`
>   AND normalized matcher — see §2 step 4 + §5 row "RuleStore"; (f)
>   orchestrator adoption uses the same ownership-gated pattern as worker
>   slots (no `Agent.spawn` on a live foreign-lineage URI) — see §2 step 2.
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

### Step 0 — Preflight (NARROWED from Phase-7 round-1..3 — codex rev-2 HIGH-2)

The structural / authority gates run BEFORE any side effects. A failure
here returns `{:error, reason}` — these are the un-completable failures
that prevent *any* convergence (no Session is created):

- `ensure_template_alive(session_template_uri)` — idempotent demand-spawn
  of the SessionTemplate Kind itself; `{:already_started, _}` accepted;
- `owner_instantiate_preflight(session_template_uri, owner_uri)` — owner
  must hold `template:instantiate` authority on the SessionTemplate's
  workspace;
- `read_template_content(session_template_uri)` — `template.read` dispatch;
- `resolve_target_workspace(template_content)` — honour
  `default_workspace_uri` (Phase-7 round-1 HIGH-4);
- `preflight_workspace_isolation/3` — the same-workspace rule (Phase-7
  round-2 CRITICAL: SessionTemplate workspace ≡ `default_workspace_uri` ≡
  every slot's AgentTemplate URI's workspace SEGMENT — *structural URI*
  check, no Kind aliveness probe; the slot URI just has to PARSE into the
  right workspace);
- `preflight_slot_name_uniqueness/1` — slot name collisions rejected (round
  3) — pure name analysis, no Kind probe;
- `preflight_routing_rules/1` — every matcher round-trips through
  `Matcher.to_json/1` — pure shape validation, no DB / Kind probe.

**MOVED OUT of Step 0** (codex rev-2 HIGH-2) — the following Phase-7
preflight is RETIRED at the Generator-entry level and migrated INTO step
3 (per-slot reconcile):

- ~~`preflight_agent_slots/1` — every slot's AgentTemplate Kind resolvable~~
  → MOVED INTO `reconcile_slot/5`. An unresolvable AgentTemplate (Kind
  spawn fails because the plugin is not yet loaded) is a per-slot
  partial outcome, NOT an up-front Generator denial. This is what makes
  V1-R4 (failed-slot retry) possible: previously the WHOLE Generator
  failed before any Session was created, so re-invocation had no partial
  state to continue from; now the Session and other slots converge
  while the unresolvable slot accumulates into `pending`.

These Step-0 preflights are PURE (structural / authority checks against
the in-hand template content, no spawning, no plugin-aliveness probes).
A re-run repeats them cheaply.

**`preflight_candidate_uris_free/3`** (Phase-7 round-3 MEDIUM-3 — rejecting
orphan-live candidate worker URIs from a prior failed cleanup) is also
RETIRED. Its job was to defend against the saga's incomplete cleanup
leaving orphan workers at predictable candidate URIs; the reconciler
WELCOMES those orphan workers IF they pass the ownership gate (`AgentLineage`
points at this orchestrator AND `WorkspaceRegistry` points at this
workspace) — they are "already-converged" slots from a prior partial run.
The check moves into per-slot reconcile (§2 step 3) as the
`verify_slot_candidate_ownership/5` round-8 gate, which is already there.

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

### Step 2 — Ensure Orchestrator (ownership-gated adoption — codex rev-2 HIGH-6)

The orchestrator URI is derived deterministically from the session URI
(today's `cc_orchestrator-#{session_name}` pattern), so re-invocation
computes the same candidate. The adoption-vs-creation decision uses the
SAME ownership gate as worker slots (§2 step 3 + `Workspace.Loader`'s
precedent — `gated_load_bind/3`):

```
def ensure_orchestrator(session_uri, workspace_uri, owner_uri):
  candidate_uri = derive_orchestrator_uri(session_uri)

  case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
    {:owned, ^candidate_uri} ->
      {:ok, candidate_uri, :already_present}

    :not_live ->
      Agent.spawn(orch_template_uri, instance_name, workspace_uri, owner_uri)

    {:live_but_ownership_unknown, _} ->
      # codex rev-3 MEDIUM: Agent.spawn/4 is process-spawn THEN bind-workspace
      # THEN record-lineage (3 non-atomic steps in agent.ex:140-143). A second
      # reconciler pass that interleaves between step 1 and step 3 of the FIRST
      # pass legitimately sees a live process with no published lineage/binding
      # yet. That race is NOT corruption. Treat live-but-ownership-unknown as a
      # transient state: bounded re-read with backoff, before classifying as
      # foreign. The retry budget is small (race window is microseconds in
      # practice); a TRUE foreign state stays foreign across the retries.
      with_retries(retries: 3, backoff_ms: 50, fn ->
        case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
          {:owned, _}                     -> {:ok, candidate_uri, :already_present}
          {:live_but_ownership_unknown, _} -> :retry
          :not_live                       -> :retry  # spawn race resolved + lost
        end
      end)
      |> case do
        {:ok, _, _} = ok -> ok
        :retry_exhausted -> {:error, {:orchestrator_foreign, candidate_uri}}
      end
  end

defp check_orchestrator(uri, owner_uri, workspace_uri):
  case KindRegistry.lookup(uri) do
    :error -> :not_live
    {:ok, _pid} ->
      lineage_ok  = match?({:ok, ^owner_uri},     AgentLineage.lookup(uri))
      workspace_ok = match?({:ok, ^workspace_uri}, WorkspaceRegistry.lookup(uri))
      cond do
        lineage_ok and workspace_ok -> {:owned, uri}
        true                         -> {:live_but_ownership_unknown, uri}
      end
  end
```

**Why this matters**: pre-rev-2 the fallback was a direct `Agent.spawn`
call, and `spawn_or_resume/1` (agent.ex:149) maps `{:error, {:already_started,
pid}}` to `{:ok, pid}` — then unconditionally calls `WorkspaceRegistry.bind`
+ `AgentLineage.record` (agent.ex:140-143). So a live foreign-lineage
orchestrator at the same URI would have been silently RE-PARENTED + REBOUND.
Rev-2's `cond` gate refuses adoption WITHOUT the lineage/workspace match —
mirroring the worker-slot `verify_slot_candidate_ownership/5` round-8
contract — surfacing the foreign URI as `{:partial, _}` with
`{:orchestrator_foreign, _}` for operator inspection.

**Race-handling decomposition** (codex rev-3 MEDIUM): the pre-rev-3 SPEC
classified ANY `live? + no ownership match` as `:orchestrator_foreign`.
That misclassifies the legitimate concurrent-reconciler race, since
`Agent.spawn/4` (agent.ex:140-143) is THREE non-atomic steps:

```
1. spawn_or_resume(agent_uri)  # process is now live
2. WorkspaceRegistry.bind(...)   # binding published
3. AgentLineage.record(...)      # lineage published
```

A second reconciler pass that runs between caller-1's step 1 and step 3
sees the process live but no published ownership. With the bounded re-read
(3 retries, 50ms backoff = 150ms total worst case — far longer than any
realistic Generator step), the second pass either sees ownership get
published (and converges) or confirms the foreign state persists (and
errors). TRUE foreign-corruption stays foreign across retries.

The fresh-spawn branch's `Agent.spawn/4` still benefits from
`spawn_or_resume/1`'s `{:already_started, _}` idempotency for the
honest concurrent-second-caller race — the second caller's spawn loses,
sees `{:already_started, pid}` → `{:ok, pid}`, then RE-RECORDS lineage +
RE-BINDS workspace. Since these registries are upserts with the same
values (caller 1 and caller 2 are the same reconciler with the same
inputs), the re-record is harmless. The dangerous case (live-and-FOREIGN
on first inspection) is the only one this branch needs to refuse — and
the bounded re-read ensures the diagnosis is correct, not racy.

### Step 3 — Reconcile each agent slot (with per-slot template resolvability — codex rev-2 HIGH-2)

For each slot in `template_content.agent_slots`, INDEPENDENTLY:

```
def reconcile_slot(slot_name, agent_template_uri, session_uri, workspace_uri, orchestrator_uri):
  expected_worker_uri = derive_worker_uri(slot_name, session_uri, workspace_uri, agent_template_uri)

  # Already-converged FAST PATH — no AgentTemplate spawn needed:
  if worker_already_owned_by_us?(expected_worker_uri, orchestrator_uri, workspace_uri),
    do: return {:already_converged, expected_worker_uri}

  # Per-slot AgentTemplate aliveness (formerly in Step-0 preflight_agent_slots/1).
  # This is THE migration of HIGH-2: a per-slot failure here is a per-slot
  # partial outcome, NOT a Generator-wide abort.
  with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
       target      <- URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate"),
       {:ok, %{workers: workers, fresh?: fresh?}} <-
         Invocation.dispatch(%Invocation{target: target, mode: :call,
           args: %{instance_name: derive_instance_name(slot_name, session_uri),
                   workspace_uri: workspace_uri,
                   spawned_by: orchestrator_uri},
           ctx: %{caller: orchestrator_uri, caps: admin_caps(), reply: {:caller_inbox, self()}}}),
       {:ok, worker_uri} <- first_worker(workers),
       :ok <- verify_slot_candidate_ownership(fresh?, slot_name, worker_uri,
                                              workspace_uri, orchestrator_uri) do
    {:ok, worker_uri}
  else
    {:error, reason} ->
      # Per-slot partial — accumulates into pending. The OTHER slots and
      # routing/caps/working-copy steps continue.
      {:error, {:slot, slot_name, reason}}
  end

defp worker_already_owned_by_us?(uri, orch_uri, ws_uri):
  case KindRegistry.lookup(uri) do
    {:ok, _pid} ->
      # Mirror the round-8 ownership predicate (canonical-string compare).
      lineage_ok = match?({:ok, ^orch_uri}, AgentLineage.lookup(uri))
      ws_ok      = match?({:ok, ^ws_uri},   WorkspaceRegistry.lookup(uri))
      lineage_ok and ws_ok
    :error -> false
  end
```

**The fast path** (`worker_already_owned_by_us?`) is the load-bearing
idempotency check. It is the structural equivalent of `Workspace.Loader.bind_one_gated/3`'s
`worker_already_bound_to?/2` (`loader.ex:247-252`) plus the round-8
`AgentLineage` parity check.

**Slot outcomes** (the per-slot, per-pass result the loop accumulates):

```
slots: [
  {"customer-bot",   {:already_converged, worker_uri_a}},   # skipped — fast-path hit
  {"escalation-bot", {:ok,                worker_uri_b}},   # freshly spawned this pass
  {"compliance-bot", {:error, {:slot, "compliance-bot",
                              {:agent_slot_template_unresolvable, "compliance-bot", _}}}}
]
```

`pending` carries `compliance-bot`; the next re-invocation tries again
(after the AgentTemplate's plugin loads). The first two slots are correctly
SKIPPED on the next pass via the fast path.

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

### Step 4 — Reconcile routing rules (codex rev-2 HIGH-5)

For each `(matcher_ast, [slot_name])` in `template_content.routing_rules`:

```
def reconcile_routing_rule(matcher_ast, slot_names, slot_uri_by_name, workspace_uri, owner_uri):
  receiver_uris =
    slot_names
    |> Enum.map(&Map.get(slot_uri_by_name, to_string(&1)))
    |> Enum.reject(&is_nil/1)

  cond do
    # Pending slot → some receiver_slot_name has no resolved URI yet:
    # DEFER (don't install a half-receiver rule). Goes to pending.
    length(receiver_uris) != length(slot_names) ->
      {:pending, :receivers_unresolved}

    receiver_uris == [] ->
      :skip  # rule with no resolvable receivers — same drop semantics as today

    true ->
      existing = find_live_existing_rule(matcher_ast, receiver_uris, workspace_uri)
      if existing, do: :already_converged, else: {:add, matcher_ast, receiver_uris}
  end

defp find_live_existing_rule(matcher_ast, receiver_uris, workspace_uri):
  # Normalize both sides through Matcher.to_json/1 so a JSON-round-tripped
  # matcher (`%{}` map) compares equal to a freshly-built one (tuple AST).
  want_matcher = Matcher.to_json(matcher_ast)
  want_recv_set = MapSet.new(receiver_uris, &URI.to_string/1)

  RuleStore.list(table)
  |> Enum.find(fn r ->
    r.enabled == true                                    and  # rev-2 HIGH-5: must be live
    r.workspace_uri == URI.to_string(workspace_uri)      and  # scope match
    r.source         == RuleStore.system_default_source  and  # generator-installed (cf. RuleStore.source/0)
    Matcher.to_json(r.matcher) == want_matcher           and  # normalized matcher equality
    MapSet.new(r.receivers, &URI.to_string/1) == want_recv_set
  end)
```

**Why the rev-2 hardening matters** (codex rev-2 HIGH-5): the rev-1 probe
filtered by `scope_matches?` + matcher/receivers but did NOT require
`enabled == true`. `RuleStore.list/1` returns ALL rows for the table;
`RuleStore.load_into_registry/1` only loads rows where `enabled == true`.
A disabled row with matching matcher/receivers/scope would have been
incorrectly classified as "already converged" — the reconciler would skip
re-adding it, and the ETS RoutingRegistry would have NO live rule for
that target. The fix: the equality predicate is the FULL live-rule contract:

- `enabled == true` (rev-2 fix);
- normalized matcher (round-trip through `Matcher.to_json/1` for shape
  equivalence — `%{}` vs tuple AST);
- workspace scope match;
- receiver SET equality (canonical-string compare, order-insensitive);
- `source` match (the Generator's installed rules are `source == :system_default`
  per `RuleStore.system_default_source/0`; a `:admin`-source rule by an
  operator is OFF-LIMITS for the Generator to "match against" — the
  operator owns it).

A disabled `:system_default` rule matching everything except `enabled`
is DRIFT (an operator disabled a Generator rule). V1 contract: the
reconciler treats this as `{:partial, :rule_disabled_by_operator}` —
DOES NOT auto-re-enable (the operator's intent overrides the
SessionTemplate spec). Operator decides: re-enable via admin UI, or
remove the rule from the SessionTemplate. (Open question §7-4: should
the reconciler emit a telemetry event on drift detection? V1 = yes,
log + telemetry, no auto-action.)

After collecting every `{:add, ...}` for this pass, ALL adds run inside ONE
`Repo.transaction` (the Phase-7 round-4 invariant is preserved at the
*batch-of-this-pass* level — a mid-batch failure rolls back ALL of THIS
pass's adds; rules added by PRIOR converged passes are NOT touched).
`load_into_registry/1` runs once after commit.

Deferred rules (`{:pending, :receivers_unresolved}` because some slot
is still `pending`) accumulate into the pass's `pending` list and are
retried next pass — the slot likely converges next time, then so does
its dependent rule.

### Step 5 — Populate `template_working_copy` (MERGE, not replace — codex rev-2 HIGH-3)

`chat.set_working_copy` is a slice REPLACE today; the rev-1 SPEC text
said "convergence MUST be monotonic from the working-copy's perspective"
but `populate_working_copy/5`'s body only knows the slots that CONVERGED
on this pass — replacing with that list would DROP a previously-converged
slot whose status is now `pending` (e.g. the worker died between passes).

The reconciler MERGES, preserving each pending slot's PRIOR tuple if and
only if that prior tuple's worker is still owned by us (lineage + binding
match):

```
def merge_working_copy(session_uri, template_content, this_pass_slots, workspace_uri, orchestrator_uri):
  # this_pass_slots :: [{slot_name, agent_template_uri, worker_uri, generation}]
  #   for slots that converged THIS pass — every entry's worker is alive + owned.
  prior = read_working_copy(session_uri)  # via chat.read_working_copy dispatch
  prior_slots_map = Map.new(prior.agent_slots, fn {n, _t, _w, _g} = e -> {n, e} end)
  this_slots_map  = Map.new(this_pass_slots,    fn {n, _t, _w, _g} = e -> {n, e} end)

  desired_slot_names = template_content.agent_slots |> normalize_agent_slots() |> Enum.map(&elem(&1, 0))

  merged_slots =
    Enum.map(desired_slot_names, fn name ->
      cond do
        # This-pass entry wins (just freshly converged).
        Map.has_key?(this_slots_map, name) ->
          this_slots_map[name]

        # No this-pass entry; prior is present + still ownership-valid (alive +
        # lineage to us + workspace match) → keep. codex rev-3 HIGH-1: lineage
        # check is included now.
        prior_entry = prior_slots_map[name];
        prior_entry != nil and prior_slot_still_owned?(prior_entry, workspace_uri, orchestrator_uri) ->
          prior_entry

        # No reliable prior entry — slot is genuinely pending, write nil-worker tuple
        # (so the operator sees "this slot has no live worker"). This tuple still
        # carries the source AgentTemplate URI from the SessionTemplate, so the
        # next pass can re-attempt the spawn.
        true ->
          source_template_uri = lookup_source_template_uri(template_content, name)
          {name, source_template_uri, nil, 0}
      end
    end)

  set_working_copy(session_uri, %{
    agent_slots: merged_slots,
    routing_rules: normalize_routing_rules(template_content.routing_rules),
    orchestrator_template_uri: template_content.orchestrator_template_uri || default,
    default_workspace_uri: workspace_uri,
    description: template_content.description
  })

defp prior_slot_still_owned?(
       {_name, _src, %URI{} = worker_uri, _gen},
       %URI{} = ws_uri,
       %URI{} = orch_uri):
  # codex rev-3 HIGH-1: require AgentLineage match too — a live worker in
  # the same workspace but re-parented to ANOTHER orchestrator must NOT be
  # preserved; instead we write a nil-worker tuple and reconcile next pass.
  # Reuses the same predicate as worker-slot fast-path (§2 step 3) and
  # orchestrator-adopt gate (§2 step 2).
  worker_already_owned_by_us?(worker_uri, orch_uri, ws_uri)
defp prior_slot_still_owned?({_name, _src, nil, _gen}, _ws, _orch), do: false
```

**The merge is monotonic for converged slots and HONEST for pending slots.**
A slot that was converged on pass 1 and is `pending` on pass 2 (the worker
died, the AgentTemplate plugin was uninstalled, etc.) — we keep its prior
tuple ONLY IF its worker is still alive and bound; otherwise we write a
nil-worker tuple so the orchestrator's UI shows "this slot has no live
worker, the reconciler will retry."

**Slice-write idempotency**: when the merge produces the same map as
what's already in the slice (the common case — full convergence + a
re-run), the `Chat.set_working_copy` dispatch produces no slice change,
the `:on_change` policy skips the snapshot row write, and `:invocations`
records ONE successful invocation (acceptable telemetry churn — a re-run
is an explicit operator action).

### Step 6 — Grant scoped caps to orchestrator (logical-equality idempotent — codex rev-2 HIGH-1)

Caps #1 (`{:within_session, S}`), #2 (`{:spawned_by, orch}`), and the
delegable subset of caps #3/#4 (template caps gated by Phase-7 round-1
§1.4 owner-cap preflight) are granted via `identity.grant_cap` dispatch.

**The rev-1 claim was wrong**: `grant_cap` is NOT idempotent on the
`%Capability{}` struct as currently built, because today's
`grant_scoped_caps/3` (session.ex:1340-1407) STAMPS each cap with
`granted_at: DateTime.utc_now()` before dispatch. Two passes produce
two structs that differ ONLY in `granted_at` — `MapSet.put/2` treats
them as distinct, so the User's `caps` set grows by 4 entries per
reconciler pass. This violates V1-R2 (byte-equivalent state across
re-runs) and burdens the audit log with duplicate grant invocations.

**The fix — logical-equality check BEFORE dispatch**:

```
def grant_scoped_caps_idempotent(orchestrator_uri, session_uri, owner_uri):
  workspace_uri = WorkspaceRegistry.lookup!(session_uri)
  desired_caps  = build_desired_caps(orchestrator_uri, session_uri, owner_uri, workspace_uri)
  # desired_caps :: [%Capability{}]  — granted_at unset / placeholder

  current_caps = Identity.list_caps_for(orchestrator_uri)  # MapSet.t()

  to_grant = Enum.reject(desired_caps, fn want ->
    Enum.any?(current_caps, &cap_equal_ignoring_metadata?(&1, want))
  end)

  # Only dispatch grant_cap for caps the orchestrator does NOT already hold.
  Enum.each(to_grant, fn want ->
    cap = %{want | granted_at: DateTime.utc_now()}
    dispatch(orchestrator_uri ? action=identity.grant_cap, %{cap: cap}, system_ctx)
  end)

defp cap_equal_ignoring_metadata?(%Capability{} = a, %Capability{} = b):
  # The IDENTITY of a cap is the {kind, behavior, instance, workspace_uri} tuple
  # — the authority being granted. `granted_at` (timestamp) and `granted_by`
  # (provenance) are metadata; the same authority granted twice by the same
  # principal should be a no-op.
  a.kind          == b.kind          and
  a.behavior      == b.behavior      and
  a.instance      == b.instance      and
  a.workspace_uri == b.workspace_uri and
  a.granted_by    == b.granted_by
```

**Why `granted_by` is part of the identity but `granted_at` is not**:
`granted_by` records WHO authorized the cap (the owner in Generator caps);
two different owners granting the SAME cap shape are two real grants
auditably (CapBAC's provenance rule). `granted_at` is purely a timestamp
of WHEN the dispatch fired; the cap's effective authority is unchanged.

**Effect on the audit log**: a fully-converged reconciler re-run produces
ZERO `identity.grant_cap` dispatches (the equality check short-circuits all
four), ZERO new `:invocations` rows, ZERO new User-Kind snapshot row
(no slice change). This is what V1-R2 byte-equivalence requires.

**On a NEW cap appearing** (Phase 9 added cap #5 in a future template
revision): the existing 4 caps are skipped; only #5 is dispatched. Pass is
still partial-converging-monotonically.

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

### 4.1 The reconciler shape for per-slot update (no-op detect BEFORE generation bump — codex rev-2 HIGH-4)

```
def update_agent_template(slot_name, new_agent_template_uri, opts):
  session_uri    = opts[:session_uri]
  workspace_uri  = opts[:workspace_uri]
  caller_uri     = opts[:caller]
  current_slot   = find_slot_tuple(session_uri, slot_name)  # {name, src, worker, gen}

  # ============== NO-OP DETECT — BEFORE any generation bump (HIGH-4) =====
  # If the slot is ALREADY in the desired state — same template URI, alive
  # worker, ownership-verified, routing pointing at it — this is an
  # idempotent rerun. Return {:ok, current_slot.worker_uri}. NO generation
  # bump, NO new worker URI computed (which would falsely diverge from
  # current).
  if slot_already_at_target?(current_slot, new_agent_template_uri,
                             session_uri, workspace_uri, caller_uri),
    do: return {:ok, current_slot.worker_uri}

  # ============== CONVERGENCE WORK — only when drift exists ============
  # The slot template differs from the request, OR the worker is dead, OR
  # routing is off, OR ownership is foreign. Compute the new generation +
  # converge.
  desired_state = %{
    slot_name: slot_name,
    template_uri: new_agent_template_uri,
    generation: current_slot.generation + 1,
    worker_uri: derive_worker_uri(slot_name, session_uri, new_agent_template_uri,
                                  current_slot.generation + 1),
  }

  reconcile_slot_to(desired_state, current_slot, session_uri, workspace_uri, caller_uri)

defp slot_already_at_target?(
       {_name, current_src_uri, %URI{} = current_worker_uri, _gen},
       %URI{} = new_template_uri,
       session_uri, workspace_uri, orch_uri):
  # All FIVE facts must agree for "already at target":
  same_template?  = URI.to_string(current_src_uri) == URI.to_string(new_template_uri)
  alive?          = match?({:ok, _pid}, KindRegistry.lookup(current_worker_uri))
  lineage_ok?     = match?({:ok, ^orch_uri},      AgentLineage.lookup(current_worker_uri))
  workspace_ok?   = match?({:ok, ^workspace_uri}, WorkspaceRegistry.lookup(current_worker_uri))
  routing_pointed_at_current? = routing_targets_worker?(current_worker_uri, workspace_uri)

  same_template? and alive? and lineage_ok? and workspace_ok? and routing_pointed_at_current?

defp slot_already_at_target?({_n, _t, nil, _g}, _new, _s, _w, _o), do: false
```

**Why this matters** (codex rev-2 HIGH-4): the rev-1 algorithm always
computed `desired_state.generation = current_slot.generation + 1` and
THEN compared `current_slot.worker_uri` to `desired_state.worker_uri`.
With generation folded into the worker URI (`Agent.session_instance_name/3`
appends `--g<n>` for n ≥ 1), the equality check could NEVER hold for an
idempotent rerun — a slot at generation N would always compute the
desired worker URI at generation N+1, so equality fails. The rev-1
"already-converged" branch was unreachable; every rerun rolled the
generation counter and respawned the worker. This contradicted V1-R6
"re-invocation after a successful update is a no-op."

The rev-2 fix moves the no-op detection BEFORE the generation bump.
Detection compares the slot's CURRENT template URI to the REQUESTED
template URI; if they're the same AND the worker is healthy AND routing
points at it, we're done. The generation bump only happens when there's
actual drift to converge.

### 4.2 The convergence routine (when drift exists)

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
| **Orchestrator Agent Kind** (cc-flavor) | `Agent.spawn/4` is idempotent on the live process (via `spawn_or_resume/1`'s `{:already_started, _}` mapping) BUT will silently `WorkspaceRegistry.bind` + `AgentLineage.record` on adopt (agent.ex:140-143) — re-parenting a foreign URI (codex rev-2 HIGH-6). | Reconciler-side `cond` gate (§2 step 2) refuses adoption when `KindRegistry` finds the URI live but `AgentLineage`/`WorkspaceRegistry` don't match expected owner+workspace. `Agent.spawn` is only called when the URI is NOT live. Mirrors the worker-slot round-8 ownership predicate and the `Workspace.Loader.bind_one_gated/3` precedent. |
| **Worker Agent Kinds** (cc/echo/curl flavors) | ALREADY IDEMPOTENT via the round-6 `{:ok, workers, %{fresh?: false}}` adoption path + round-7 `fresh?`-gated obligations + round-8 ownership gate. The dispatch `template.instantiate` returns the `fresh?` signal; the reconciler uses it to decide adoption-vs-creation. | NO CHANGE in the spawn path. Reconciler-side: implement "expected URI present + ownership matches → :already_converged" detection. |
| **AgentTemplate Kind** (`Ezagent.Entity.AgentTemplate`) | ALREADY IDEMPOTENT (read-only from reconciler's perspective). `:template` slice `:write` is mutable + plain-replace (Phase-7 rev-5 — AgentTemplate is versionless). Reconciler reads only. | NO CHANGE. |
| **SessionTemplate Kind** (`Ezagent.Entity.SessionTemplate`) | ALREADY IDEMPOTENT (write-once + hash-checked, rev-5 CRITICAL). The reconciler READS the SessionTemplate; doesn't write to it. | NO CHANGE. |
| **PtyServer sidecar** (cc plugin) | ALREADY IDEMPOTENT (round-8 returns `fresh?: false` for already-started; no new sidecar OS process). | NO CHANGE. |
| **`WorkspaceRegistry`** | ALREADY IDEMPOTENT (`bind/2` is an ETS upsert; identical (uri, workspace) pair is no-op). | NO CHANGE. |
| **`AgentLineage`** | ALREADY IDEMPOTENT (`record/2` is an ETS upsert). The reconciler LOOKUPS, doesn't re-record. Existing record for our orchestrator + our workspace = ownership confirmed. | NO CHANGE. |
| **`Identity` (grant_cap)** | NOT idempotent on the struct as currently built (codex rev-2 HIGH-1). `granted_at: DateTime.utc_now()` is stamped per dispatch; `MapSet.put` treats two structs differing only in `granted_at` as distinct. | Reconciler-side `cap_equal_ignoring_metadata?/2` (§2 step 6) compares `{kind, behavior, instance, workspace_uri, granted_by}` to gate the dispatch. `Identity.grant_cap` itself unchanged — the *MapSet* still trusts struct equality, the *reconciler* doesn't dispatch a redundant grant. |
| **`RuleStore`** | PARTIALLY IDEMPOTENT (`add/5` always inserts a NEW row). Reconciler must detect "live equivalent rule already present" with the FULL contract: `enabled == true`, normalized matcher, scope, receiver-set, source (codex rev-2 HIGH-5). | PR-A helper `existing_routing_rule_for/4` does the full-contract check via `RuleStore.list/1` + filter; only un-matched rules are added. Disabled `:system_default` rows = OPERATOR DRIFT — reconciler logs + marks pending, does NOT auto-re-enable. |
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

### §7-4 — Routing rule drift detection: log-only, telemetry, auto-re-enable, or block?

Codex rev-2 HIGH-5 surfaced: a disabled `:system_default` rule with matching
matcher/receivers/scope is OPERATOR DRIFT (an operator disabled a
Generator-installed rule). Options:

- **A — Log + telemetry, classify as `:partial` with `:rule_disabled_by_operator`**
  (this SPEC). The reconciler does NOT auto-re-enable; operator's intent
  wins. The orchestrator's UI surfaces the drift so the operator can
  re-enable or amend the SessionTemplate to remove the rule. **Recommended for V1.**
- **B — Auto-re-enable** (the reconciler overrides operator intent). Risky
  — operator may have disabled the rule deliberately during a migration;
  auto-re-enable creates a fight loop.
- **C — Block: refuse the SessionTemplate convergence entirely** until
  operator resolves the drift. Heavy-handed; one disabled rule shouldn't
  fail-stop the whole template.

**Recommendation: Option A.** Allen confirms in PR-A review.

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

### V1-R2 — Idempotent re-run (with cap + routing + audit churn assertions — codex rev-2)

Two invocations of `spawn_from_template(template_uri, owner_uri)` in
succession produce IDENTICAL outcomes (same session URI, same orchestrator
URI, same slot worker URIs). All of:

- `KindRegistry` — same pids across both calls (`Process.info(_, :start_time)`).
- `AgentLineage` — same row count + same `(uri, spawned_by)` pairs.
- `WorkspaceRegistry` — same `(uri, workspace)` pairs.
- `routing_rules` — same row count (no `add/5` dispatched on call 2).
- `users.caps_json` (the orchestrator's User Kind) — same cap count;
  per-cap logical equality (`{kind, behavior, instance, workspace_uri,
  granted_by}` set equal); no extra grant invocation in `:invocations`
  table between call 1's end and call 2's end. **(codex rev-2 HIGH-1 gate.)**
- `kind_snapshots` — same row count for the Session + orchestrator + slots
  + SessionTemplate Kinds (no slice change → no snapshot write).
- `:invocations` table — call 2 emits ZERO `identity.grant_cap` dispatches,
  ZERO `RuleStore.add` calls, ZERO `template.instantiate` dispatches that
  result in fresh spawns. (Read-side `template.read` is fine; idempotent.)

Test: `idempotent_re_run_test.exs` — invoke twice, snapshot every store
between calls, assert each item above.

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
  a successful update is a no-op — `{:ok, current_worker_uri}` returned
  WITHOUT bumping generation, WITHOUT spawning a new worker. **(codex
  rev-2 HIGH-4 gate: assert `current_slot.generation` unchanged across
  the re-invocation; assert `current_worker_uri` pid stable.)**
- A failure mid-repoint (force-roll-back the routing transaction) leaves
  the new worker alive + the slot tuple at the OLD URI + routing at
  the OLD URI. Re-invocation detects "new worker present, slot still
  on old, routing still on old" → repoints + commits. The OLD worker
  is then terminated.
- A re-invocation of `update_agent_template` with a slot that's
  ALREADY at the requested template returns `{:ok, current_worker_uri}`
  with NO generation bump and NO `template.instantiate` dispatch.

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
