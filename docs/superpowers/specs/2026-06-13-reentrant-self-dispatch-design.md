# Re-entrant (in-process) self-dispatch — design

> Decision D (Allen 2026-06-13): touch the dispatch/runtime core so a dispatch
> whose target is the **currently-executing Kind process** runs **in-process**
> (synchronously, against the live threaded state) instead of a self
> `GenServer.call`, preserving the CapBAC chokepoint. Also correct the invariant
> tests + the `ezagent-developer` skill so future development knows this path
> exists.

## 1. Problem

`Ezagent.Invocation.dispatch` to a Kind resolves (eventually) to
`GenServer.call(kind_pid, {:ezagent_dispatch, inv})` (`invocation.ex:260`). A
GenServer cannot synchronously `call` **itself**: while it is inside
`handle_call/handle_cast` for message A, the process is busy; a `call` to its
own pid sits unprocessed in its mailbox while the current frame blocks for the
reply → 5s timeout → crash. This is an OTP hard property, not a logic bug.

So any code that, **while running inside a Kind's dispatch handler**, wants to
synchronously dispatch (`mode: :call`) to the **same** Kind deadlocks. The
codebase has repeatedly hand-rolled workarounds for exactly this class:
- `Behavior.CurlAgent` reads `:api_keys` via `reads_sibling_slices/0` (PR #389)
  rather than `Kind.get_slice(self)`.
- `Behavior.Session.Delivery` resolves flavor via ETS + `SnapshotStore` rather
  than `Kind.get_slice(self)` (this session, curl P2).

It is now load-bearing for the **orchestrator-MCP transport split (PR-8 / O-4)**:
the spec puts the 7 orchestrator tool *operations* on the session domain and has
the cc transport forward `tools/call` via `Invocation.dispatch` to a session
action. If that action runs as a **Session Kind action** (in the session's
GenServer), the tools — which themselves dispatch back to the same session
(`chat.join` for `add_managed_member`, `routing.add_rule` for
`define_rule_set_rule`, `chat.set_prompt_templates` for `define_prompt_template`)
— deadlock. Every MUTATING orchestrator tool is affected.

## 2. Why the existing escape hatches don't cover it

The runtime already has TWO ways a Kind can affect state beyond its own slice:
1. **Effect grammar** — a Behavior handler returns effects, including
   `%Ezagent.Cmd{}` dispatches re-entered via `Ezagent.Router.dispatch/1`.
2. **Deferred post-commit dispatches (P2.5c)** — the 5th element of
   `Kind.Runtime.handle_dispatch/4`'s result tuple; `Kind.Server` commits the
   slice, then `Ezagent.Kind.DeferredDispatch.enqueue(deferred)` runs them
   **after** the current call returns (so a deferred dispatch to self is NOT a
   self-`call` — it runs in a fresh handler frame).

Neither fits the orchestrator tools: they need a **synchronous result** (the MCP
`tools/call` must return "did add_managed_member succeed / what was the impact"
to claude). Deferred post-commit dispatches are fire-after-commit — no result is
returned to the original caller. And the effect grammar is declarative (emit
effects), not imperative ("dispatch sub-op, read its result, branch on it").

## 3. The mechanism that's missing

`Kind.Runtime.handle_dispatch(inv, state, kind_module, self_uri)` is already an
(almost) **pure function**: `state → {:ok, new_state, result, slice_change_event,
deferred} | {:error, _}`. The CapBAC check (`Capability.matches?`) is the "5.5
authz gate" **inside** `handle_dispatch` (`runtime.ex:62, 547/558`) — so calling
`handle_dispatch` in-process re-runs the cap check; authority is NOT bypassed.

What's missing is a **synchronous in-process re-entrant path**: a way, while the
session Kind's GenServer is executing an outer dispatch, to run a sub-dispatch
to the **same** Kind by calling `handle_dispatch` **in the current process**
against the **threaded** state, getting the sub-result back, and folding the
sub-dispatch's `new_state` / `slice_change_event` / `deferred` into the outer
dispatch's outcome.

### 3.1 Exposure — the core design question (FOR CODEX/ALLEN REVIEW)

Behavior handlers are pure and **slice-scoped** (`invoke_behavior` passes only
`(slice, args, ctx)`), so a handler can't itself call `handle_dispatch` (it has
no full state, and it returns effects, not a mutated state). The re-entrant
sub-dispatch must be owned by a level that HOLDS the state. Two candidate shapes:

**Option D-effect (recommended):** a new SYNCHRONOUS effect the outer handler
emits — `{:sync_dispatch, sub_inv}` (or a sequence). `Kind.Runtime`, while still
in the outer `handle_dispatch` frame (so still in the session process), runs each
`sub_inv` via `handle_dispatch(sub_inv, threaded_state, kind, uri)`, threading
`new_state` forward and accumulating `deferred`/`slice_change`. The sub-results
are handed back to the outer handler so it can build its own result. Keeps the
"behavior emits effects" purity; the new effect is just "synchronous sub-command
against self." The cap check runs per sub-`handle_dispatch`.
- Open Q: how the outer handler consumes the sub-results to build ITS result.
  Likely the outer action is a thin "run this tool" whose result IS the
  sub-sequence's collected results — i.e. `Orchestrator.Tools` becomes a builder
  of `[sub_inv]` + a result-shaper, run by the runtime, not a caller of
  `Invocation.dispatch`.

**Option D-ctx-callback:** inject `ctx.dispatch_self.(sub_inv)` available only
inside a Kind dispatch frame; it re-enters `handle_dispatch` against a
runtime-held state accumulator (process-scoped to this outer dispatch) and
returns the sub-result synchronously. More imperative/ergonomic for the tools,
but breaks handler purity (a handler now performs effects mid-body) and needs the
runtime to own a per-frame mutable state accumulator. Higher risk to the
effect-ordering / commit guarantees.

Recommendation: **D-effect** (preserves the pure-handler model + composes with
the existing effect/commit pipeline). Codex to scrutinize both.

### 3.2 Correctness requirements (the hard part)

1. **Single commit, right order.** The outer dispatch must still produce ONE
   coherent committed state. Sub-dispatches thread `new_state` in sequence; the
   Server loop commits the FINAL threaded state once (no double-persist, no
   per-sub-commit), and runs the UNION of `deferred` post-commit dispatches in
   declared order.
2. **slice_change_event composition.** Each sub-dispatch may produce a
   `slice_change_event`; these must be emitted in order after commit (or merged),
   matching today's single-dispatch semantics for subscribers/cursors.
3. **Re-entrancy bound + cycle guard.** A sub-dispatch could itself emit
   `:sync_dispatch`. Bound the depth (and detect a self-cycle) → fail loud,
   never infinite-loop the GenServer.
4. **Cross-Kind sub-ops are unchanged.** A sub-op targeting a DIFFERENT Kind
   (e.g. `add_managed_member` spawning a worker Agent) is a normal cross-process
   `GenServer.call` — only **same-process self-targets** take the in-process
   path. The runtime decides per-target: `target Kind pid == self()` → in-process.
5. **Auth unchanged.** Each sub-dispatch runs the full `handle_dispatch` authz
   gate (5.5) + workspace isolation (5.6) against the SAME `ctx.caps`. No new
   ambient authority; scope-narrowing only (Invariant #5).
6. **Failure propagation.** A sub-dispatch `{:error, _}` aborts the outer
   sequence (no partial commit of later sub-ops); the already-applied earlier
   sub-state is discarded with the outer rollback, matching atomicity
   (`add_managed_member` must not leave a spawned-but-unjoined member — note the
   worker-spawn is cross-Kind, so ordering: do same-session mutations first / or
   make the spawn a compensatable/deferred step — to be settled in the plan).

## 4. Invariant-test + skill corrections (Allen's explicit ask)

- The gates/patterns that treat self-dispatch as forbidden (the implicit rule
  behind `reads_sibling_slices` + the delivery ETS workaround) get an explicit
  sanctioned path: "synchronous self-dispatch is allowed ONLY via the runtime's
  in-process re-entrant path (`:sync_dispatch` effect); a raw
  `Invocation.dispatch(self, mode: :call)` from inside a handler is still
  forbidden (deadlock)." Add/adjust the relevant `check_invariants` / arch gate
  so the new path is recognized and the raw self-`call` stays banned.
- `ezagent-developer` SKILL.md: document the re-entrant self-dispatch path —
  when you need a synchronous sub-operation on the SAME Kind, emit
  `:sync_dispatch`, do NOT `Invocation.dispatch(self, :call)`. Note cross-Kind
  dispatch stays normal.

## 5. How PR-8 then closes (trivially)

With D in place, the orchestrator-MCP split is clean: cc McpServer stays the thin
transport (decode + forward, carrying only the caller URI + empty caps). The
session-side `orchestrate.<tool>` action lives on a session Behavior; it does the
fail-closed `caller == session.orchestrator_uri` structural check + reconstructs
the orchestrator's delegated caps session-side, then runs the tool's sub-ops via
`:sync_dispatch` (same-session) + normal dispatch (cross-Kind). No separate
executor process, no deadlock, no plugin-held authority. The existing auth-net
tests (no-admin-fallback denial / cap-#2 happy+deny / per-kind list / the new
O-4 structural-deny) become the regression net.

## 6. Risks / why this is core

This touches the heart of the dispatch pipeline (`Kind.Runtime.handle_dispatch`
+ `Kind.Server` commit loop + the effect grammar). The risks are effect-ordering
/ double-commit / re-entrancy correctness (§3.2). Mitigation: design reviewed by
codex BEFORE implementation; implement behind the existing dispatch tests +
add re-entrancy-specific tests (single-commit, ordered slice_change, depth bound,
cross-Kind unchanged, auth per sub-op, failure rollback); land as its OWN core PR
before the PR-8 close-out.
