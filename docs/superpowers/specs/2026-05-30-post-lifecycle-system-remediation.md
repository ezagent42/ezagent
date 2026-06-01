# Post-lifecycle system remediation — all known problems + a systematic solution

> Author: Claude, per Allen 2026-05-30 ("请总结现存的所有系统问题，给一个系统解决方案" + "不管是不是 pre-existing，请在本次修复所有问题").
> Grounded in: the full post-lifecycle E2E re-run (live agent-browser + full umbrella `mix test` + pre-lifecycle baseline-diff at `54df56c9`).
> Status: DRAFT for codex adversarial-review before implementation.

## 0. One-paragraph framing

The lifecycle big-bang migration delivered the **framework** (`create` persists state, `activate` rebuilds transients on every (re)start, two-container slice, effect grammar). The E2E proves the framework works **live** — phx cold-boots clean, snapshots restore, agents respawn, ExternalMirror reconciles. But the migration is **structurally incomplete in three ways**, and one pre-existing engine gap got worse. None of these are random bugs; they are four missing/under-specified **contracts**. The systematic fix is to *finish the contracts the migration implied*, each backed by an invariant test, rather than patch symptoms.

## 1. Problem inventory (everything currently known)

### Migration-introduced (baseline-diff: chat 23→43 failures, +20)
- **P1 — Readiness gap (`:not_ready`)** *(PRIMARY)*. A synchronous dispatch (`join`, `subscribe_from`, any `handle_call(:ezagent_dispatch)`) issued to a Kind during its post-init/`activate` window returns `{:error, :not_ready}` instead of waiting. `ReadyGate`+`PendingDelivery` buffer async **casts** but reject synchronous **calls** (`kind/server.ex:281-285`). `activate/2` now runs in post-init `handle_continue`, widening the not-ready window, so this latent gap became a live regression. Breaks the production invariant *"a join/subscribe right after a Session (re)spawn must succeed"* — exactly the cold-restart message-loss class the migration was meant to eliminate. Symptom tests: `SessionSurvivesRestartTest — THE GATE`, `WorkspaceRegistry rebind on rehydrate`, `PublisherSessionTest no-ambient-caps`.
- **P2 — Destroy contract hole**. After `:destroy`, `read`/`write_path` return `{:ok, %{…: nil}}` (empty two-container state) instead of `{:error, :destroyed}`. The process-dict `destroyed?` sentinel was dropped in the Sandbox→Lifecycle conversion ("destroyed = absence of state"), but no engine-level replacement enforces the gate. Symptom: `SandboxDestroyTest` (2).
- **P3 — Two-container parity test-debt**. A handful of tests still assert the old flat slice shape `%{<slice>: %{<field>}}`; product correctly returns `%{<slice>: %{state: %{<field>}}}`. Pure stale assertions. Symptom: `Kind.SnapshotTest` etc.

### Pre-existing (baseline has them too — but Allen: fix this round regardless)
- **P4 — Emit-integrity hole (`Jason.Encoder` for `Ezagent.Capability`)**. `{:emit, :cap_granted, %{cap: %Capability{}}}` (`identity.ex:361`) raises in `EventLog.append` because `Capability` (and nested `URI`/`MapSet`/`DateTime`) aren't JSON-encodable. The emit is caught ("continuing") → **`cap_granted` events are silently dropped from EventLog** (337 raises at baseline). No contract guarantees emit payloads are serializable.
- **P5 — Transient-coverage gaps (the SAME cold-restart class, not yet converted)**:
  - **#114 AgentLineage ETS** — `agent_lineage.ex` is a bare `:ets` table (`record`/`lookup`/`forget`), never persisted nor boot-rebuilt → lineage lost on restart → previously-owned agents become "foreign", breaking ownership/cap gates.
  - **#113 Codex subprocess** — no `ensure_subprocess_alive`/respawn path; a codex agent's bridge subprocess is not re-established on cold-restart.
- **P6 — Test-isolation flakiness (`DBConnection.ConnectionError`)**. Tests spawn `Kind.Server`s that outlive the test owning the Ecto sandbox connection (`owner exited / Client still using connection`) → ~39 cascading failures at baseline. Test-infra, not product.
- **P7 — Dispatch-path inconsistency (#112)**. Facade layers (`workspace.ex`, `identity.ex`, `external_mirror.ex`, `workspace/loader.ex`) call `Invocation.dispatch` directly instead of `Router.dispatch`; the §11 gate only scanned `behavior/`.
- **P8 — minor**: bare-handle login (`admin`) doesn't resolve at the form (full URI works); `#50` template-seed `:not_ready` on first boot (a P1 instance); `#48` LV @-mention parse; `#35` cwd drift; `#62/#63` follow-up nits.

## 2. Root-cause grouping → four contracts to finish

| Theme | Problems | Missing contract |
|---|---|---|
| **A. Readiness** | P1, P8(#50) | *No inbound dispatch is ever rejected for not-being-ready; it is served after `activate`.* |
| **B. Transient completeness** | P5(#113,#114) | *Every piece of non-persisted runtime state is a declared Lifecycle transient, rebuilt in `activate` or on boot.* |
| **C. Effect & lifecycle integrity** | P2, P4 | *Every `:emit` payload is serializable; every Terminable `:destroy` makes subsequent reads return `{:error, :destroyed}`.* |
| **D. Test hygiene** | P3, P6 | *Spawned Kinds are synchronously torn down / sandbox-allowed; fixtures assert the two-container shape.* |
| **E. Dispatch consistency** | P7 | *All facade entry points route through `Router.dispatch`.* |

## 3. Systematic solution

### C-A — Readiness contract (engine, keystone)
In `Kind.Server`, when `handle_call(:ezagent_dispatch, from, …)` arrives while `ReadyGate == :not_ready`, **do not reply `:not_ready`**: stash `{from, dispatch}` into `PendingDelivery` and `{:noreply, …}`; on `drain_then_mark_ready`, execute the buffered call and `GenServer.reply(from, result)`. Casts already buffer — unify both into one buffer with optional `from`. Net: synchronous and async dispatch both wait-then-serve.
- **Invariant test** (`LifecycleCase`): spawn a Kind whose `activate` blocks briefly; issue a synchronous dispatch during the window; assert it returns the real result (never `:not_ready`). Add a cold-restart variant (the `SessionSurvivesRestart` gate).
- Keep an explicit timeout escape so a genuinely stuck `activate` doesn't hang callers forever (bounded buffer wait → `{:error, :activate_timeout}`, a *distinct* signal from the silent `:not_ready`).

### C-B — Transient-completeness audit
- **AgentLineage (#114)**: lineage is `(agent_uri → spawned_by)`. Source of truth already lives in each agent's persisted slice (`spawned_by`). Rebuild the ETS table on boot from agent snapshots (a `BootReconciler`-style sweep), OR fold lineage lookups to read the persisted field directly. Prefer **boot-rebuild from snapshots** (keeps the fast ETS read path, removes the un-rebuilt state).
- **Codex subprocess (#113)**: bring the codex agent under the same `activate`-rebuilds-subprocess pattern Sandbox/PTY use (an `ensure_subprocess_alive` in `activate`).
- **Gate**: extend `check_invariants.lifecycle` to flag raw `:ets.new`/long-lived PID state in `lib/**` that isn't declared a transient or boot-rebuilt (catch the next #114 by construction).

### C-C — Effect & lifecycle integrity
- **Emit serialization (P4)**: add a normalization boundary in `EventLog.append` that coerces payloads to JSON-safe terms (and/or `@derive {Jason.Encoder, …}` on `Capability` + a `Jason.Encoder` impl for `URI`/`MapSet`). Add a test that emits **one of every declared event type** and asserts the row persists. Make `:emit` failures **loud in test** (the "continuing" swallow hid this for months).
- **Destroy gate (P2)**: lift a `:destroyed` marker to `Behavior.Terminable`/engine so that post-`:destroy`, the Kind answers every action with `{:error, :destroyed}` (structural, not per-Behavior process-dict). Restores `SandboxDestroyTest` semantics for all Kinds uniformly.

### C-D — Test hygiene
- Shared `LifecycleCase`/`DataCase` helper: register spawned Kinds and synchronously `Kind.terminate` them in `on_exit`; use `Ecto.Adapters.SQL.Sandbox.allow` for spawned children. Update the few P3 parity assertions to `%{state: …}`.

### C-E — Router consistency (#112)
Migrate facade `Invocation.dispatch` → `Router.dispatch`; widen the §11 gate beyond `behavior/`.

## 4. Sequencing (each step = its own PR, TDD, codex-reviewed, verified green before next)
1. **C-A readiness** (keystone; unblocks the largest failure cluster + #50).
2. **C-C destroy gate + emit serialization** (engine contracts; small, high-value).
3. **C-B transient audit** (#114 boot-rebuild, #113 codex respawn, gate).
4. **C-D test hygiene + P3 parity** (drives the suite to baseline-or-better).
5. **C-E #112 router consistency**.
6. Final: full umbrella suite from root → assert failures ≤ baseline (ideally the sandbox-flakiness class also shrinks once C-A stops the `:not_ready`-crash cascade); live agent-browser + Feishu roundtrip re-verify.

## 5. Acceptance
- Migrated chat failures ≤ baseline (23) and the +20 migration-introduced set is **0**.
- New invariant tests: readiness-buffer, emit-every-event-type, destroy-returns-destroyed, transient-rebuilt (AgentLineage + codex) — all green and each FAILS if its contract regresses.
- Live: cc reply + Feishu outbound roundtrip post-restart, agent-browser screenshot.
