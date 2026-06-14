# Cap-checked in-process op primitive — analysis (task #56)

> **Analysis, not a committed design** (it touches the CapBAC chokepoint —
> "never weaken authz" — so it gets Allen review + codex adversarial-review
> before any code). Frames the problem, enumerates the workaround class it
> retires, sketches the primitive, lists open questions. Code citations are
> point-in-time (post-9b rename to `ezagent_domain_session`).

## 1. The problem

A Kind cannot perform a **cap-checked operation on its own state in-process.**
The normal authority path is *cross-process*: build an `Invocation`, dispatch →
`GenServer.call` to the target Kind → `Kind.Runtime` step 5.5
(`Capability.matches?`) → handler. A Kind that tried to dispatch to *itself* this
way **deadlocks** — it is blocked inside its own `call` handler waiting on a
`call` to itself (`runtime.ex:392-398`: *"that GenServer.call deadlocks against
itself … until the 5s default timeout fires"*).

So when a handler needs another (or its own) slice of the SAME Kind, the code
sidesteps dispatch with **un-cap-checked workarounds**:

## 2. The workaround class (what #56 retires)

1. **`reads_siblings/0`** (+ legacy `reads_sibling_slices/0`) — a Behavior
   statically declares sibling slice keys it reads in-process; `Kind.Runtime`
   surfaces those slices to the handler. The read is gated by a **static
   declaration, NOT a capability.** Live consumers today:
   - `ezagent_domain_session/.../behavior/agent/receive.ex` → `reads_siblings([:sandbox])`
   - `ezagent_domain_external_mirror/.../behavior/external_mirror.ex` → `reads_siblings([:publisher])`
   - `ezagent_domain_identity/.../behavior/config_evolve.ex` → `reads_siblings([:sandbox, :identity])`
2. **`get_slice(self)`-avoidance** — `Kind.Runtime` / delivery code deliberately
   avoids calling `Kind.get_slice` on `self` to dodge the same deadlock.

Both are read-side hacks that bypass the cap chokepoint: a Behavior reading a
sibling slice is authorized by *being declared*, not by *holding a cap*.

## 3. Why the gate can be reused in-process (the key insight)

`Ezagent.Capability.Match.matches?/2` (`capability/match.ex`) is a **pure
function** — it checks a cap against `%{kind, behavior, action, instance,
workspace_uri}` with no process call. The deadlock is caused by the *transport*
(`GenServer.call` to self), NOT by the cap check. So the authority decision can
run **in-process** against `ctx.caps` with zero deadlock risk; only the
cross-process *delivery* of the request is what must be skipped.

This is exactly why part (a) of the rejected option-D (the #53 orchestrator
"D vs C" debate, 2026-06-13) was called *clean + not runtime-fighting*: it is a
pure-function authorization, decoupled from the deadlock machinery (option C /
SessionManager Kind solved the orchestrator via normal cross-process dispatch;
this primitive is orthogonal and was parked as #56).

## 4. Sketch of the primitive (to brainstorm)

A cap-gated in-process operation: authorize via `matches?` against `ctx.caps`,
then operate directly on the in-memory slice — all inside the Kind's own process,
no `GenServer.call`. Conceptually:

```elixir
# inside a handler, ctx.caps in scope:
with :ok <- Ezagent.Capability.authorize_in_process(ctx.caps,
              %{kind: k, behavior: b, action: a, instance: self_uri, workspace_uri: w}) do
  # read/operate on own/sibling slice directly (already in this process)
end
```

- **Same gate, same semantics** as step 5.5 — identical `{kind, behavior,
  action, instance, workspace_uri}` check. It does NOT weaken authz; it removes
  the *transport*, not the *check*. (Contrast: today's `reads_siblings` removes
  the check entirely.)
- **Retires** the workaround class: a `reads_siblings([:sandbox])` read becomes a
  cap-gated in-process read; the static sibling-declaration mechanism + the
  `get_slice(self)`-avoidance can then be deleted.
- **Does NOT include** option-D's runtime-fighting deadlock machinery (explicitly
  out of scope per the #56 task note).

## 5. Open questions (for Allen, before a plan)

1. **API surface.** A `Ezagent.Capability.authorize_in_process/2` helper (pure,
   returns `:ok | {:error, :unauthorized}`), a `Kind.Runtime.in_process_op/…`
   that also performs the op, or a Behavior-level macro? Recommendation: the pure
   `authorize_in_process/2` helper first (smallest, testable, no runtime change),
   then migrate consumers to call it.
2. **Reads only, or reads + writes?** `reads_siblings` is read-only today.
   Extend to cap-gated in-process *writes* (effects on own slice) or keep #56
   scoped to reads (matching what it retires)? Recommendation: reads first;
   writes as a separate follow-up to avoid scope creep.
3. **Migration scope.** Introduce the primitive + migrate all 3 consumers +
   delete `reads_siblings`/`reads_sibling_slices` + the avoidance, in one pass?
   Or land the primitive, migrate incrementally, retire the mechanism last?
4. **Sequencing vs 基座化.** `matches?` + `Kind.Runtime` are `core`; two of the
   three consumers are in just-renamed session/external_mirror/identity domains.
   9b is merged; only 9c (allowlist-shrink, mechanical) remains. So #56 can start
   on `core` after 9c with low churn. Confirm timing.

## 6. Completion invariant

The test that proves #56 actually closed the gap (per
`feedback_completion_requires_invariant_test`): **a Kind's in-process self/sibling
read is DENIED when the required cap is absent** — something `reads_siblings`
cannot express today (its reads are un-gated). The test fails on the current
static-declaration mechanism and passes only when the read is genuinely
cap-checked in-process.

## 7. Cross-references

- `Ezagent.Capability.Match.matches?/2` — the pure gate to reuse.
- `Ezagent.Kind.Runtime` (`runtime.ex:392-398`) — the self-call deadlock that forces the workarounds.
- `Ezagent.Behavior` / `Ezagent.Lifecycle` — `reads_siblings/0` declaration + surfacing.
- The 3 live `reads_siblings` consumers (§2).
- Origin: #53 orchestrator "D vs C" design (Allen 2026-06-13) — part (a) of option D.
