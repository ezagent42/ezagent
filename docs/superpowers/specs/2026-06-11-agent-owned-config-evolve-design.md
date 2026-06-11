# Agent-Owned Config-Evolve — Design Spec

> **STATUS: design, rev 3 (two-step model — Allen 2026-06-11; codex round-1+2 REVISE addressed), awaiting codex round-3 + Allen review.** Prerequisite refactor that must merge BEFORE the P5 collapse-to-one-Kind work. Decided in Feishu brainstorm: **full move** of config-application from the socialware Session to the Agent entity.
>
> **rev 3 (Allen two-step — supersedes the rev-2 mechanism):** split the behavior into two steps with two distinct callers, resolving codex round-2's two HIGH blockers:
> - **Step 1 `apply_config_delta`** — dispatched TO the agent, gated by the agent's manage-cap (the manager/creator caller holds it via #533). Writes the immutable object + pointer to **ConfigStore — the DURABLE source of truth** — synchronously, object→pointer ordered, `source_turn_id`-idempotent.
> - **Step 2 (projection)** — the AGENT projects that pointer into its own `Sandbox` slice (`cascade_resolution.user_layer_uri`) via a **post-commit `DeferredDispatch` self-dispatch** (the P2.5c pattern — no deadlock, logged on failure), under a self-scoped `Sandbox.write_path` cap.
>
> The Sandbox pointer is **demoted from source to a spawn-time cache** of the durable ConfigStore pointer, so the **spawn read path is untouched** (small blast radius — no relocation of the 6+ `cascade_resolution` consumers). Tradeoff (Allen-accepted): the cache is **eventually consistent**; a crash in the commit↔projection window is closed by a **boot reconciliation** in the agent's own `ConfigEvolve.activate` (re-derive the cache from the ConfigStore source — runs in identity, no `core→ConfigStore` dep). Correctness is preserved; only the cache refresh is async + self-healing.
>
> **rev 2 (codex round-1, retained):** Q5/Q6 — the replay guard + `source_turn_id` + the `ConfigProjection` boot-registration + the `BehaviorSet`/`SocialwareSession` metadata move with the code (§6). Self-evolution-as-caller is DROPPED (codex r2 FIX-2b: the settlement caller is the manager/session, never the agent; the agent's self-write is step 2's projection, not a caller identity).

**Goal:** Dissolve the #607 confused-deputy class *structurally* by moving the agent-config-application capability (today `Ezagent.Behavior.ConfigUpdate` on the socialware Session Kind) onto the **Agent entity**, so the agent mutates its own config under its own authority. The socialware Session keeps only the optimizer Turn + the approval gate, then dispatches a validated, settled delta to the target agent.

**One-line architecture:** "SW-UPD" is not a scenario — it decomposes into (a) a generic socialware `Turn` whose settled output happens to be a config delta, and (b) an **agent updating its own config**. This spec moves (b) home to the agent and deletes the `ConfigUpdate` session behavior.

---

## 1. Problem & context

### 1.1 The #607 confused-deputy class

The self-evolve flow (SW-UPD) applies a settled config delta to a **target agent's** #17 high (user) cascade layer. Today this runs as `Ezagent.Behavior.ConfigUpdate` — a behavior on the socialware **Session** Kind (`apps/ezagent_domain_socialware/lib/ezagent/behavior/config_update.ex`). Its `apply_delta`/`repoint` handlers reach **across the entity boundary** into the target agent's `Sandbox` slice via `Ezagent.Socialware.CascadeRepoint.repoint_user_layer/3`, which can only do so by running under the privileged `system://agent-internal` principal (`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:247`, the `cap(:agent, Sandbox, :read)` + shared `:write_path` entries, added for #607).

Because a Session reaching into an arbitrary agent's Sandbox is a privilege escalation gated only by an in-handler caller-validation predicate, the bug class recurred across **five codex rounds** (#607): a caller-controlled `subject_uri` / `layer` / `config_id` reaching a store write before validation. The current code defends with `validate_and_normalize/2` (a single upfront chokepoint) — but the *structural* problem remains: the wrong entity owns the mutation.

### 1.2 The conceptual reframe (why "SW-UPD" dissolves)

Decomposing SW-UPD leaves two pieces, neither SW-UPD-specific:

1. **A socialware `Turn`** whose settled output happens to be a config delta. This is the generic `Ezagent.Behavior.Turn` — the same turn machinery SW-USE uses, with a different output shape. Nothing UPD-specific.
2. **An agent applying that delta to its own config.** This is just *agent update* — an Agent-entity operation.

Every other "update" a socialware app could want lands in an existing bucket, so none needs a standalone SW-UPD:

| "Update" | Belongs to |
|---|---|
| Change the socialware app/template (behaviors, workers, page) | **SW-DEV** (authoring) |
| Change an agent's soul/config (self-evolve) | **agent-update** (this spec) |
| Re-materialize a running session (new behavior set / params) | generic **`Manage.reconfigure`** (#533) |
| Change membership / routing | **session management** / team-routing (manage-cap) |
| Change the customer-facing surface/page | **SW-USE** turn output |

So the socialware "scenarios" reduce to **SW-DEV (build the app) + SW-USE (run it)**, both just substrate compositions — and "update" is not a scenario.

### 1.3 The precedent that de-risks this: the ApiKeys-to-Agent flip

This exact move was already done once. `catalog.ex:262-271` records that `cap(:user, ApiKeys, :get_api_key)` used to live on `system://agent-internal`; Allen flipped `ApiKeys` onto the agent's own Kind (2026-05-26), after which the agent reads its **own** slice in-process (`ctx[:all_slices][:api_keys]`) — **no dispatch, no cap** — and the entry was dropped from the principal. Agent-owned config-evolve is the same play applied to the cascade-layer write.

---

## 2. The seam — what moves, what stays

`apply_delta` has five steps; **only step 4 crosses the entity boundary.** The seam is exactly there.

```
1  read settled turn + extract delta        ── stays SESSION-side (Turn reads its own :turns slice, dispatches step 1 to the agent)
2  validate_and_normalize (delta shape)      ── MOVES to the agent (it validates its own incoming delta)
3  ConfigStore.write_config (immutable obj)  ── MOVES to agent domain — STEP 1, synchronous (durable source)
4 ★ repoint the AGENT's Sandbox cascade layer ── MOVES to the agent — STEP 2, the agent's own async PROJECTION of the durable pointer (no relocation of the pointer itself; Sandbox stays a spawn cache)
5  ConfigStore.put_pointer (rollback ledger) ── MOVES to agent domain — STEP 1, synchronous (durable source)
```

**Full move** (Allen 2026-06-11): the entire config-version management — the immutable-object catalog, the cascade pointer, the repoint, the rollback bookkeeping, and the delta validation — is the **agent's** config-version history (objects are keyed by `subject_uri` = the target agent; the rollback pointer is per `(agent, layer, key)`). It all moves to the agent side. The socialware Session keeps **only** the `Turn` (produce the delta) + the approval gate, then **dispatches** the apply to the target agent.

### Modules that move (out of `ezagent_domain_socialware`)

| Module today | Role | New home |
|---|---|---|
| `Ezagent.Behavior.ConfigUpdate` | session behavior: apply_delta/repoint | **DELETED**; replaced by a new Agent behavior (§3) |
| `Ezagent.Socialware.ConfigStore` | immutable objects + pointer + rollback | `ezagent_domain_identity` (agent config-provisioning) |
| `Ezagent.Socialware.ConfigObject` (schema) | the immutable-object table | `ezagent_domain_identity` (table unchanged — §6) |
| `Ezagent.Socialware.CascadeRepoint` | the agent-sandbox read-modify-write | folded into the new Agent behavior, **in-process** |
| `Ezagent.Socialware.ConfigProjection` | `object_uri` + spawn-time `resolve_config_dir`/`render_soul` | `ezagent_domain_identity` (it is agent provisioning) |

### Stays in `ezagent_domain_socialware`

- `Ezagent.Behavior.Turn` — produces the settled delta; at settlement it now **dispatches the apply to the target agent** instead of self-dispatching `apply_delta` (`turn.ex:574`).
- The approval gate (the turn must be settled before the delta is applied) stays a Turn concern.

### Domain-dependency direction (the load-bearing constraint)

The Agent entity lives in `ezagent_domain_instance_message`. `ezagent_domain_socialware` **depends on** `instance_message` and `identity` — not the reverse. So config-management cannot stay in socialware and be "owned" by the agent. Moving it to **`ezagent_domain_identity`** (which already hosts the agent's credential/provisioning behaviors `CredentialGrant`, `ApiKeys`) is dependency-correct: `instance_message` (Agent Kind) already depends on `identity` to register those behaviors, so it can register the new config-evolve behavior too; `socialware` already depends on `identity`, so the Turn can still dispatch to the agent.

---

## 3. The new Agent behavior

A new behavior `Ezagent.Behavior.ConfigEvolve` (in `ezagent_domain_identity`), registered on the **Agent** Kind alongside `Sandbox`/`CredentialGrant`/`ApiKeys`. It owns a `:config_evolve` slice (holding the applied-turn idempotency markers; the durable config-version state lives in `ConfigStore`).

The work is **two steps with two distinct callers** (Allen's design — resolves codex round-2):

```elixir
# Agent.behaviors/0 gains Ezagent.Behavior.ConfigEvolve
# STEP 1 — caller = the manager (holds the agent's manage-cap)
action(:apply_config_delta, args: %{turn_id, delta...}, caps: [:apply_config_delta], modes: [:call])
action(:repoint_config,     args: %{layer, config_id...}, caps: [:repoint_config], modes: [:call])
# STEP 2 — caller = the agent itself (self-scoped Sandbox cap); a deferred projection, not user-facing
action(:project_cascade_to_sandbox, args: %{}, caps: [:project_cascade_to_sandbox], modes: [:cast])
```

### Step 1 — durable apply (the agent is the dispatch target; manager-authorized)
`apply_config_delta` (and `repoint_config` for rollback) run in the **agent's** process, gated by the agent's manage-cap (§4). Synchronously, **object-keyed**: merge delta → `ConfigStore.write_config` (immutable object) → `ConfigStore.put_pointer` (current/previous rollback ledger, `source_turn_id`-stamped) → record the applied marker in the agent's own `:config_evolve` slice. **`ConfigStore` is the durable source of truth.** Then the handler emits **one `dispatch_after_commit` Cmd** for step 2 (post-commit, so it runs only after step 1's durable state commits). This step is fully synchronous + observable to its caller; the #607 atomic-by-ordering guarantee lives entirely here (in the DB), unchanged.

### Step 2 — sandbox projection (the agent acts on itself; self-authorized, async)
`project_cascade_to_sandbox` is the agent's own deferred handler. It reads the current `ConfigStore` pointer + the current `cascade_resolution` (via `reads_siblings([:sandbox])`, the genuine ApiKeys in-process read precedent), and writes the refreshed `user_layer_uri` into the **`Sandbox`** slice by self-dispatching `sandbox.write_path` (the agent is both caller and target). This needs a **self-scoped** `cap(:agent, Sandbox, :write_path, instance: self)` granted to the agent at create. As a post-commit **cast** (`DeferredDispatch`, P2.5c), it never deadlocks and its failure is logged (`log_unobservable_cast_error`).

**Why this is sound where rev-2's single self-dispatch was not (codex round-2):** the Sandbox copy of the pointer is **demoted from source to a spawn-time cache**. The durable consume (object + pointer) is step 1, synchronous in `ConfigStore`; the Sandbox write is a downstream *projection* whose async timing cannot lose or mis-order durable state. The spawn read path is **untouched** (it still reads `cascade_resolution.user_layer_uri`), so there is **no relocation** of the 6+ `cascade_resolution` consumers.

### Crash-window self-heal (boot reconciliation)
If the agent crashes between step 1's commit and step 2 running, the Sandbox cache is stale. `ConfigEvolve.activate/2` (agent boot, in identity) **reconciles**: read the `ConfigStore` current pointer, compare to the Sandbox `user_layer_uri`, and if they diverge re-emit the step-2 projection. This closes the window with **no `core→ConfigStore` dependency** (it runs in the agent's own domain). Correctness is preserved; only the cache refresh is async + self-healing.

**The confused-deputy is dissolved structurally:** there is no longer any path where a caller-controlled `subject_uri` lets a *session* write an *arbitrary* agent's Sandbox under a god-cap. Step 1's authority is the specific target agent's manage-cap (instance-scoped); step 2's write is the agent acting on **itself**. The cross-entity `system://agent-internal` Sandbox-read escalation is removed.

---

## 4. Authority model — two callers (manager for step 1, self for step 2)

**Step 1** (`apply_config_delta`/`repoint_config`) requires the **agent's manage-cap**; **step 2** (`project_cascade_to_sandbox`) requires the agent's **self-scoped Sandbox cap**:

```
required_caps[:apply_config_delta] = required_caps[:repoint_config]
  = cap(:agent, Ezagent.Behavior.Manage, :any)              # resolved against the target agent instance at dispatch
required_caps[:project_cascade_to_sandbox]
  = cap(:agent, Ezagent.Behavior.Sandbox, :write_path)      # held by the agent over ITSELF (instance: self, granted at create)
```

This reuses the **already-built and merged** #533 machinery (verified on main 2026-06-11):

- `Ezagent.CreatorGrant.manage_cap/4` mints `cap(:<kind>, Ezagent.Behavior.Manage, :any, instance: uri)`.
- `Ezagent.Behavior.Manage` is registered on every Kind.
- The agent-create path (`agent_create.ex` `grant_agent_creator_manage_cap` → `Ezagent.Workspace.grant_creator_manage_cap(:agent, …)`) grants the **creator** the agent's manage-cap.

So **whoever manages the agent holds the cap and may evolve it** (the orchestrator/evolver/creator who created it; granting to N entities is supported). The old `ConfigUpdate` "membership OR spawn-lineage" predicate was a *pre-manage-cap approximation* of management authority; it is **retired**, not preserved as a fallback. Authority = manage-cap, period.

**Why the manage-cap (not a new `config_evolve` cap):** config-evolve is bundled under *management* authority by design (Allen-endorsed 2026-06-11: "谁持有 manage-cap 谁就可以更新 agent"). Evolving an agent's soul is a management act of the same weight as `Manage.delete`/`reconfigure`; gating it by the same cap means there is exactly one authority concept for "may control this agent," not a proliferation of per-action caps. (A future split is possible if a role should evolve but not delete — out of scope; YAGNI.)

**How legitimate evolvers acquire the cap (codex Q3 — load-bearing).** Codex confirmed today's SW-UPD callers pass with ordinary **session-scoped user caps**, NOT the Agent manage-cap (`config_update_test.exs:294-301,345-357`; the settling caller's caps are forwarded at `turn.ex:585-597`). So flipping the gate to the manage-cap **denies them unless the cap is wired**. This is a deliberate authority tightening — safe because SW-UPD is **not in production** — and the wiring is in-scope here, NOT a deferred diligence note:

- **Manager-driven evolution** (orchestrator / creator runs SW-UPD on an agent it manages): the caller already holds `cap(:agent, Manage, :any, instance: agent)` via the #533 create-grant. The plan asserts this with a test where the authorized manager passes and a non-manager is denied.
- **Step 2 is NOT a separate evolver** (codex r2 FIX-2b correction): the settlement caller is always the manager/session — never the agent — so there is no "agent self-evolves as caller." The agent's involvement is step 2's **projection**, authorized by its own self-scoped `Sandbox.write_path` cap (§3), not by being the step-1 caller. The earlier "self-evolution with a self manage-cap" framing is dropped.
- **Any other current caller** that passed only via the old membership predicate: the plan identifies it and grants the manage-cap at the point its management relationship is established — it is NOT given a membership fallback. If no such legitimate caller exists, the tightening simply removes an over-broad path.

The agent's **base self-caps at create** gain exactly one entry for this feature: the self-scoped `cap(:agent, Sandbox, :write_path, instance: self)` that step 2 needs (NOT a self manage-cap — the agent does not manage itself; only the step-2 projection is self-authorized).

**Recovery-path caller (verified at `turn.ex` `config_update_effects`/`dispatch_ctx`):** the `delta` carrying `subject_uri` (the target agent) IS available at the Turn settlement effect, so step 1 can target the agent. BUT the **settlement-recovery** path defaults `dispatch_ctx` to `caller: ctx.self_uri` (the session) with bootstrap/empty caps — which does NOT hold the target agent's manage-cap. The plan MUST make the recovery re-dispatch run under a principal that holds (or is granted) the target agent's manage-cap — e.g. a scoped system-principal entry for the settlement-recovery dispatch, mirroring how recovery already injects bootstrap caps. The NORMAL settlement path carries the settling caller's caps (the manager who drove the turn); the plan asserts that caller holds the manage-cap and adds the recovery-path principal so a crashed-then-recovered settlement is not denied.

The existing `config_update_test.exs` fixtures that grant only session caps are **updated** to grant the manage-cap to the authorized caller (reflecting the corrected model), plus a new denial test for an unauthorized caller.

**Validation (step 2) under the new model:** the agent re-validates the delta it receives (layer / key / patch shape) before any side effect — the same single-upfront-chokepoint discipline (#607 round-5), but now the agent validates *its own* incoming delta rather than a Session validating a cross-entity write. The confused-deputy authority guard (`subject_uri` belongs to a manageable agent) is **gone** because the agent *is* the subject — there is no deputy.

---

## 5. Data flow

### Before
```
Turn settles → Turn self-dispatches Cmd(:apply_delta, session)   (turn.ex:574)
  → ConfigUpdate (SESSION behavior) handles it
    → ConfigStore.write_config (object)
    → CascadeRepoint.repoint_user_layer  ── escalate to system://agent-internal → write TARGET agent Sandbox
    → ConfigStore.put_pointer
```

### After
```
Turn settles → Turn reads its settled delta, extracts subject_uri (target agent)
  → Turn dispatches Cmd(:apply_config_delta, TARGET AGENT, {delta})   ── caller must hold the agent's manage-cap
    → STEP 1  ConfigEvolve.apply_config_delta (AGENT); gate = target agent's manage-cap (§4):
        → ConfigStore.write_config (immutable object)        ┐ SYNCHRONOUS, object→pointer
        → ConfigStore.put_pointer  (current/previous, source_turn_id) ┘ ordered = DURABLE SOURCE
        → set applied marker in own :config_evolve slice
        → emit dispatch_after_commit Cmd(:project_cascade_to_sandbox → SELF)
    → STEP 2  ConfigEvolve.project_cascade_to_sandbox (AGENT→SELF, post-commit cast):
        → read ConfigStore current pointer + cascade_resolution (reads_siblings([:sandbox]))
        → self-dispatch sandbox.write_path → refresh cascade_resolution.user_layer_uri (self-scoped Sandbox cap)
  [boot] ConfigEvolve.activate: reconcile Sandbox cache ⟸ ConfigStore source (closes crash window)
```

The **object-keyed ordering** (object → pointer; #607 CRITICAL) lives entirely in **step 1, synchronously in `ConfigStore`** — the durable source of truth. Step 2's Sandbox write is a *projection* of that durable pointer; its async timing cannot lose or mis-order durable state. The P2.5c durable idempotency marker (`source_turn_id` on the `ConfigObject`, `applied_for_turn?`) and crash-replay semantics move unchanged **with the store** (§6 — the replay guard the Turn's recovery scan calls at `turn.ex:163-170` must remain reachable after the store relocates).

**Authority handoff** is specified concretely in §4 (manager holds the #533 create-grant; self-evolution uses a self-scoped manage-cap; the plan wires the grants + updates the tests). The cap is **instance-scoped to the specific target agent**, so there is no arbitrary-agent surface even at hop 1.

---

## 6. Migration & risk

- **No production data yet** (Allen: SW-UPD/substrate not in production). So this is a **code move**, not a live data migration.
- **`ConfigObject` table is unchanged.** Only the Ecto schema *module* relocates (`Ezagent.Socialware.ConfigObject` → `…Identity…`). The table name stays; the existing migration that created it stays where it is (or is re-homed without altering the table). No `ALTER`/data backfill.
- **TEST DB ONLY** for any verification; never `mix ecto.migrate` against dev/prod (:10042/:10043).
- **`system://agent-internal` cleanup:** drop the #607-specific `cap(:agent, Sandbox, :read)` entry; the shared `cap(:agent, Sandbox, :write_path)` **stays** (still used by `Agent.do_record_sandbox_state/3`). Leave a comment recording the #607 removal, mirroring the ApiKeys-flip comment.

- **Replay guard moves WITH the store (codex Q5):** the Turn crash-recovery scan calls `ConfigStore.applied_for_turn?/1` keyed by `source_turn_id` (`turn.ex:163-170`). After the store relocates to identity, this call site must resolve to the new module (the Turn already depends on identity), and the Agent-side write must keep stamping `source_turn_id` on the `ConfigObject` and preserve the object→repoint→pointer ordering. Carry the P2.5c replay test.

- **`ConfigProjection` registration + resolver ownership move (codex Q6):** `ConfigProjection.register()` runs from `socialware`'s `application.ex:17-20` and the `socialware-config-object` URI delegates to the `:socialware_config_dir` resolver (`instance_message/uri_query_resolvers.ex:98-131`). The boot `register/0` moves to identity's `application.ex`; the `UriQuery` delegation is preserved (the coupling is runtime via `Ezagent.UriQuery`, NOT a compile dep — so no cycle and the `uri_query` arch gate stays green).

- **`BehaviorSet` + `SocialwareSession` metadata (codex Q6 LOW):** remove `config_updates: Ezagent.Behavior.ConfigUpdate` and the `ConfigUpdate => %{turns: :required, chat: :required}` `@required_reads` entry from `behavior_set.ex:165-183`; add `ConfigEvolve`'s slice + its `%{sandbox: :required}` sibling-read closure (on the Agent Kind side). Remove `ConfigUpdate` from `SocialwareSession.behaviors` (`socialware_session.ex:15-21`). These keep the static lifecycle / cap-chokepoint / required-reads gates green.

---

## 7. Testing (TDD)

1. **Authority gate (load-bearing):** a caller holding the target agent's manage-cap CAN `apply_config_delta`/`repoint_config`; a caller WITHOUT it is denied. A cross-agent caller (manage-cap on agent X, target agent Y) is denied.
2. **Step 2 projection:** after step 1 commits, the agent's `project_cascade_to_sandbox` cast refreshes `cascade_resolution.user_layer_uri` in its own Sandbox slice; assert the Sandbox cache matches the `ConfigStore` pointer once the deferred dispatch runs.
3. **No cross-entity escalation:** the step-2 sandbox write succeeds via the agent's **self-scoped** `Sandbox.write_path` cap, and FAILS (logged, non-fatal) if that self-cap is absent. After the move, `system://agent-internal` no longer carries the #607 `cap(:agent, Sandbox, :read)`, and no session-scoped caller can write another agent's Sandbox via this path.
3b. **Authority wiring (Q3):** a manager holding the target agent's manage-cap passes the step-1 settlement dispatch; a caller with only session-scoped caps is **denied** (the corrected, tightened gate). A cross-agent manager (manage-cap on X, target Y) is denied.
3c. **Eventual-consistency + boot reconciliation:** simulate a crash between step-1 commit and step-2 running (drop the deferred cast) → the Sandbox cache is stale but `ConfigStore` is correct; on `ConfigEvolve.activate` the reconciliation re-derives the Sandbox cache from `ConfigStore` → cache matches source. (The durable consume is never lost.)
4. **Object-keyed ordering preserved:** carry over the #607 ordering/partial-write tests (object → pointer; infra-failure-between leaves only non-harmful state) against the relocated step-1 code.
5. **Idempotency / crash replay:** carry over P2.5c `applied_for_turn?` / `source_turn_id` replay tests.
6. **Confused-deputy regression:** the old crafted-`subject_uri` attack now has no surface (the agent is the subject); assert the validation rejects malformed delta shapes upfront.
7. **End-to-end SW-UPD:** a socialware Turn settles a config delta → dispatches to the target agent → the agent's user cascade layer resolves the new immutable object on next spawn (the consume is real, via `ConfigProjection.resolve_config_dir` / `CascadeRuntime`).
8. **Full umbrella `mix test`** + arch fitness (`lifecycle`, `oversized_modules_gt_1000`, `cap_check_only_at_chokepoint`, `uri_query`, `cross_file_duplicate_fn`) green from the worktree root.

---

## 8. Non-goals

- **Membership-based** management authority (granting a manage-cap to a non-creator who only shares session membership). #533 covers the creator/lineage half; the membership grant is a team-routing follow-up. If a real evolver needs it, grant the manage-cap at the relationship point — out of scope here.
- Re-modelling the `Turn` settlement machinery beyond changing its dispatch target.
- Any P5 work (this is its prerequisite).

---

## 9. Relationship to P5

P5 collapses the two parallel session Kinds into one substrate Kind. By deleting `ConfigUpdate` from the socialware Session here, P5's union behavior-set loses an entire behavior and the cross-entity escalation it carried — the collapse is cleaner and the `chat`/`socialware` compositions are purely session-scoped behaviors. This refactor merges first; P5 follows.
