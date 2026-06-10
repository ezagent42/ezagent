# Socialware Substrate P2.5c — Post-Parent-Turn-Commit Delivery Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (`feedback_subagent_must_load_project_skills`).

**Goal:** Close the rev4-HIGH ordering bug: a Kind's `{:dispatch, …}` effects run **synchronously inside the handler** (`Router.dispatch` in `invoke_behavior`), which is **before** `Kind.Server.commit_and_notify` durably persists the parent slice. For `turn.settle`, that means the settlement `:approve` + `:commit_settlement` (which write the outbox, flip status to `:committed`, and broadcast a committed customer delivery) execute **before** the parent `:turns` slice commits. If that parent commit then fails (`{:error, {:persistence_failed, _}}` — issue #342), the Turn never durably settled, yet a committed customer delivery already exists: an **orphan delivery for a turn that didn't happen**.

**Architecture (two halves — fast path + crash safety net):**
- **(a) Deferred dispatch (fast path):** a new general effect `{:dispatch_after_commit, %Ezagent.Cmd{}}` the runtime collects (resolved+enriched like a normal `:dispatch`) but does NOT execute during the handler; `Kind.Server` runs it via `Router.dispatch` **only after `commit_and_notify` returns `:ok`/`:not_durable`**, SKIPS on `{:error, _}`. `Behavior.Turn` switches its settlement `:approve`/`:commit_settlement` (+ `config_update`'s `:apply_delta`) to `{:dispatch_after_commit, …}`. Symmetric with the existing post-commit `SliceChange.emit` gate (codex PR-N1) — extended from notifications to re-entrant dispatches.
- **(b) `Turn.activated/2` recovery (crash safety net):** because the deferred cast is in-memory, a crash AFTER the parent commit but BEFORE the cast would lose the delivery. `prepare_settlement` durably creates the `:pending` SettlementRecord BEFORE the parent commit, so `activated/2` (runs post-`:ready` on every start) replays approve+commit for any `:settled` turn whose settlement is still `:pending`. Both paths are idempotent (re-approve same version; `commit_after_pointer` no-ops when committed — P2.5b), so (a) and (b) converge to the same end state: no orphan delivery (rev4) AND no lost delivery (crash-window).

**Tech Stack:** Elixir 1.19 / OTP 27, `ezagent_core` (`Behavior.Effects`, `Kind.Runtime`, `Kind.Runtime.Effects`, `Kind.Server`) + `ezagent_domain_socialware` (`Behavior.Turn`). ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

**RISK + GATE:** This changes the `ezagent_core` dispatch return shape that EVERY Kind flows through (3-tuple → 4-tuple in the invoke chain; 4-tuple → 5-tuple from `handle_dispatch` to `Kind.Server`). The gate is FULL-repo regression (`MIX_ENV=test mix test`), all arch fitness gates, and a parent-commit-rollback test. Additive + default-empty: a handler that emits no `:dispatch_after_commit` effect behaves byte-for-byte as today (the new bucket is `[]`, the post-commit step is a no-op).

---

## Background — grounded current state

**The synchronous-dispatch path (the bug):**
- `Ezagent.Kind.Runtime.handle_dispatch/4` (`runtime.ex:123`) runs `invoke_behavior` → `invoke_new_contract` → `invoke_new_contract_handler` → `invoke_handler_with_post` → `apply_new_contract_effects` (`runtime.ex:873`).
- `apply_new_contract_effects/4` (`runtime/effects.ex:82`) → `Ezagent.Behavior.apply_effects/2` buckets effects, then `execute_buckets/2` runs them: `execute_dispatches/2` (`runtime/effects.ex:259`) calls `Ezagent.Router.dispatch/1` **synchronously**, returning before `apply_new_contract_effects` returns `{:ok, buckets.state, result}`.
- So all `{:dispatch, %Cmd{}}` effects execute INSIDE `handle_dispatch`, which returns `{:ok, new_state, result, slice_change_event}` to `Kind.Server`.
- `Kind.Server.handle_call({:ezagent_dispatch, …})` (`kind/server.ex:616`) and `handle_cast` (`:643`) THEN call `commit_and_notify/3` (`:686`) → `Snapshot.commit/4` persists the parent slice. On `{:error, reason}` (issue #342) the in-memory slice is NOT advanced and `{:error, {:persistence_failed, reason}}` is returned — but the `:dispatch` effects already ran.
- `Behavior.Turn.handle_settle/2` (`socialware/.../turn.ex:180`) runs `prepare_settlement` in-handler then returns `settle_commit_effects/3` → `approve_and_commit_effects/3` (`turn.ex:308`) = `[{:dispatch, Cmd(:approve)}, {:dispatch, Cmd(:commit_settlement)}]` (+ `config_update_effects` `{:dispatch, Cmd(:apply_delta)}`). These are the effects that must wait for the parent `:turns` commit.

**The invoke-chain return shapes (what P2.5c threads a 4th element through):**
- `apply_new_contract_effects/4` → `{:ok, buckets.state, result}` | `{:error, _}` (`runtime/effects.ex:82-104`).
- `invoke_handler_with_post/7` → `{:ok, slice, result}` (no-effects branch) | the `apply_new_contract_effects` result | `{:error, _}` (`runtime.ex:859-904`).
- `invoke_new_contract_handler/6` → `{:ok, slice, result}` (pre_handle `:halt`) | `invoke_handler_with_post` result | `{:error, _}` (`runtime.ex:826-854`).
- `invoke_new_contract/5` passes through. (Confirm whether a LEGACY invoke branch exists — `rg -n "defp invoke_behavior|invoke_legacy|Phase 1.5" apps/ezagent_core/lib/ezagent/kind/runtime.ex` — if so it ALSO returns `{:ok, slice, result}` and must emit `[]` as the 4th element.)
- `handle_dispatch/4` binds `{:ok, new_slice, result_or_nil} <- invoke_behavior(...)` (`runtime.ex:189`) and returns `{:ok, new_state, result, slice_change_event}` (`runtime.ex:250-251`).
- `Kind.Server` matches `{:ok, new_slice_state, result, slice_change_event}` (`kind/server.ex:618, 645`).

**Existing post-commit precedent:** `commit_and_notify/3` already gates `SliceChange.emit` on `commit_result in [:ok, :not_durable]` (`kind/server.ex:686-695`). P2.5c runs the deferred dispatches at the SAME gate.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/behavior/effects.ex` | Modify | Add `{:dispatch_after_commit, %Cmd{}}` effect type; bucket into a new `dispatches_after_commit` list (accumulator init + result map); do NOT execute it. |
| `apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex` | Modify | `apply_new_contract_effects/4` returns the deferred list as a 4th element; `execute_buckets/2` ignores `dispatches_after_commit`. |
| `apps/ezagent_core/lib/ezagent/kind/runtime.ex` | Modify | Thread the deferred list through `invoke_handler_with_post`/`invoke_new_contract_handler`/`invoke_new_contract`/`invoke_behavior` (4-tuple) and return it from `handle_dispatch/4` (5-tuple); legacy branch emits `[]`. |
| `apps/ezagent_core/lib/ezagent/kind/server.ex` | Modify | `handle_call`/`handle_cast` match the 5-tuple; after `commit_and_notify` success, run the deferred dispatches via `Router.dispatch`; skip on `{:error, _}`. |
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex` | Modify | `approve_and_commit_effects/3` + `config_update_effects/3` emit `{:dispatch_after_commit, …}` instead of `{:dispatch, …}`. |
| `apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs` | Create | Unit: a stub Kind whose handler emits `{:dispatch_after_commit, cmd}` — runs after a successful commit; does NOT run when the parent commit fails. |
| `apps/ezagent_domain_socialware/test/integration/parent_commit_rollback_test.exs` | Create | The rev4 gate: force the parent `:turns` slice commit to FAIL after `turn.settle` prepares settlement → assert NO committed outbox / committed settlement / customer delivery appears. |

---

## Task 1: New `{:dispatch_after_commit, %Cmd{}}` effect + bucket

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/behavior/effects.ex`

- [ ] **Step 1: Add the effect type + bucket (no execution)**

In `effects.ex`: (a) add to the `@type effect` union (after the `{:dispatch, …}` line):

```elixir
          | {:dispatch_after_commit, Ezagent.Cmd.t()}
```

(b) add `dispatches_after_commit: []` to the accumulator init (next to `dispatches: []`) AND to the result-map typespec/struct; (c) add a bucket clause in the `apply_effects` reducer (next to the `{:dispatch, %Ezagent.Cmd{}}` clause at `effects.ex:104`):

```elixir
      {:dispatch_after_commit, %Ezagent.Cmd{}} = e ->
        # Collected but NOT executed here — Kind.Server runs it AFTER the parent
        # slice durably commits (P2.5c). Bucketed separately from :dispatch.
        bucket_dispatch_after_commit(acc, e)
```

with the helper:

```elixir
  defp bucket_dispatch_after_commit(acc, {:dispatch_after_commit, cmd}) do
    %{acc | dispatches_after_commit: [cmd | acc.dispatches_after_commit]}
  end
```

Ensure the final result map reverses it to source order (mirror how `dispatches` is finalized — read the reduce-finalize at `effects.ex:244` and apply the same `Enum.reverse`).

- [ ] **Step 2: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -10`
Expected: clean (the new bucket is unused by execution yet — that is Task 2/3).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/behavior/effects.ex
git commit -m "feat(core/p2.5c): {:dispatch_after_commit} effect bucket (collected, not executed)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `execute_buckets` RESOLVES + ENRICHES the deferred dispatches and returns them; `apply_new_contract_effects` propagates the list

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex`

> **codex P2.5c review HIGH — deferred dispatches must reuse the EXACT `:dispatch` resolution, not be passed raw to `Kind.Server`.** Normal `:dispatch` effects are (a) `substitute_refs`'d with the post-`dispatch_returning` `returning2` map and (b) enriched by `enrich_dispatch_cmd/2` (caller defaulted to the emitting Kind's `self_uri`, `trace_id` propagated) BEFORE `Router.dispatch`. A raw deferred `Cmd.new(...)` defaults `caller: :system` → it would be authorized as **system** (authority escalation) and would miss ref substitution. So resolve+enrich the deferred cmds HERE (where `ctx` + `returning2` live) and return the RESOLVED list; `Kind.Server` runs already-correct cmds.

- [ ] **Step 1: `execute_buckets` returns the resolved deferred list**

In `runtime/effects.ex`, `execute_buckets/2` (`:124`): after the normal dispatch/notify/event/termination handling, substitute_refs + `enrich_dispatch_cmd/2` each `dispatches_after_commit` cmd (using the SAME `returning2` + `ctx` as the normal dispatches), and return `{:ok, resolved_deferred}` instead of `:ok`:

```elixir
  defp execute_buckets(buckets, ctx) do
    with :ok <- execute_saga(buckets.saga, ctx),
         {:ok, returning2} <-
           execute_dispatches_returning(Map.get(buckets, :dispatches_returning, []), buckets.returning, ctx) do
      dispatches = Enum.map(buckets.dispatches, &Ezagent.Behavior.substitute_refs(&1, returning2))
      notifies = Enum.map(buckets.notifies, &Ezagent.Behavior.substitute_refs(&1, returning2))
      events = Enum.map(buckets.events, &Ezagent.Behavior.substitute_refs(&1, returning2))

      with :ok <- execute_dispatches(dispatches, ctx) do
        execute_notifies(notifies)
        execute_events(events, ctx)
        execute_terminations(buckets.terminations, ctx)

        # P2.5c — RESOLVE the post-commit dispatches with the SAME ref-substitution
        # + enrichment as normal :dispatch effects, but DO NOT run them here. Return
        # them resolved; Kind.Server runs them after the parent slice durably commits.
        deferred =
          buckets
          |> Map.get(:dispatches_after_commit, [])
          |> Enum.map(&Ezagent.Behavior.substitute_refs(&1, returning2))
          |> Enum.map(&enrich_dispatch_cmd(&1, ctx))

        {:ok, deferred}
      end
    end
  end
```

- [ ] **Step 2: `apply_new_contract_effects` returns the resolved list as a 4th element**

```elixir
  def apply_new_contract_effects(slice, result, effects, ctx) do
    case Ezagent.Behavior.apply_effects(effects, slice) do
      {:ok, buckets} ->
        case execute_buckets(buckets, ctx) do
          {:ok, deferred} ->
            {:ok, buckets.state, result, deferred}

          {:error, _} = err ->
            err
        end

      {:halt, reason, _partial} ->
        {:error, {:halt, reason}}
    end
  end
```

(`enrich_dispatch_cmd/2` is already a private fn in this module — reuse it; no new helper.)

- [ ] **Step 3: Compile (will surface the callers to update in Task 3)**

Run: `MIX_ENV=test mix compile 2>&1 | tail -15`
Expected: compiles, but the callers in `runtime.ex` still expect the 3-tuple — Task 3 updates them. (If the compiler errors on arity here, that's expected; proceed to Task 3 and re-compile.)

---

## Task 3: Thread the deferred list through the invoke chain + `handle_dispatch`

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/runtime.ex`

- [ ] **Step 1: Update the invoke-chain return clauses**

Make every `invoke_*` success return a 4-tuple `{:ok, slice, result, deferred}` (deferred = `[]` where no effects ran):
- `invoke_handler_with_post/7` (`runtime.ex:859`): the `{:ok, result, effects}` branch already calls `apply_new_contract_effects` → now returns the 4-tuple, pass it through. The `{:ok, result}` (no-effects) branch returns `{:ok, slice, result}` → change to `{:ok, slice, result, []}`. The post_handle-injected-effects branch likewise threads the 4-tuple.
- `invoke_new_contract_handler/6` (`runtime.ex:826`): the pre_handle `:halt` branch `{:ok, slice, result}` → `{:ok, slice, result, []}`; the `{:cont, …}` branch passes through `invoke_handler_with_post`'s 4-tuple.
- `invoke_new_contract/5` passes through.
- **Legacy branch:** if `invoke_behavior` has a legacy (non-new-contract) clause returning `{:ok, slice, result}`, change it to `{:ok, slice, result, []}` (legacy behaviors never emit `:dispatch_after_commit`). Confirm via `rg`.

- [ ] **Step 2: `handle_dispatch/4` binds + returns the deferred list (5-tuple to Kind.Server)**

At `runtime.ex:189`, change the bind to the 4-tuple and the returns (`runtime.ex:249-252`) to a 5-tuple:

```elixir
         {:ok, new_slice, result_or_nil, deferred} <-
           invoke_behavior(behavior_module, action, slice, args, invoke_ctx) do
      # ... new_state, slice_change_event computed as today ...
      case result_or_nil do
        nil -> {:ok, new_state, nil, slice_change_event, deferred}
        result -> {:ok, new_state, result, slice_change_event, deferred}
      end
```

- [ ] **Step 3: Compile**

Run: `MIX_ENV=test mix compile 2>&1 | tail -15`
Expected: now `Kind.Server` is the only remaining arity mismatch (it matches the 4-tuple) — fixed in Task 4.

- [ ] **Step 4: Commit (Tasks 2+3 together — one compiling unit)**

```bash
git add apps/ezagent_core/lib/ezagent/kind/runtime/effects.ex apps/ezagent_core/lib/ezagent/kind/runtime.ex
git commit -m "feat(core/p2.5c): thread dispatch_after_commit through invoke chain + handle_dispatch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `Kind.Server` runs the deferred dispatches AFTER commit success

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex`
- Test: `apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs` (create)

- [ ] **Step 1: Write the failing unit test**

Create `apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs` — a minimal Kind whose handler emits `{:dispatch_after_commit, cmd}` to a probe, asserting the probe fires after a successful commit, and (with a forced commit failure) does NOT fire. Use the existing core test scaffolding for an in-line Kind + a stubbed `Snapshot.commit` failure path — READ `apps/ezagent_core/test/**` for the established pattern (e.g. how `issue #342` / persistence-failure is already tested) before writing; mirror it. Assert:
  - success: the deferred command is dispatched exactly once, AFTER the slice is persisted (observe via the probe + a `Kind.get_slice` showing the committed slice).
  - failure: when `commit_and_notify` returns `{:error, _}`, the deferred command is NOT dispatched and the call returns `{:error, {:persistence_failed, _}}`.
  - **enrichment (codex HIGH):** a deferred `Cmd` emitted with NO `caller` (default) is dispatched with `caller` = the emitting Kind's `self_uri`, NOT `:system` — assert the probe/target observes the emitting-Kind caller (proving `enrich_dispatch_cmd` ran via `execute_buckets`, not a raw `Router.dispatch`).
  - **observable failure (codex MEDIUM):** a deferred `Cmd` aimed at an unavailable/unauthorized target (so `Router.dispatch` returns `{:error, _}`) AFTER a successful parent commit → the parent slice IS committed AND the failure is logged at `:error` (capture with `ExUnit.CaptureLog`), not silently dropped; the other deferred cmds in the same batch still run.

(If a forced-commit-failure seam does not exist in core test support, the parent-commit-rollback integration test in Task 6 is the load-bearing gate; keep this unit test to the success-path + ordering and note the failure-path is covered at the socialware integration level.)

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs -v 2>&1 | tail -20`
Expected: FAIL — the deferred command never dispatches (Kind.Server doesn't run it yet) / arity mismatch on the 5-tuple.

- [ ] **Step 3: Run the deferred dispatches post-commit in `handle_call` + `handle_cast`**

In `kind/server.ex`, update BOTH `handle_call({:ezagent_dispatch, …})` (`:616`) and `handle_cast({:ezagent_dispatch, …})` (`:643`) to match the 5-tuple and run the deferred list ONLY on commit success:

```elixir
  def handle_call({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, _from, state) do
    case Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri) do
      {:ok, new_slice_state, result, slice_change_event, deferred} ->
        case commit_and_notify(state, new_slice_state, slice_change_event) do
          commit_ok when commit_ok in [:ok, :not_durable] ->
            run_deferred_dispatches(deferred)
            reply = if is_nil(result), do: :ok, else: {:ok, result}
            {:reply, reply, %{state | state: new_slice_state}}

          {:error, reason} ->
            # Parent slice did NOT durably commit (issue #342). Do NOT run the
            # deferred dispatches — they would commit a settlement/delivery for a
            # turn that never settled (rev4 HIGH). Slice un-advanced.
            {:reply, {:error, {:persistence_failed, reason}}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end
```

(mirror in `handle_cast`, running `run_deferred_dispatches(deferred)` before `Ezagent.Invocation.reply(inv.ctx, {:ok, result})`.) Add:

```elixir
  # P2.5c — run deferred (post-commit) re-entrant dispatches. Runs ONLY after the
  # parent slice durably committed. The cmds are ALREADY ref-substituted +
  # enriched (caller=self_uri, trace_id) by Runtime.Effects.execute_buckets — so
  # they dispatch with the emitting Kind's authority, NOT :system. The parent
  # commit already succeeded, so a failure here is observational: log BOTH a
  # {:error, reason} Router return AND a raised exception (codex P2.5c MEDIUM:
  # never silently drop a post-commit dispatch — that is the orphan-in-the-other-
  # direction). All cmds run regardless of an individual failure.
  defp run_deferred_dispatches([]), do: :ok

  defp run_deferred_dispatches(cmds) when is_list(cmds) do
    require Logger

    Enum.each(cmds, fn %Ezagent.Cmd{} = cmd ->
      try do
        case Ezagent.Router.dispatch(cmd) do
          :ok ->
            :ok

          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Kind.Server.run_deferred_dispatches: post-commit dispatch FAILED " <>
                "target=#{inspect(cmd.target)} action=#{inspect(cmd.action)} " <>
                "reason=#{inspect(reason)} — parent slice committed but this side " <>
                "effect did not run"
            )
        end
      catch
        kind, reason ->
          Logger.error(
            "Kind.Server.run_deferred_dispatches: post-commit dispatch RAISED " <>
              "target=#{inspect(cmd.target)} action=#{inspect(cmd.action)} " <>
              "#{inspect({kind, reason})}"
          )
      end
    end)
  end
```

> **codex P2.5c MEDIUM (observability):** every `{:error, reason}` from `Router.dispatch` is now logged at `:error` (an operator-visible signal that a settled turn's post-commit side effect did not run), not silently discarded. A DLQ is out of scope for P2.5c (the existing `:dispatch` path also logs-and-aborts rather than DLQ-ing); if a durable retry is needed it belongs with the P3 ExternalAdapter's outbox-replay (the committed_seq cursor already makes the delivery itself replayable — a dropped advisory dispatch is recovered by the next replay).

> **Ordering note:** deferred dispatches run AFTER `commit_and_notify` (which also fires `SliceChange.emit`). That is correct — the parent slice + its notification are durable before any settlement re-dispatch. The deferred dispatch re-enters `Router.dispatch` on the SAME Kind instance (a `:call` would deadlock the GenServer — confirm Turn's settlement Cmds are built with `reply: :ignore` → `:cast`, as they are today in `dispatch_ctx/1`; a post-commit `:cast` self-send is enqueued to the mailbox, NOT a synchronous self-call). VERIFY `dispatch_ctx/1` still yields `reply: :ignore` so these are casts.

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs -v 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/server.ex apps/ezagent_core/test/ezagent/kind/dispatch_after_commit_test.exs
git commit -m "feat(core/p2.5c): run dispatch_after_commit effects only after parent slice durably commits

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `Behavior.Turn` settlement effects become post-commit

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex`

- [ ] **Step 1: Switch the settlement dispatches to `:dispatch_after_commit`**

In `turn.ex`, `approve_and_commit_effects/3` (`:308-322`) and `config_update_effects/3` (`:445-452`): change each `{:dispatch, Cmd.new(...)}` to `{:dispatch_after_commit, Cmd.new(...)}`. These approve / commit_settlement / apply_delta dispatches must run only after the parent `:turns` slice (set by `handle_settle`) durably commits. Leave `prepare_settlement` (the in-handler `begin` + `flip_visibility`) and `dispatch_subtask`'s `:send` (turn.dispatch) as-is — only the settle-time approve/commit/apply_delta move post-commit.

> **Why these three:** `approve` + `commit_settlement` produce the committed customer delivery; `apply_delta` commits a config update. All three are the durable side effects that must not outlive a failed parent-turn commit. `turn.dispatch`'s subtask `:send` (during delegation) is NOT settle-time and stays a normal `:dispatch`.

- [ ] **Step 2: Compile + run the socialware turn/settlement tests**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -10`
Expected: PASS — the existing turn/settlement/customer-feed tests still pass. The settlement now commits one mailbox-hop later (post parent commit) but still completes; the integration tests that `wait_until` on `status: :committed` / the outbox still observe it. (If any test asserted synchronous in-handler settlement, update it to `wait_until` the committed state, with a comment.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex
git commit -m "feat(socialware/p2.5c): settle approve/commit/apply_delta run post-parent-commit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Parent-commit-rollback gate (the rev4 HIGH test) + full regression

**Files:**
- Create: `apps/ezagent_domain_socialware/test/integration/parent_commit_rollback_test.exs`

- [ ] **Step 1: Write the rollback gate test**

Drive a real socialware turn to `compose`, then dispatch `turn.settle` in a way that FORCES the parent `:turns` slice commit to fail, and assert NO committed delivery leaked. The force-fail seam: read how issue #342 / `{:persistence_failed, _}` is exercised in the existing suite (`rg -n "persistence_failed|Snapshot.commit|:not_durable|fail" apps/ezagent_core/test apps/ezagent_domain_socialware/test`) and reuse it. Assert AFTER a forced parent-commit failure on `turn.settle`:
  - `Settlement.get(turn_id)` is `:error` OR `status: :pending` (NOT `:committed`);
  - `Repo.get_by(CustomerOutbox, turn_id: turn_id)` reflects no committed delivery (no row, or committed_seq nil);
  - `MessageStore.committed_customer_visible(session, _)` does NOT include the turn's messages;
  - `CustomerFeed.snapshot/2` exposes neither the page nor the messages.

If a deterministic force-fail seam for a specific dispatch's commit does not exist, ADD a minimal test-only injection (e.g. a configurable `Snapshot.commit` failure for one URI in the test env) rather than skipping the gate — this test IS the phase's acceptance criterion (`feedback_completion_requires_invariant_test`). Flag the seam addition for codex review.

- [ ] **Step 2: Run the gate**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/integration/parent_commit_rollback_test.exs -v 2>&1 | tail -20`
Expected: PASS — no orphan committed delivery for a turn whose parent slice failed to commit. (Pre-P2.5c, this FAILS: the settlement committed before the parent commit failed.)

- [ ] **Step 3: FULL-repo regression + arch gates (core change — do NOT scope down)**

Run (each 0 failures / exit 0):
```bash
MIX_ENV=test mix compile --warnings-as-errors --force 2>&1 | tail -5
MIX_ENV=test mix test 2>&1 | tail -20
MIX_ENV=test mix ezagent.arch.scan 2>&1 | grep -E "FAIL|gt_1000"
MIX_ENV=test mix ezagent.check_invariants 2>&1 | tail -4
MIX_ENV=test mix ezagent.check_invariants.lifecycle 2>&1 | tail -4
```
Expected: the WHOLE umbrella suite green (the dispatch return-shape touches every Kind — full regression is mandatory, not the per-app subset used by leaf phases); no arch FAIL; gt_1000=0; invariants clean.

- [ ] **Step 4: Commit (if any test updated to wait_until)**

```bash
git add -A
git commit -m "test(p2.5c): parent-commit-rollback gate + wait_until settlement-completes fixtures

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Crash-window recovery — `Turn.activated/2` replays settled-but-pending settlements

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex`
- Test: `apps/ezagent_domain_socialware/test/integration/settlement_recovery_on_restart_test.exs` (create)

> **Why (codex rev2 HIGH):** deferring the settlement dispatch (Task 5) fixes the rev4 orphan-delivery, but a BEAM crash AFTER `commit_and_notify` durably marks the turn `:settled` but BEFORE the deferred `:approve`/`:commit_settlement` run would leave a **settled turn whose settlement never commits** — a permanently lost delivery. The deferred dispatch is the FAST path; this recovery is the crash-safety NET. Both are needed.

> **Why it is safe + tractable:** `Turn.prepare_settlement` creates the `:pending` `SettlementRecord` (`Settlement.begin`) BEFORE the parent commit, so after a successful parent commit the durable truth is *turn `:settled` ⟹ a `SettlementRecord` exists; if still `:pending`, the deferred commit was lost → replay it.* Replay is idempotent: `Surface.handle_approve` sets `approved = version` (idempotent); `Settlement.commit_after_pointer` is a full no-op when already `:committed` (P2.5b).

> **SEAM CORRECTION (codex rev4 HIGH — `activated/2` does NOT emit effects).** `Ezagent.Lifecycle` specs `activated/2 :: :ok` (lifecycle.ex:126); its return is ignored. ONLY `handle_signal/2 :: {:ok, [effect()]} | :ignore` (lifecycle.ex:134, "successor to handle_kind_message/3") emits an executed effect list. So recovery is a TWO-STEP seam: (1) `Turn.activated/2` (post-`:ready`, allowed side-effects per its docstring) does `send(self(), {:ezagent_recover_settlements})` and returns `:ok`; (2) `Turn.handle_signal({:ezagent_recover_settlements}, ctx)` scans + emits the recovery effects. **MUST VERIFY at implementation (hands-on, before relying on it):** that `handle_signal/2`'s returned `{:dispatch, …}` effects are actually EXECUTED by the engine's `handle_info → handle_signal → apply_effects` path (its predecessor `handle_kind_message/3` returned only a slice, NOT effects), and that `handle_signal`'s ctx exposes `read/2` + the dispatch-ctx (`self_uri`, caller/caps). If signal-effects are NOT executed on this tree, fall back to a self-dispatched recovery ACTION `Turn.handle_recover_settlements/2` (a normal handler) triggered by the `activated/2` self-send → `handle_info` → `Router.dispatch(self, :recover_settlements)`. The Step-1 test is the proof.

> **Tag the recovery effects NORMAL, not deferred (codex rev4 HIGH).** Task 5 converts `settle_commit_effects/3` (via `approve_and_commit_effects/3` + `config_update_effects/3`) to `:dispatch_after_commit`. Recovery must NOT reuse that as-is — there is no parent-commit gate in the signal/recovery path to consume deferred effects. PARAMETERIZE the helper: `settle_commit_effects(turn_id, turn, ctx, dispatch_kind)` where `:after_commit` (the settle fast path) emits `{:dispatch_after_commit, …}` and `:now` (recovery) emits normal `{:dispatch, …}`. Assert in the recovery test that the emitted effects are `:dispatch`, not `:dispatch_after_commit`.

> **Split settlement-replay from config-replay gating (codex rev4 MEDIUM).** A config-only settled turn has a `config_delta` but NO `SettlementRecord` (settlement is created only for page/message settlement), so `Settlement.get/1` stays `:error` for it — a predicate of "settled AND not committed" would re-run `apply_delta` on EVERY restart, and `apply_delta` writes a NEW immutable config-object UUID + repoints (NOT idempotent). So recovery gates the two independently: (i) **settlement replay** (approve+commit) ONLY when a `:pending` `SettlementRecord` exists for the turn; (ii) **config replay** (`apply_delta`) ONLY when a durable idempotency marker (e.g. the `:config_updates` slice's `applied`/source-turn record) shows it has NOT been applied. A clean start (or an already-applied config / already-committed settlement) emits nothing.

- [ ] **Step 1: Write the failing recovery test**

Create `apps/ezagent_domain_socialware/test/integration/settlement_recovery_on_restart_test.exs`. DETERMINISTIC crash simulation (don't race the deferred cast): set up the durable post-parent-commit-but-pre-deferred state directly, then spawn the session so `activated/2` runs:
  1. Spawn a SocialwareSession; drive `turn.open → dispatch → deliver(page) → compose` so the `:surface` has version N and the `:turns` slice has the turn.
  2. Put the turn into `:settled` in the `:turns` slice + create a `:pending` `Settlement.begin` for it (mirroring what `handle_settle` + `prepare_settlement` durably leave) — WITHOUT running the deferred approve/commit (the "crash lost the deferred casts" state). Persist (the snapshot of `:turns` + the pending SettlementRecord are durable).
  3. Terminate the session via `DynamicSupervisor.terminate_child(EzagentDomainSocialware.SocialwareSessionSupervisor, pid)`; `wait_until KindRegistry.lookup == :error`.
  4. Re-spawn the session (→ `activated/2` runs).
  5. Assert recovery committed the settlement: `Settlement.get(turn_id)` is `:committed`; the committed delivery appears (outbox `committed_seq` set; `CustomerFeed.snapshot` returns the page + committed messages).

Expected (pre-Step-3 impl): FAIL — `activated/2` does not recover, settlement stays `:pending`.

- [ ] **Step 2: Implement `Turn.activated/2` recovery**

Add `activated/2` to `Behavior.Turn`. For each turn in the `:turns` slice with `status: :settled`, check `Settlement.get(turn_id)`; if NOT `:committed`, emit that turn's `settle_commit_effects/3` (the SAME approve + commit_settlement [+ apply_delta] effects `handle_settle` builds). Use NORMAL `{:dispatch, …}` here (NOT `:dispatch_after_commit`): on activate the turn is ALREADY durably `:settled`, there is no parent-commit-in-flight to gate against. The dispatches are idempotent (re-approve same version; commit no-op if already committed). Emit nothing when no settled-but-pending turn exists.

```elixir
  @impl true
  def activated(_state, ctx) do
    turns = ctx.read.(:turns, %{})

    effects =
      turns
      |> Enum.filter(fn {turn_id, turn} ->
        turn.status == :settled and not settlement_committed?(turn_id)
      end)
      |> Enum.flat_map(fn {turn_id, turn} -> settle_commit_effects(turn_id, turn, ctx) end)

    {:ok, effects}
  end

  defp settlement_committed?(turn_id) do
    case Ezagent.Socialware.Settlement.get(turn_id) do
      {:ok, %{status: :committed}} -> true
      _ -> false
    end
  end
```

(Confirm `activated/2`'s ctx exposes `read/2` + the dispatch-ctx the effects need — read `Ezagent.Lifecycle.__run_activated__` + how `handle_settle`'s ctx is built; if `activated` ctx lacks `self_uri`/`caller` for `Cmd.new`/`dispatch_ctx`, thread them the same way the dispatch path enriches, or build the Cmds with the recovery caller. The deferred-dispatch enrichment from Task 2 also applies if these go through the same path.)

- [ ] **Step 3: Run to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/integration/settlement_recovery_on_restart_test.exs -v 2>&1 | tail -20`
Expected: PASS — recovery commits the settled-but-pending settlement on respawn; the delivery appears.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/behavior/turn.ex apps/ezagent_domain_socialware/test/integration/settlement_recovery_on_restart_test.exs
git commit -m "feat(socialware/p2.5c): Turn.activated/2 recovers settled-but-pending settlements on restart

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> **Alternative considered + rejected (too invasive for now):** make the Kind snapshot commit and the settlement Repo writes ONE transaction (Kind.Server wrapping behavior-emitted Repo writes in the snapshot txn) — a much larger core change. The deferred-dispatch + `activated` recovery pair gives the same end-state guarantee (no orphan delivery, no lost delivery) via idempotent replay off the already-durable pending-settlement marker.

---

## Self-Review (run before handing to codex)

1. **Additive + default-safe:** a handler emitting no `:dispatch_after_commit` gets an empty bucket; `run_deferred_dispatches([])` is a no-op; the invoke-chain 4th element is `[]`; behavior is byte-for-byte unchanged for every existing Kind. The return-shape change is the only ripple — verified by FULL-repo regression.
2. **Correct gate:** deferred dispatches run ONLY on `commit_and_notify in [:ok, :not_durable]` (same gate as `SliceChange.emit`); on `{:error, _}` they are skipped + `{:persistence_failed, _}` propagates — closing the rev4 HIGH (no settlement/delivery for a non-durable turn).
2b. **Same authority + resolution as `:dispatch` (codex HIGH):** deferred cmds are `substitute_refs`'d + `enrich_dispatch_cmd`'d inside `execute_buckets` (caller defaulted to the emitting Kind's `self_uri`, not `:system`) BEFORE being returned — `Kind.Server` runs already-resolved cmds, never raw. A deferred cmd is NOT an authority-escalation path.
2c. **Post-commit failures observable (codex MEDIUM):** `run_deferred_dispatches` logs every `Router.dispatch` `{:error, reason}` AND exception at `:error`; it does not silently drop a post-commit side effect for a settled turn. (Durable retry is P3's outbox-replay concern; the committed_seq cursor makes the delivery itself replayable.)
3. **No self-deadlock:** Turn's settlement Cmds use `reply: :ignore` → `:cast`; a post-commit self-`cast` is mailbox-enqueued (the GenServer is mid-`handle_call`/`handle_cast` and will process it next) — NOT a synchronous self-`call`. Verified against `dispatch_ctx/1`.
4. **Ordering vs notify:** deferred dispatches run after `commit_and_notify` (which emits `SliceChange`), so the parent slice + its notification are durable before any settlement re-dispatch — the intended order.
5. **Scope:** only `turn.settle`'s approve/commit/apply_delta move post-commit; `turn.dispatch`'s subtask `:send` stays a normal `:dispatch` (it is not a settle-time durable side effect). #44 wire-schema is P3 prep; the P2.5b cursor is already on main.
6. **Legacy branch:** if a legacy (non-new-contract) invoke clause exists, it returns `{:ok, slice, result, []}` — confirmed by grep before editing.
7. **Crash-window closed (codex rev2 HIGH):** the deferred dispatch is the fast path; `Turn.activated/2` (Task 7) is the crash safety net — on every restart it idempotently replays approve+commit for any `:settled` turn whose settlement is `:pending` (off the durable pre-parent-commit `SettlementRecord`). So (a)+(b) give no-orphan AND no-lost delivery. `activated/2` legitimately emits the same effect list as a handler (lifecycle.ex:121-132). Recovery dispatches are normal `:dispatch` (turn already durably `:settled`, no parent-commit to gate).
