# Agent-Owned Config-Evolve — Design Spec

> **STATUS: design, rev 2 (codex round-1 REVISE addressed), awaiting re-review + Allen review.** Prerequisite refactor that must merge BEFORE the P5 collapse-to-one-Kind work (Allen, 2026-06-11). Decided in Feishu brainstorm: **full move** of config-application from the socialware Session to the Agent entity.
>
> **rev 2 (codex round-1):** Q2 — the cascade-layer write is NOT cap-free; behaviors write only their own slice (sibling slices are read-only), so the agent mutates its own Sandbox via a **capped self-dispatch** under a self-scoped cap (§3). Q3 — the manage-cap authority is load-bearing and today's callers don't hold it, so the plan must **wire the manage-cap grant to the legitimate evolvers and update the tests** (§4); this is a deliberate authority tightening, safe because SW-UPD is not in production. Q5/Q6 — the replay guard + `source_turn_id` + the `ConfigProjection` boot-registration + the `BehaviorSet`/`SocialwareSession` metadata all move with the code (§6).

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
1  read settled turn + extract delta        ── stays SESSION-side (reads the session's own :turns slice)
2  validate_and_normalize (delta shape)      ── SPLIT (see §4)
3  ConfigStore.write_config (immutable obj)  ── MOVES to agent domain (it is the agent's config-version history)
4 ★ repoint the AGENT's Sandbox cascade layer ── MOVES to the agent; runs IN-PROCESS under the agent's own identity
5  ConfigStore.put_pointer (rollback ledger) ── MOVES to agent domain
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

A new behavior `Ezagent.Behavior.ConfigEvolve` (in `ezagent_domain_identity`), registered on the **Agent** Kind alongside `Sandbox`/`CredentialGrant`/`ApiKeys`:

```elixir
# Agent.behaviors/0 gains Ezagent.Behavior.ConfigEvolve
action(:apply_config_delta, args: %{...delta...}, caps: [:apply_config_delta], modes: [:call])
action(:repoint_config,     args: %{...layer, config_id...}, caps: [:repoint_config], modes: [:call])
```

- **`apply_config_delta`** — the agent writes a NEW immutable `ConfigObject` (from the delta carried by a settled turn), repoints its OWN user cascade layer at that object, and records the rollback pointer. Object-keyed ordering preserved (§5).
- **`repoint_config`** — rollback / explicit advance to an existing immutable object on the agent's own layer.

**The cascade-layer write mechanism (codex Q2 — corrected).** A behavior writes ONLY its own slice; sibling slices are injected **read-only** (`apps/ezagent_core/lib/ezagent/kind/runtime/context.ex:37-40`, `apps/ezagent_core/lib/ezagent/behavior/effects.ex:158-193`). The cascade pointer lives in the **`Sandbox`** slice (`respawn_template_data.cascade_resolution.user_layer_uri`), which the spawn-time `CascadeRuntime` reads. So `ConfigEvolve` cannot write it directly, and the original "no-cap in-process write" claim was wrong (the ApiKeys precedent was a *read*; this is a read-modify-write).

The agent updates the pointer via a **capped self-dispatch of `sandbox.write_path`**: `ConfigEvolve`'s handler reads the current `cascade_resolution` in-process via `reads_siblings([:sandbox])` (the read side — the genuine ApiKeys precedent), computes the new `user_layer_uri`, and emits a `Cmd` targeting **its own URI** (`sandbox.write_path`), processed in-process by the same `Kind.Server`. This requires a **self-scoped** `cap(:agent, Ezagent.Behavior.Sandbox, :write_path, instance: self)` granted to the agent over itself (added to the agent's base self-caps at create).

This is **not** cap-free — but it is **not** the #607 confused-deputy either. The structural win holds: there is no longer any path where a caller-controlled `subject_uri` lets a *session* write an *arbitrary* agent's Sandbox. The write runs under the agent's **own self-authority** (instance-scoped to itself), and the cross-entity `system://agent-internal` escalation is removed. (Alternative considered and rejected for now: move `user_layer_uri` out of the Sandbox slice into `ConfigEvolve`'s own slice — eliminates the self-dispatch but ripples into the spawn-time `CascadeRuntime` read path; deferred as higher-risk, YAGNI.)

---

## 4. Authority model — pure A (the agent's manage-cap)

The two new actions require the **agent's manage-cap**:

```
required_caps[:apply_config_delta] = required_caps[:repoint_config]
  = cap(:agent, Ezagent.Behavior.Manage, :any)   # resolved against the target agent instance at dispatch
```

This reuses the **already-built and merged** #533 machinery (verified on main 2026-06-11):

- `Ezagent.CreatorGrant.manage_cap/4` mints `cap(:<kind>, Ezagent.Behavior.Manage, :any, instance: uri)`.
- `Ezagent.Behavior.Manage` is registered on every Kind.
- The agent-create path (`agent_create.ex` `grant_agent_creator_manage_cap` → `Ezagent.Workspace.grant_creator_manage_cap(:agent, …)`) grants the **creator** the agent's manage-cap.

So **whoever manages the agent holds the cap and may evolve it** (the orchestrator/evolver/creator who created it; granting to N entities is supported). The old `ConfigUpdate` "membership OR spawn-lineage" predicate was a *pre-manage-cap approximation* of management authority; it is **retired**, not preserved as a fallback. Authority = manage-cap, period.

**Why the manage-cap (not a new `config_evolve` cap):** config-evolve is bundled under *management* authority by design (Allen-endorsed 2026-06-11: "谁持有 manage-cap 谁就可以更新 agent"). Evolving an agent's soul is a management act of the same weight as `Manage.delete`/`reconfigure`; gating it by the same cap means there is exactly one authority concept for "may control this agent," not a proliferation of per-action caps. (A future split is possible if a role should evolve but not delete — out of scope; YAGNI.)

**How legitimate evolvers acquire the cap (codex Q3 — load-bearing).** Codex confirmed today's SW-UPD callers pass with ordinary **session-scoped user caps**, NOT the Agent manage-cap (`config_update_test.exs:294-301,345-357`; the settling caller's caps are forwarded at `turn.ex:585-597`). So flipping the gate to the manage-cap **denies them unless the cap is wired**. This is a deliberate authority tightening — safe because SW-UPD is **not in production** — and the wiring is in-scope here, NOT a deferred diligence note:

- **Manager-driven evolution** (orchestrator / creator runs SW-UPD on an agent it manages): the caller already holds `cap(:agent, Manage, :any, instance: agent)` via the #533 create-grant. The plan asserts this with a test where the authorized manager passes and a non-manager is denied.
- **Self-evolution** (the agent evolves itself): the SW-UPD turn runs in the agent's own context, so `ctx.caller == the agent`. The agent is granted a **self-scoped** `cap(:agent, Manage, :any, instance: self)` at create (the same base-self-cap grant that carries the self-scoped `Sandbox.write_path` from §3). The agent manages itself.
- **Any other current caller** that passed only via the old membership predicate: the plan identifies it and grants the manage-cap at the point its management relationship is established — it is NOT given a membership fallback. If no such legitimate caller exists, the tightening simply removes an over-broad path.

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
    → ConfigEvolve (AGENT behavior) handles it; gate = target agent's manage-cap (§4):
      → write_config (object)                 (agent's own config-version store)
      → read cascade_resolution via reads_siblings([:sandbox])   (in-process read)
      → emit Cmd(sandbox.write_path → SELF)    (capped self-dispatch; self-scoped Sandbox cap)
      → put_pointer                            (agent's own rollback ledger)
```

The **object-keyed ordering** that makes the two-store write atomic-by-ordering (object → repoint → pointer; #607 CRITICAL) is preserved verbatim — it just runs inside the agent now. The P2.5c durable idempotency marker (`source_turn_id` on the `ConfigObject`, `applied_for_turn?`) and crash-replay semantics move unchanged **with the store** (§6 — the replay guard the Turn's recovery scan calls at `turn.ex:163-170` must remain reachable after the store relocates).

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
2. **Self-iteration:** the agent evolving itself (caller == subject) is authorized.
3. **No cross-entity escalation:** the cascade-layer write succeeds via the agent's **self-scoped** `Sandbox.write_path` cap (the self-dispatch), and FAILS if that self-cap is absent (proving it is genuinely cap-gated, not bypassing). After the move, `system://agent-internal` no longer carries the #607 `cap(:agent, Sandbox, :read)`, and no session-scoped caller can write another agent's Sandbox via this path.
3b. **Authority wiring (Q3):** a manager holding the target agent's manage-cap passes the settlement dispatch; a caller with only session-scoped caps is **denied** (the corrected, tightened gate). Self-evolution (caller == the agent, holding its self-scoped manage-cap) passes.
4. **Object-keyed ordering preserved:** carry over the #607 ordering/partial-write tests (object → repoint → pointer; infra-failure-between leaves only non-harmful state) against the relocated code.
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
