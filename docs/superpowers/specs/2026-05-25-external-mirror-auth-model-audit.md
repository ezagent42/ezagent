# ExternalMirror Facade Auth-Model Audit — formalizing the 4-gate enforcement, trust transfer, atomicity, and the collective invariant

**Status:** r1. 2026-05-25.
**Tier:** documentation amendment to `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` + small primitive lift to `apps/ezagent_core/` + invariant test in `apps/ezagent_domain_external_mirror/`.
**Trigger:** Allen 2026-05-25 — observed pattern of PR #317 (PR-EM-3) hitting 5 rounds of `/codex:adversarial-review`, 12 cumulative HIGH/CRIT findings, all clustered in `Behavior.ExternalMirror` facade vs action-body split. Allen 2026-05-25 (Feishu): "未来 codex 多轮 review 失败的 pattern 我们要 generalize 成 SPEC + invariant test，不能靠 point fix".
**Predecessors (all merged on `main`):**
- `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` (the parent SPEC; §4.2 is the under-specified area this audit addresses).
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` (PRs #306-#310; the cap shape Check 1 verifies).
- PR-EM-3 / PR #317 — the 5-round codex iteration that produced this audit. Each merged commit (a9d40af, 89904b9, 931a0203, 4a1637d8, 017f5ff2, e3ca119f, 4cc0e237) carries the round's finding + fix rationale.
- PR-EM-FINAL is **not** a prerequisite; this audit can land before or after.
- `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05): no `:warning`+degrade, no defaults, no whitelists, no shims. Audit verdicts MUST follow this rule.
- `feedback_completion_requires_invariant_test` (Allen 2026-05-05): a multi-PR phase is "done" only when an architectural invariant test exists that would fail if the goal were unmet. The §6 invariant test IS the gate for this audit.
- `feedback_north_star_plugin_isolation` (Allen 2026-05-05): tiebreaker for ambiguous design choices is "keeps plugin authors out of core".
- SKILL P3 (single source of truth) + P14 (dispatch is the only path between Kinds) + P22 (reliability primitives in core; plugin authors cannot bypass) + P23 (declare-don't-call plugin contract).
**Companion:** `2026-05-25-external-mirror-auth-model-audit.zh_cn.md` (Chinese mirror).

---

## 1. Context — why this audit exists (the meta-finding)

PR #317 implemented the `Ezagent.ExternalMirror.bind/4` facade + `Behavior.ExternalMirror.invoke(:bind, ...)` action body per parent-SPEC §4.2 / §8.2 r6. It hit **5 rounds** of `/codex:adversarial-review`. Each round surfaced 2–3 NEW HIGH/CRIT findings, **all clustered in the same surface**: facade vs action-body split, enforcement ordering, atomicity, failure modes. Cumulative: **12 findings** across r1–r5.

### 1.1 Round-by-round summary (copied from PR #317 commit bodies, exact)

| Round | Verdict | Findings | What was structurally implicit |
|-------|---------|----------|--------------------------------|
| r1 | needs-attention | 1 CRIT (projection row keyed by `<adapter>/<target>`, collides across sessions) + 1 HIGH (`String.to_atom` on JSON-decoded opts keys) | "row key is session-scoped" — parent SPEC §7.1 wrote "natural key `(session_uri, adapter_id, target_id)`" but didn't pin the PK derivation; the implementer used the human-readable in-memory binding_id verbatim. |
| r2 | no-ship | 3 HIGH — HIGH-1 boot-ordering (BootReconciler skipped persisted bindings because adapters register later) + HIGH-2 read-side cap bypass (`list_bindings/1` + `sessions_for_adapter/1` skipped CapBAC) + HIGH-3 boot-ordering (per-adapter cap subjects never registered) | "the moment an adapter is observable, X must also be true" — there was no spec'd event-driven install hook; one-shot polls at app boot ran before plugins booted. |
| r3 | needs-attention | 1 CRIT (`_facade_checks_ok` flag forgeable by direct dispatcher) + 2 HIGH (`sessions_for_adapter/2` workspace-only filter still leaks; `BindingRow.insert` raised on unique conflict instead of returning changeset) | "trust transfer from facade to action body" — parent SPEC §8.2 said "facade injects `args[:_facade_checks_ok] = true`" without acknowledging args is caller-controlled. |
| r4 | needs-attention | 2 HIGH (BootReconciler retry loop missing; `spawn_worker_idempotently` returned `:ok` on retry-exhausted dead worker — `:warning`+degrade anti-pattern) + 1 MED (Check 1 ran AFTER Check 3 in the facade, so a caller missing the session bind cap could trigger adapter target-enumeration I/O) | "enforcement ordering" — parent SPEC §4.2 listed the gates but didn't pin order or rationalize it. |
| r5 | needs-attention | 2 HIGH on **pre-existing** code — HIGH-A (AdapterInstall ordering vs BindingRegistry atomicity; install fired before both registries populated for the same `adapter_id`) + HIGH-B (`do_bind` spawned worker FIRST then persisted; spawn-success + persist-failure produced orphan worker; blanket `{:error, changeset} → :ok` mapping silently lost real DB failures) | "atomicity contract for bind" — parent SPEC §8.2 said "persist + spawn" without pinning order, error classification, or compensation. |

### 1.2 The meta-finding

Five rounds, twelve findings, **one architectural surface**. Each fix was correct individually but the parent-SPEC §4.2 was under-specified along five orthogonal dimensions:

1. **Enforcement ordering** — which gates run before which, why, what fails for cheap-and-noisy callers vs costly-and-quiet ones.
2. **Trust transfer** — how the facade communicates "I validated this" to the action body in an unforgeable way.
3. **Atomicity contract** — persist-first vs spawn-first; idempotency vs real failure; compensation on partial.
4. **Boot-ordering invariants** — when "the moment adapter X is observable, Y must also be true" applies and how to enforce it without polling.
5. **Defense in depth** — which gates also run at dispatch §5.5 / §5.6, and what the facade's pre-checks save (I/O, latency, target enumeration).

This audit closes all five dimensions in one spec + one invariant test, so a future round of codex against any change in this surface lands on a r1-level structural assertion, not r1-only point findings.

### 1.3 Exemplar findings (the two that capture the pattern)

**r3 CRIT — `_facade_checks_ok` forgery (trust transfer):**
> `args[:_facade_checks_ok] = true` set by the facade after Checks 2+3 passed. The action body trusted that boolean — but `args` is caller-controlled at `Invocation.dispatch/1` time, so any in-VM caller holding the session `:bind` cap could dispatch directly with the flag set and skip BOTH Check 2 and Check 3. **Real authorization bypass.** The fix: replace the flag with a 32-byte `:crypto.strong_rand_bytes` nonce stored in a `:protected`-ETS table whose only writer is the FacadeNonceTable GenServer. Forgery requires guessing 256 bits of RNG OR writing to a table the caller doesn't own.

**r5 HIGH-B — spawn-before-persist split-brain (atomicity):**
> `:bind` action body spawned the worker FIRST, then `persist_binding_row/2`. If `Repo.insert/1` raised, the worker was alive but no row + no slice mutation. ALSO: `persist_binding_row` mapped ANY `{:error, changeset}` to `:ok` blanket (the comment said "for unique-constraint idempotency"), so NOT NULL / FK / validation errors silently became "success" with no row created and a live worker that no future rehydration could see. The fix: persist FIRST with discriminated returns (`{:ok, :persisted}` / `{:ok, :idempotent_unique_conflict}` / `{:error, {:db_insert_failed, _}}`), spawn AFTER, compensating delete if spawn fails post-persist.

These two findings together make the case: the parent SPEC's "facade runs Checks 2+3 then dispatches" + "the action body persists + spawns" was correct at the abstract level but every concrete detail was under-specified. This audit pins every concrete detail.

---

## 2. The four enforcement gates (canonical order)

### 2.1 The table

| # | Gate | Where enforced | Cost | Failure shape | Findings that surfaced gaps |
|---|------|----------------|------|---------------|------------------------------|
| **0** | **Adapter lookup** — `adapter_id` resolves in `AdapterRegistry` | Facade (`lookup_adapter/1`) AFTER Gate 1 (per codex r1 audit-SPEC HIGH-2) | O(1) ETS lookup | `{:error, :unknown_adapter}` | codex r1 audit-SPEC HIGH-2 — pre-fix this ran BEFORE Gate 1 → no-cap caller could enumerate adapter IDs by probing |
| 1 | **Cap 1** — caller holds `{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: <session>, workspace_uri: <ws>}` | Facade INLINE (`check_session_bind_cap/2`) + Dispatch §5.5 (defense in depth) | O(caps) MapSet scan; sub-µs | `{:error, :unauthorized}` | r4 MED — was post-Check-3 → caller w/o session cap triggered adapter I/O |
| 2 | **Cap 2** — caller holds `{kind: :session, behavior: <adapter.cap_subject.behavior_module>, instance: <session>, workspace_uri: <ws>}` | Facade Check 2 (`check_adapter_allow_cap/3`) + Dispatch §5.5 (auto-derived because adapter's per-session allow cap registers as a Behavior on Session at AdapterInstall time) | O(caps) MapSet scan; sub-µs | `{:error, :adapter_not_authorized}` | r2 HIGH-3 — was never registered because Application.start ran before plugin boot |
| 3 | **Workspace iso pre-check** — caller's workspace == session's workspace | Facade `check_workspace_iso/2` (NEW per this audit) + Dispatch §5.6 (defense in depth) | O(1) URI compare | `{:error, :cross_workspace_denied}` | NEW (Q4 — facade pre-check avoids wasting Check 4's adapter I/O on a cross-workspace target) |
| 4 | **`target_ownership_check`** — adapter-side I/O verifies the caller owns `target_id` on the adapter's external surface | Facade Task w/ 5s timeout (`run_target_ownership_check/3`) | bounded 5s adapter I/O | `{:error, {:target_ownership_denied, reason}}` / `{:error, :target_check_timeout}` / `{:error, {:target_check_crashed, reason}}` | r4 MED ordering (must come last); r4 HIGH-1 originally part of dispatch (deadlock) |

**Canonical sequence in code (per `Ezagent.ExternalMirror.bind/5`):**

```elixir
with :ok <- check_session_bind_cap(ctx, session_uri),         # Gate 1 — no adapter info
     {:ok, adapter_module} <- lookup_adapter(adapter_id),     # Gate 0 — only after caller proves general access
     :ok <- check_adapter_allow_cap(ctx, session_uri, adapter_module),  # Gate 2
     :ok <- check_workspace_iso(ctx, session_uri),            # Gate 3
     :ok <- run_target_ownership_check(adapter_module, ctx.caller, target_id) do  # Gate 4
  claim_nonce_and_dispatch(...)
end
```

Gate 1 BEFORE Gate 0 closes the adapter-enumeration leak: a caller without the session bind cap sees `{:error, :unauthorized}` for ANY adapter_id (real, fake, or probed) — they cannot distinguish "adapter doesn't exist" from "I'm not authorized for ExternalMirror on this session". An attacker probing adapter IDs gets one error shape regardless of input.

### 2.2 Why this exact order

Each gate's position is load-bearing:

- **Gate 1 first** because it's the cheapest (MapSet membership against caller's caps) AND the most general — a caller missing the session bind cap has no business being in the facade at all. Failing fast here saves every downstream gate.
- **Gate 2 second** because the per-adapter cap is also cheap (same MapSet shape) AND it's the LEAST general (specific to one adapter). If the caller has gate 1 but not gate 2, they're authorized for ExternalMirror in general but not for this adapter — a real authorization distinction that should surface BEFORE we ask "does this adapter agree?".
- **Gate 3 third** because workspace isolation is structural (caller's workspace is in their identity URI; session's workspace is in the session URI) and resolves in O(1) without I/O. Catching cross-workspace HERE saves the network round-trip in Gate 4 to an adapter that would never legitimately serve a cross-workspace target.
- **Gate 4 last** because it's the only gate that does I/O (network call to Lark / Slack / etc., bounded 5s). It's also the only gate whose result depends on the ADAPTER's view of the world rather than the BEAM's — if gates 1+2+3 already say "no", we should never ask the adapter.

**The leak vector each ordering closes:** swapping any two gates introduces information leak. Specifically:

- 4-before-3 leaks "this target exists in the adapter" to cross-workspace callers (the symptom r4 MED almost re-introduced).
- 4-before-2 leaks "this target exists" to callers without the adapter cap (target enumeration via valid session cap but no adapter cap).
- 4-before-1 leaks "this target exists" to anyone with NO ExternalMirror caps at all (the worst — the bug r4 MED actually fixed).
- 3-before-2 is harmless info-wise but spends a tiny bit more CPU per denied call (negligible).
- 3-before-1 is harmless info-wise (workspace mismatch with no caps is the same denial whichever side fires).

**The canonical order (1, 2, 3, 4) is the minimum-cost ordering that preserves least-privilege information disclosure.** This audit pins it so future changes to `Ezagent.ExternalMirror.bind/4` cannot reorder gates without explicit SPEC amendment.

### 2.3 Defense in depth

Gates 1, 2, and 3 ALSO run inside `Ezagent.Invocation.dispatch/1` (steps 5.5 / 5.6). The facade's inline pre-check is **not** the only enforcement — it's the optimization that avoids reaching dispatch for denied calls. The invariant from `feedback_let_it_crash_no_workarounds` applies: a caller that somehow bypasses the facade and hits `Invocation.dispatch/1` directly with `?action=external_mirror.bind` STILL fails gates 1/2/3 at dispatch §5.5 / §5.6, AND ALSO fails gate 4 at the action body because the FacadeNonceTable consume returns `:error` (no claim was made). All four gates are enforced; the facade is the canonical entry point that runs them in the cheapest order.

Gate 4 has **no dispatch-side defense in depth** — there's no equivalent of "re-run target_ownership_check from inside the action body" because the action body explicitly MUST NOT do I/O (per parent-SPEC §8.2 r6 — Session GenServer is bounded by slice mutation + cheap Kind.spawn). Instead, gate 4 is structurally tied to gate "5" — the FacadeNonceTable. **Trust transfer** (§3) substitutes for re-running gate 4 in the action body.

---

## 3. Facade vs action-body boundary + trust transfer

### 3.1 The boundary contract

| Concern | Facade (`Ezagent.ExternalMirror`) | Action body (`Behavior.ExternalMirror.invoke/4`) |
|---------|-----------------------------------|--------------------------------------------------|
| Adapter I/O | YES (gate 4 only; bounded 5s Task) | NO (would block Session GenServer) |
| Caller-context reads (caps, workspace) | YES (gates 1, 2, 3) | YES via dispatch step 5.5 (defense in depth) |
| DB writes | YES (Worker reconciliation during AdapterInstall) | YES (`insert_binding_row` — persist-first per §4) |
| Slice mutation | NO (Kind owns slice) | YES (the ONLY place slice changes) |
| `Kind.spawn` for Workers | NO (the facade doesn't spawn during normal bind path — that's the action body's job; AdapterInstall is the exception, handled separately in §5) | YES (`do_spawn_after_persist`) |
| `Invocation.dispatch` to other Kinds | NO (would re-enter caller process's authorization domain) | NO (parent-SPEC §8.2 forbids — adapter callbacks also forbidden) |

The split has one structural reason: **the facade runs in the caller's process; the action body runs in the Session GenServer.** Anything I/O-bound MUST be on the caller side or the Session is blocked for every other action on it (chat sends, subscribe calls, other binds). Anything mutating slice MUST be on the Session side or two callers race to overwrite each other.

### 3.2 The trust transfer problem

Once the facade has run gates 1–4, it dispatches `:bind` on the Session Kind. The action body needs to know: **"gates 1–4 already passed for THIS exact (session, adapter, target, caller) tuple."**

The naive solution (PR #317 r2 shape) was `args[:_facade_checks_ok] = true`. **This is the r3 CRIT — a real auth bypass.** `args` is caller-controlled at `Invocation.dispatch/1` time; any in-VM caller holding the session :bind cap (gate 1) could dispatch directly with the flag set and skip gates 2+3+4. Their dispatch passes step 5.5 (gate 1), they SKIP the facade entirely, the action body trusts the forged flag, and they bind to a target they don't own on an adapter they don't have a per-adapter cap for.

### 3.3 The FacadeNonceTable pattern — formalized

The fix shipped in PR #317 (commit `4a1637d8`) introduces `Ezagent.ExternalMirror.FacadeNonceTable`. This audit formalizes it as **the** trust-transfer primitive between facade and action body — AND closes the codex r1 audit-SPEC CRIT-1 forgery vector that the pre-audit shape had open.

**The corrected trust-transfer model (codex r1 audit-SPEC CRIT-1 fix):**

The pre-audit shape exposed `FacadeNonceTable.claim_nonce/4` as a freely-callable public function. **That itself was a bypass** — any in-VM caller holding only the session bind cap could call `claim_nonce` directly to mint a nonce for any `(session, adapter, target, caller)` tuple, then direct-dispatch `external_mirror.bind` with that nonce, skipping gates 2 and 4.

**The structural fix:** `claim_nonce/5` is no longer a "freely callable nonce minter". It is **THE gate-enforcing operation**. Its contract:

```elixir
@spec claim_nonce(
        URI.t(),                # session_uri
        Ezagent.ExternalMirror.caller_ctx(),  # caller ctx (caps + caller_uri)
        adapter_module :: module(),
        target_id :: term()
      ) :: {:ok, binary()} | {:error, term()}
```

`claim_nonce` internally re-runs Gates 1, 2, 3, AND 4 for the supplied `(session, caller_ctx, adapter, target)` tuple. If any gate fails, it returns the gate's error shape (`:unauthorized` / `:adapter_not_authorized` / `:cross_workspace_denied` / `{:target_ownership_denied, _}` / `:target_check_timeout` / etc.). If ALL gates pass, it claims and returns the nonce.

**The facade `Ezagent.ExternalMirror.bind/5` becomes a thin wrapper** that calls `claim_nonce` (which enforces all gates) then dispatches with the nonce. An in-VM caller calling `claim_nonce` directly **must satisfy the same gates** — they get a nonce only if they would have gotten one via the facade. The forgery vector closes structurally because there is no path to a valid nonce that doesn't pass the gates.

The action body's `consume_nonce/2` is then ONLY about single-use semantics + replay protection — NOT a sole authorization gate. Gates have already run by definition (a nonce in the table means gates passed).

**Properties (the corrected contract):**

1. **`:private, :named_table` ETS, GenServer-owned.** Per codex r1 audit-SPEC CRIT-1 second sub-finding: `:protected` was world-readable, letting another in-VM process enumerate live nonces and either steal them for direct dispatch OR consume-delete them to DoS the legitimate facade caller. `:private` semantics: only the owner pid (the FacadeNonceTable GenServer) can read OR write the table. All reads go through `GenServer.call` (which already happens — `consume_nonce` is a `handle_call`). External enumeration becomes structurally impossible.

2. **`claim_nonce/4` enforces all 4 gates internally.** See structural fix above. Public API; safe because the enforcement runs inside.

3. **32-byte nonce from `:crypto.strong_rand_bytes/1`.** 256 bits of entropy. Guessing in a single-bind window (~20ms typical, 5s upper bound) is infeasible. (Forgery via guess remains theoretically open but computationally infeasible; the CRIT-1 fix closes the realistic vector.)

4. **SPEC-pinned 5-second TTL.** NOT configurable per-deployment (per `feedback_let_it_crash_no_workarounds`). The 5s ceiling is 250× the p99 dispatch latency (~20ms slice mutation + Kind.spawn). **Test-only `@doc false` 5-arity form** with explicit `ttl_ms` param permitted so the nonce-expiry invariant test runs in milliseconds; production callers MUST use the 4-arity form.

5. **Bound to the exact tuple `(session_uri, adapter_id, target_id, caller_uri, expires_at)`.** Consume verifies all four URI/term equalities + the expiry. ANY mismatch → `:error` (action body returns `:bind_must_go_through_facade`).

6. **Atomic consume via single GenServer call.** `consume_nonce/2` reads + verifies + deletes in one `handle_call`. Two concurrent attempts to consume the same nonce: exactly one returns `:ok`, the other returns `:error`.

7. **Periodic sweep** (30s interval) removes expired rows so the table cannot grow unbounded. Sweep uses `:ets.select_delete/2` (atomic per-row).

8. **Failure shape from `consume_nonce`:** missing / expired / tuple mismatch / replay — **all four reject with `{:error, :bind_must_go_through_facade}`** at the action body. The action body propagates verbatim. No information leak about which check tripped.

### 3.4 Forgery analysis — what an attacker can and cannot do (corrected)

| Attack | What it requires | Why it fails |
|--------|------------------|--------------|
| Call `claim_nonce` directly to mint a nonce for a target the caller doesn't own | Pass Gates 1+2+3+4 inside `claim_nonce` | `claim_nonce` enforces all 4 gates internally — no nonce returned unless gates pass |
| Steal a live nonce by reading the ETS table | Read access to a `:private` ETS table owned by a foreign pid | Impossible — `:private` denies all non-owner reads |
| Race to consume a nonce before the legitimate caller | Bypass GenServer serialization | Single GenServer call ensures exactly one `:ok` per nonce |
| Guess a valid nonce | 2^256 attempts | Computationally infeasible |
| Write a forged nonce directly to ETS | Elevation to owner pid | Impossible — `:private` denies non-owner writes |
| Replay a captured nonce | Same nonce consumed twice | First consume deletes; second returns `:error` |
| Reuse one nonce for a different `(session, adapter, target)` | Nonce bound to original tuple | Consume verifies tuple equality; mismatch returns `:error` |
| Wait past TTL then consume | `expires_at` check in consume | `now > expires_at` returns `:error`; sweep also removes |
| Direct-dispatch `external_mirror.bind` with a random nonce | Have a nonce in the table | Random nonce → no row in table → consume returns `:error` |
| Direct-dispatch with no nonce at all | `args[:_facade_nonce]` missing | Action body's `nonce_consume/2` short-circuits to `:error` |
| Direct-dispatch ignoring the facade entirely | Pass dispatch step 5.5 (Cap 1) AND consume a valid nonce from the table | Cap 1 is dispatch-side defense in depth; AND the nonce can only have been minted by a `claim_nonce` call that passed Gates 1+2+3+4 — so even the "skip facade" path is gated. Action body sees a valid nonce only if all 4 gates passed somewhere upstream. |
| Forge by intercepting facade-to-dispatch network | No network — facade is in-process | All in-BEAM, no wire format to intercept |
| BEAM memory dump → read live nonces | Root on the host running BEAM | Out of scope for app-level auth |

The threat model is **in-VM callers holding partial caps**, not host root. With the corrected `claim_nonce` (enforces gates) + `:private` ETS (no enumeration/DoS), every in-VM forgery path closes structurally. The remaining "BEAM memory dump" attack is explicitly out of scope and unchanged from the parent SPEC's implicit threat model.

### 3.5 Why not generalize to a `TrustTransfer` core primitive

Tempting to lift FacadeNonceTable to `Ezagent.TrustTransfer` in `ezagent_core`. **Rejected** for V1:

- **YAGNI** — ExternalMirror is the only domain currently needing facade↔action trust transfer. Lifting before a second consumer exists invites a wrong-shape API.
- `feedback_north_star_plugin_isolation` — keeping it in `ezagent_domain_external_mirror` keeps plugin authors out of one more core surface. If a future Domain needs the same pattern, **that** PR lifts to core with two concrete consumers shaping the API.
- The current implementation IS the spec for the future lift. Anyone copy-pasting it has the 5-finding pedigree as guidance.

**This audit does extract a thin generalization within the domain:** the data shape moves from session/adapter/target-specific to a generic opaque tuple, so that if PR-EM-FINAL or beyond needs the same pattern for a different facade/action pair within ExternalMirror, it can reuse without naming-coupling. The module stays at `Ezagent.ExternalMirror.FacadeNonceTable` (renamed `TrustTransfer` would imply a wider scope it shouldn't yet take).

---

## 4. Atomicity contracts

### 4.1 `:bind` — persist-first, spawn-after, compensating-delete

**Canonical order (PR #317 commit `4cc0e237`):**

```
do_bind:
  1. insert_binding_row(session_uri, binding)
       → {:ok, :persisted}                            -- fresh insert
       | {:ok, :idempotent_unique_conflict}           -- same-triple race winner already inserted
       | {:error, {:db_insert_failed, %Changeset{}}}  -- real DB error (NOT NULL / FK / validation)

  2. for both :persisted and :idempotent_unique_conflict cases:
     spawn_worker_idempotently(session_uri, binding)
       → :ok                                          -- {:ok, _pid} or {:already_started, _pid}
       | {:error, :worker_spawn_failed}               -- retries exhausted

  3. on :ok: update slice with new binding, return success map
     on {:error, :worker_spawn_failed} AFTER persist succeeded:
       compensating delete (BindingRow.delete_by_natural_key/3)
       propagate :worker_spawn_failed
```

### 4.2 Error classification — discriminated, not blanket

Pre-r5, `persist_binding_row/2` matched `{:error, %Ecto.Changeset{}}` and returned `:ok` blanket "for unique-constraint idempotency". This silently lost real failures (NOT NULL / FK / validation). Post-r5, `insert_binding_row/2` uses `unique_constraint_violation?/1`:

```elixir
defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
  Enum.any?(errors, fn
    {_field, {_msg, opts}} when is_list(opts) ->
      Keyword.get(opts, :constraint) == :unique
    _ -> false
  end)
end
```

This matches ONLY changesets carrying `constraint: :unique` in their error opts list. Per `BindingRow.insert/1` declarations, both the named natural-key index AND the default-name PK constraint can fire — both are idempotency cases (concurrent same-triple bind by another caller). Any OTHER changeset error is a real failure: **the contract is `{:error, {:db_insert_failed, cs}}` — propagate verbatim, do NOT swallow.** The caller (do_bind's `with`) returns this to the facade; the facade returns to the user; the slice + worker stay untouched.

### 4.3 Compensating delete — when, why, idempotency

If `spawn_worker_idempotently` returns `{:error, :worker_spawn_failed}` AFTER `insert_binding_row` returned `:persisted` or `:idempotent_unique_conflict`, the projection table has a row but no live worker. Per P3 (single source of truth) and the parent SPEC's §7.1 contract, "row in `external_mirror_bindings`" → "worker in PerBindingSupervisor". A row without a worker is a broken invariant.

**Compensation:** `BindingRow.delete_by_natural_key(session_uri, adapter_id, target_id)` removes the row. This is idempotent (delete of a missing row is a no-op).

**Edge case — concurrent winner survived:** if our `do_bind` lost the spawn race (other caller's worker is `{:already_started, _}` — we don't see this as `:worker_spawn_failed`; we see it as `:ok`), no compensation runs. Good.

**Edge case — concurrent winner ALSO failed:** if our spawn exhausted retries AND the winner's spawn also exhausted (same `KindRegistry.put_new` foreign-pid blocker affecting both), both callers run compensating delete. First delete removes the row; second is a no-op. The end state: no row, no worker, both callers see `:worker_spawn_failed`. Correct — neither got a working binding, and the projection table reflects that.

**Edge case — winner succeeded, we exhausted:** if we ran compensating delete here, we'd remove a row the winner depends on. **Cannot happen**: if the winner succeeded, its `Kind.spawn` returned `{:ok, _}`; our `spawn_worker_idempotently` then sees `{:already_started, _}` from the registry and returns `:ok`, NOT `:worker_spawn_failed`. The "winner-succeeded-AND-we-exhausted" branch is impossible because they share the registry as truth.

### 4.4 `:unbind` — slice mutation → DB delete → Worker terminate

`unbind` ordering (action body, parent SPEC §8.2):

```
do_unbind:
  1. WorkerSpawn.terminate(session_uri, adapter_id, target_id)
  2. BindingRow.delete_by_natural_key(session_uri, adapter_id, target_id)
  3. update slice (remove from bindings list)
  4. return success
```

The worker is a **derived view** of (slice + DB row). Terminating it first means no SliceChange events fire to a now-orphaned subscriber during the cleanup window. The slice mutation last means readers of the slice (`list_bindings`) see "binding present" until the moment the worker AND row are gone — a brief window where reads see a binding whose worker is dead, but that window is bounded by the action body's serialization (the next slice read after this action completes will see the cleaned state).

**Idempotency:** `unbind` on a non-existent binding returns `{:ok, %{ok: true, unbound: false}}`. Each of the three sub-operations is independently idempotent (terminate of missing worker, delete of missing row, removal from missing-from-slice).

### 4.5 AdapterInstall trigger — must wait for BOTH registries

Per the r5 HIGH-A finding and PR #317 commit `4cc0e237`'s fix:

> `AdapterRegistry.register/1` previously fired `AdapterInstall.install/1` unconditionally on fresh insert. But install/1 walks persisted binding rows and spawns Workers whose dispatch path looks up the binding module via `BindingRegistry.lookup!/1` — and `Plugin.publish_adapters!` registers the binding AFTER the adapter. So install ran while BindingRegistry was still empty for this adapter_id → spawned workers would have crashed on their first publish event.

The fix: split into `maybe_install/1` (called from `AdapterRegistry`) and `maybe_install_by_adapter_id/1` (called from `BindingRegistry`). Each checks whether the OTHER registry has an entry for this `adapter_id` before firing `install/1`. **Whichever registers SECOND triggers install — both registries are populated by then.** Symmetric so registration order doesn't matter.

This pattern generalizes to a **core primitive**: see §5.

---

## 5. `Ezagent.Plugin.publish_after_all_registered/2` — NEW core primitive

### 5.1 The pattern

The "wait until BOTH registries have entries for the same key before firing a hook" pattern is **structurally general**. ExternalMirror is the first consumer; future cross-registry dependencies (e.g. a plugin that exposes both a routing rule AND a template class for the same flow, where install requires both) will benefit from the same primitive.

This audit lifts the pattern from `Ezagent.ExternalMirror.AdapterInstall` to `Ezagent.Plugin` in `apps/ezagent_core/lib/ezagent/plugin.ex`.

### 5.2 API

```elixir
@spec publish_after_all_registered(
        registries :: [{registry_module :: module(), key :: term()}],
        hook_fn :: (-> :ok)
      ) :: :ok

# Example (the AdapterInstall consumer):
Ezagent.Plugin.publish_after_all_registered(
  [
    {Ezagent.ExternalMirror.AdapterRegistry, adapter_id},
    {Ezagent.ExternalMirror.BindingRegistry, adapter_id}
  ],
  fn -> Ezagent.ExternalMirror.AdapterInstall.install(adapter_module) end
)
```

### 5.3 Contract (corrected per codex r1 audit-SPEC HIGH-3)

1. **`registries`** — a non-empty list of `{registry_module, key}` pairs. Each `registry_module` MUST implement ONE callback the primitive consults:
   - `lookup/1 :: (key) -> {:ok, value} | :error` — synchronous check whether `key` already has an entry.

   The registry module ALSO drives the primitive forward by calling
   `Ezagent.Plugin.RegistrationHooks.notify_subscribers(__MODULE__, key)`
   from its own successful-insert path. This is NOT a callback the
   primitive requires (no `@callback` contract); it is an integration
   the registry module opts into by adding the call alongside its
   `:ets.insert_new/2`. A registry that doesn't call `notify_subscribers`
   simply never fires hooks for its insertions — `publish_after_all_registered`
   degrades to "all already-registered check at call time" semantics for
   that registry.

2. **`hook_fn`** — a zero-arity function. Behavior:
   - If all `registries` already resolve at call time → fires **synchronously inside `publish_after_all_registered`** before it returns.
   - Otherwise → the hook is registered in `RegistrationHooks` with a fresh internal hook_id. Fires when a `notify_subscribers/2` call observes that all registries now resolve.
   - **Fires exactly once per call to `publish_after_all_registered/2`**, NOT once per `(registries, hook_fn)` tuple. The primitive cannot compare anonymous functions for equality; each call registers an independent hook tracked by an opaque hook_id. **Hook authors MUST write idempotent hook bodies** so the rare second call (e.g. a domain re-running registration on hot reload) doesn't double-execute side effects.

3. **`hook_fn` exceptions are isolated.** If the user-supplied function raises, `RegistrationHooks` catches via try/rescue, logs at `:error`, and continues. A buggy hook does NOT crash the GenServer or lose other pending hooks.

4. **Hot uninstall (V2):** when a registry entry is REMOVED (e.g. `__delete__/1`), the primitive does NOT fire any "uninstall" hook. Hot uninstall is V2 scope per parent-SPEC §10.

### 5.4 Implementation — minimal, in `ezagent_core`

The actual implementation is ~80 LOC:
- A `Ezagent.Plugin.RegistrationHooks` GenServer owning a `:protected` ETS of pending hooks keyed by `[{registry_module, key}]` lists.
- Each `*Registry` module that wants to participate adds a thin `subscribe_register/2` callback that calls `RegistrationHooks.notify_subscribers(__MODULE__, key)` from its successful-insert path.
- `publish_after_all_registered/2` resolves immediately if all registries have the key; otherwise inserts a hook record and `:ets` watches for the "all-present" transition triggered by `notify_subscribers`.

### 5.5 ExternalMirror as the first consumer

PR-EM-AUDIT (the implementation PR) replaces `Ezagent.ExternalMirror.AdapterInstall.maybe_install*/1` body with one call to `Ezagent.Plugin.publish_after_all_registered/2`. The two registries (`AdapterRegistry`, `BindingRegistry`) gain a `subscribe_register/2` shim. Existing tests (PR #317 r5 added 2 — "register adapter alone → no install; then binding → install fires" and symmetric path) move to live against the new primitive — they still pass without modification because the observable contract is unchanged.

### 5.6 Why core, not domain

Strictly, ExternalMirror could keep the pattern internal. **The lift to core happens because:**

- The primitive is observably about "plugin registration completeness" — that's a `Ezagent.Plugin` concern, not a Domain concern.
- Future plugin authors who write extension code that registers across two of core's registries (e.g. RoutingRegistry + TemplateRegistry for a flow that needs both) will hit the same need. Lifting now means they reach for `Ezagent.Plugin.publish_after_all_registered/2` instead of inventing a poll loop OR a domain-internal hook.
- Per `feedback_north_star_plugin_isolation`: "tiebreaker is keeps plugin authors out of core". Plugin authors are kept out of `Ezagent.Plugin.RegistrationHooks` (it's the internal GenServer); they only see the public `publish_after_all_registered/2` API. Net: core surface increases by ONE public function in exchange for removing a class of "I registered X but install doesn't fire" plugin bugs.

---

## 6. The collective invariant test — the gate

### 6.1 Location + shape

Per `feedback_completion_requires_invariant_test`: this audit is "done" only when a single architectural-goal test exists that would fail if ANY of the 12 PR #317 findings (or a structurally similar new finding) were re-introduced.

**Location:** `apps/ezagent_domain_external_mirror/test/invariants/auth_model_invariant_test.exs`

**Shape:** ONE test file (NOT one test). 22 scenarios (numbered `0`, `1..10`, `10b`, `11..20` matching §6.2 below), each with:

- A `@moduledoc` header citing the originating PR #317 codex finding it regression-protects (e.g. `# scenario 7 — regression for PR #317 codex r3 CRIT: _facade_checks_ok forgery`).
- A focused `test` block.
- Assertions that prove BOTH (a) the failure shape is exactly the spec'd one AND (b) NO downstream work happened (no adapter I/O fired, no DB row written, no worker spawned, no slice mutation).

### 6.2 The 22 scenarios

Extended from 14 to 20 per codex r1 audit-SPEC HIGH-4: the original 14 missed regressions for 6 of the 12 PR #317 findings (r1 row collision, r1 atom DoS, r2 HIGH-2 read-side leaks, r2 HIGH-3 cap subject visibility, r3 HIGH-2 unique-conflict, r4 HIGH-1 BootReconciler retry). Scenarios 15-20 add direct regression protection.

| # | Name | Tests | Regression for |
|---|------|-------|----------------|
| 0 | Adapter enumeration denial | No-cap caller calling `bind(_, "real_adapter_id", ...)` AND `bind(_, "nonexistent_id", ...)` get the SAME `{:error, :unauthorized}` response — cannot distinguish | codex r1 audit-SPEC HIGH-2 |
| 1 | Cap 1 denial (no session :bind cap) | Returns `{:error, :unauthorized}`; mock adapter's `target_ownership_check/2` call counter == 0; no row in DB | PR #317 r4 MED |
| 2 | Cap 2 denial (has session cap, no per-adapter cap) | Returns `{:error, :adapter_not_authorized}`; mock adapter call counter == 0; no row in DB | PR #317 r2 HIGH-3 (enforcement) |
| 3 | Workspace iso denial (facade pre-check, gate 3) | Returns `{:error, :cross_workspace_denied}`; mock adapter call counter == 0; no row in DB | NEW (Q4 = B) |
| 4 | Workspace iso denial (dispatch §5.6, bypass facade) | Direct `Invocation.dispatch/1` with cross-workspace caller still returns `{:error, :cross_workspace_denied}` | Defense in depth |
| 5 | `target_ownership_check` denial | Returns `{:error, {:target_ownership_denied, :not_a_member}}`; no row in DB; no worker in registry | parent SPEC §8.2 r6 (facade-vs-action split) |
| 6 | `target_ownership_check` timeout | Mock adapter sleeps > 5s (test uses lowered timeout); returns `{:error, :target_check_timeout}`; no row; no worker | parent SPEC r4 MED |
| 7 | Nonce forgery (random nonce in args) | Direct dispatch with `args[:_facade_nonce] = <random 32 bytes>` returns `{:error, :bind_must_go_through_facade}`; no row; no worker; no slice mutation | PR #317 r3 CRIT |
| 8 | Nonce replay (consume same nonce twice) | First consume succeeds; second consume returns `:error` from FacadeNonceTable → action body returns `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 9 | Nonce expiry (sleep past TTL) | Claim nonce w/ tiny TTL via `@doc false` 5-arity form; sleep past expiry; consume returns `:error`; action body returns `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 10 | Nonce tuple mismatch (different session/adapter/target) | Claim for tuple A; consume with tuple B → `:error`; action body returns `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 10b | **Direct claim_nonce bypass** (NEW per codex r1 audit-SPEC CRIT-1) | An in-VM caller missing cap 2 calls `FacadeNonceTable.claim_nonce/4` directly with their own ctx — claim_nonce internally fails Gate 2 and returns `{:error, :adapter_not_authorized}`; no nonce returned; no row; no worker | codex r1 audit-SPEC CRIT-1 |
| 11 | DB insert NOT NULL violation | Force `BindingRow.insert/1` to fail with a non-unique changeset error; action body returns `{:error, {:db_insert_failed, _}}`; NOT idempotent success; no worker spawned | PR #317 r5 HIGH-B |
| 12 | Worker spawn failure AFTER row persisted | Pre-register foreign pid in `KindRegistry` under worker URI; bind triggers compensating delete; row removed; error `{:error, :worker_spawn_failed}` returned | PR #317 r4 HIGH-2 + r5 HIGH-B |
| 13 | AdapterInstall ordering (registries land in either order) | Register adapter alone → no workers spawned (BindingRegistry empty); register binding → install fires; workers spawn. Then symmetric: binding-first → adapter-second → install fires. | PR #317 r5 HIGH-A |
| 14 | Happy path (all gates pass) | All 4 gates pass; exactly 1 row in DB; exactly 1 worker in `KindRegistry`; slice has exactly 1 binding; nonce consumed (no leftover in FacadeNonceTable) | Sanity gate |
| **15** | **Row id collision across sessions** (NEW per codex r1 audit-SPEC HIGH-4) | Two sessions bind same `(adapter_id, target_id)` → two distinct DB rows with different `row_id` hashes; unbind from session A leaves session B's row + worker intact | PR #317 r1 CRIT |
| **16** | **Atom-DoS via opts keys** (NEW per codex r1 audit-SPEC HIGH-4) | Bind with `opts: %{"<random string key>" => "v"}`; restart Session via DynamicSupervisor.terminate_child + SpawnRegistry.spawn; rehydrated opts keys are ALL strings (any atom appearance proves regression) | PR #317 r1 HIGH |
| **17** | **Read-side `list_bindings/2` unauthorized** (NEW per codex r1 audit-SPEC HIGH-4) | A caller without `:list_bindings` cap calls `Ezagent.ExternalMirror.list_bindings/2` → returns `{:error, :unauthorized}` (dispatch §5.5 rejects); no binding tuples leaked | PR #317 r2 HIGH-2 + r3 HIGH-1 |
| **18** | **Cap subject CapabilityRegistry visibility** (NEW per codex r1 audit-SPEC HIGH-4) | After AdapterInstall fires for adapter "test_em_a", `CapabilityRegistry.list_subjects(Ezagent.Entity.Session)` includes the `(Session, allow_test_em_a, _)` entry — admins can grant per-adapter caps via the normal grant path | PR #317 r2 HIGH-3 |
| **19** | **Unique-conflict returns changeset, not raise** (NEW per codex r1 audit-SPEC HIGH-4) | Insert a `BindingRow` for `(S, A, T)`; insert a SECOND row for the SAME `(S, A, T)` triple — `BindingRow.insert/1` returns `{:error, %Ecto.Changeset{} = cs}` carrying `constraint: :unique` in the errors keyword (NOT a raised `Ecto.ConstraintError`); `do_bind`'s wrapper classifies as `{:ok, :idempotent_unique_conflict}` (per §4.2) | PR #317 r3 HIGH-2 |
| **20** | **BootReconciler retry survives missing session spawn handler** (NEW per codex r1 audit-SPEC HIGH-4) | Boot with `external_mirror_bindings` rows present BEFORE `:ezagent_domain_instance_message` registers `session://` spawn handler; BootReconciler initial pass returns `{:retry, _}` for each row; later (during test setup) chat registers its handler; reconciler's next retry pass succeeds; all rows reconciled within bounded retry budget | PR #317 r4 HIGH-1 |

### 6.3 What the test asserts beyond return values

For scenarios 1–6, 11, 12: each test MUST also assert that **no downstream observable mutation happened**. Concretely:

```elixir
# Helper used by every "denial" test
defp assert_no_downstream_work(session_uri, adapter_id, target_id, mock_adapter) do
  # 1. adapter I/O didn't fire (gates 1, 2, 3 should short-circuit before gate 4)
  assert MockAdapter.call_count(mock_adapter, :target_ownership_check) == 0

  # 2. DB row not written
  assert {:error, :not_found} =
           BindingRow.fetch_by_natural_key(session_uri, adapter_id, target_id)

  # 3. Worker not in KindRegistry
  worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)
  assert :error = KindRegistry.lookup(worker_uri)

  # 4. Slice not mutated (still has 0 bindings for this triple)
  {:ok, slice} = Ezagent.Kind.get_slice(session_uri, :external_mirror)
  refute Enum.any?(slice.bindings, &(&1.adapter_id == adapter_id and &1.target_id == target_id))
end
```

Scenarios 5+6 exempt assertion #1 (the adapter call MUST fire for gate 4 to deny). Scenarios 7–10 exempt #1 (gate 4 already passed in the facade's "claim" path; the denial is at the action body's consume). Scenario 10b exempts #1 only when Gate 2 fails inside claim_nonce (the adapter call would not have been reached yet). Scenario 11 exempts #3 (insert fails BEFORE spawn). Scenario 12 expects #2 to flip from "row present" to "row absent" mid-test as compensation runs. Scenarios 13, 18 use registry-state assertions instead of `assert_no_downstream_work` (they're about boot-ordering observability, not bind denial). Scenario 14, 15, 16, 19, 20 assert positive state (1 row, 2 rows, all-string keys, idempotent classification, retry success respectively) instead of denial state. Scenario 17 asserts a `dispatch.dispatch/1` rejection through the read facade, not a bind denial.

### 6.4 What this invariant prevents

If a future contributor:
- Reorders gates 1–4 in the facade → scenarios 1, 5 likely fail (cap denial returns wrong shape OR adapter I/O fires when it shouldn't).
- Moves `lookup_adapter` BEFORE Gate 1 → scenario 0 fails (no-cap caller can enumerate adapter IDs).
- Re-introduces a forgeable trust-transfer flag → scenario 7 fails.
- Exposes a public `claim_nonce` that doesn't enforce gates → scenario 10b fails (caller missing cap 2 obtains a nonce).
- Forgets the FacadeNonceTable expiry check → scenario 9 fails.
- Removes the persist-first ordering → scenario 11 may silently pass (depends on which path was broken) BUT scenario 12 fails (compensating delete + row state).
- Reverts AdapterInstall to fire unconditionally on AdapterRegistry insert → scenario 13 fails (workers spawn before binding registered).
- Returns `:ok` instead of `{:error, :worker_spawn_failed}` on spawn exhaustion → scenarios 12, 14 fail (state divergence).
- Breaks workspace iso facade pre-check OR dispatch §5.6 → scenarios 3 or 4 fail respectively.
- Regresses `BindingRow.row_id/3` to use the session-unscoped `binding_id` → scenario 15 fails (cross-session collision).
- Reintroduces `String.to_atom` on JSON-decoded opts keys → scenario 16 fails (atom appearance in rehydrated keys).
- Removes the read-side dispatch route for `list_bindings/2` → scenario 17 fails (unauthorized caller sees data).
- Skips AdapterInstall's cap-subject registration step → scenario 18 fails (cap subject absent from registry).
- Removes `BindingRow.insert/1`'s `unique_constraint/3` declarations → scenario 19 fails (insert raises instead of returning changeset).
- Removes BootReconciler's bounded retry loop → scenario 20 fails (rows stuck un-reconciled when handler registers late).

**The invariant test IS the gate.** Per `feedback_completion_requires_invariant_test`, "the test that would fail if the architectural goal is unmet — that's the gate". This test failing is structurally equivalent to "the audit's goal is unmet".

### 6.5 Test ergonomics — helpers, not duplication

`test/support/auth_model_test_helpers.ex` provides:

- `MockAdapter.new(target_check_response: ..., delay_ms: ..., call_counter: :start)` — instrumented mock that records every callback invocation. Replaces ad-hoc per-test mocks for cleaner reuse.
- `setup_caller(ctx :: %{caps: ..., workspace: ...})` — builds a `caller_ctx` map with caps for the requested gates.
- `bypass_facade_dispatch(session_uri, adapter_id, target_id, args_overrides)` — constructs an `Invocation.dispatch/1` call that bypasses `Ezagent.ExternalMirror.bind/4`. Used by scenarios 4, 7, 8, 9, 10.
- `assert_no_downstream_work/4` — as in §6.3.

Existing tests in `test/ezagent/behavior/external_mirror_test.exs` and `test/ezagent/external_mirror/facade_test.exs` are NOT removed — they still test individual code paths. The invariant test is the ARCHITECTURAL gate; the focused tests are unit-level. **Both layers coexist.**

---

## 7. Migration plan

### 7.1 PR scope

This audit produces **TWO PRs**:

**PR A — SPEC PR (this document):**
- Branch: `docs/external-mirror-facade-audit-spec`
- Adds: `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` + `.zh_cn.md`
- Title: `docs(spec): facade auth-model audit — 4 gates + trust transfer + atomicity + invariant test`
- Body: meta-finding summary + section headers + handoff context + the 4 Allen-settled answers (Q1=A inline, Q2=A SPEC-pinned 5s, Q3=B lift to core, Q4=B facade pre-check)
- Codex: `/codex:adversarial-review --background`. r1 only. If r1 has architectural HIGH/CRIT, escalate Allen (no audit-on-audit).
- Merge: `gh pr merge --admin --squash --delete-branch` after clean

**PR B — Implementation PR (after PR A merges):**
- Branch: `feat/external-mirror-facade-audit-impl`
- Adds:
  - `apps/ezagent_core/lib/ezagent/plugin.ex` — `publish_after_all_registered/2` (~30 LOC public API)
  - `apps/ezagent_core/lib/ezagent/plugin/registration_hooks.ex` — backing GenServer (~50 LOC)
  - `apps/ezagent_core/test/ezagent/plugin/registration_hooks_test.exs` — unit tests for the primitive (~80 LOC, ~5 scenarios)
  - `apps/ezagent_domain_external_mirror/test/invariants/auth_model_invariant_test.exs` — the **22-scenario** (0, 1..10, 10b, 11..20) architectural gate (~600 LOC)
  - `apps/ezagent_domain_external_mirror/test/support/auth_model_test_helpers.ex` — test ergonomics (~150 LOC)
- Modifies:
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex` — `maybe_install*/1` body becomes one call to `publish_after_all_registered/2`
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex` — call `RegistrationHooks.notify_subscribers/2` from successful-insert path
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_registry.ex` — call `RegistrationHooks.notify_subscribers/2` from successful-insert path
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex` — reorder gates per §2.1 (Gate 1 BEFORE Gate 0 lookup_adapter) + add `check_workspace_iso/2` gate 3 facade pre-check + thin `bind/5` body since `claim_nonce` now enforces gates
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex` — **structural rework per codex r1 audit-SPEC CRIT-1**: change ETS to `:private`; `claim_nonce/4` (public, 4-ary) takes `caller_ctx + adapter_module + target_id` and internally enforces Gates 1+2+3+4 before claiming; `@doc false` 5-ary form keeps the `ttl_ms` override for the invariant test
- Net LOC: ~+850 production+test (the existing 8 r3 nonce tests + 5 r5 atomicity tests merge into the 21-scenario invariant suite where overlap exists)
- Title: `feat(external-mirror): facade auth-model audit — primitive + invariant test`
- Codex: `/codex:adversarial-review --background`. Up to r2 if needed. r3+ escalates to Allen.
- Merge: `gh pr merge --admin --squash --delete-branch` after clean

### 7.2 What this audit does NOT change

- The 4 gates' enforcement code (already shipped in PR #317 r4/r5). Existing tests stay green.
- The FacadeNonceTable's runtime behavior (already shipped in PR #317 r3). Existing 8 nonce tests stay green.
- The action body's persist-first/spawn-after order (already shipped in PR #317 r5). Existing tests stay green.
- The AdapterInstall maybe_install pattern's externally-observable behavior (already shipped in PR #317 r5). The impl PR re-implements its body via the new primitive — same observable contract.

The audit is a **formalization + gate**, not a refactor of behavior. Behavior preservation is verified by the existing test suite (94 tests passing on `main`) PLUS the new invariant test.

### 7.3 Out of scope

- ExternalMirror PR-EM-FINAL (admin UI cleanup, CLI surface, feishu plugin rewrite). Tracked in parent SPEC §9.
- `dispatch.ex ReadyGate/PendingDelivery TOCTOU` (docs/futures/todo.md). Framework-wide concern; separate SPEC.
- Hot-uninstall semantics for adapters (parent SPEC §10 lists as V2).
- Multi-node V2 (parent SPEC §10).

---

## 8. Anti-patterns explicitly rejected

Per `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05), this SPEC does NOT contain any of:

1. **`:warning` + degrade paths.** Every gate denial returns a structured error; no "log warning and continue with reduced functionality" patterns. (r4 HIGH-2's `spawn_worker_idempotently → :ok` was exactly this anti-pattern; the fix returned `{:error, :worker_spawn_failed}`. This SPEC pins that fix as canonical.)

2. **Default values / fallback values for missing data.** No "if cap absent, default to allow". No "if workspace mismatch, default to caller's workspace". Missing data is a denial, not a fallback. (The closest thing — workspace `:any` for class-wide caps — is a STRUCTURED grant shape from caps-data-ownership v2, not a default; it means "admin wildcard granted explicitly", verified by `admin_wildcard?/1`.)

3. **Whitelists / allowlists at the auth boundary.** No "this adapter_id is exempt from gate 4". No "this caller URI bypasses cap checks". Gates are uniform across all adapters and callers; admin wildcards (where applicable) are STRUCTURED caps, not implicit allowlists.

4. **Configuration knobs that work around structural problems.** FacadeNonceTable TTL is SPEC-pinned 5s, not `config :ezagent, :facade_nonce_ttl_ms`. A deployment that needs a different TTL has a structural problem in its dispatch latency that this SPEC would address by changing the dispatch path, not by exposing a knob. Test-only override is permitted via `@doc false`.

5. **Shims / compatibility layers** for the pre-r3 `_facade_checks_ok` flag. The flag is removed; any caller that was depending on it (none in `main`) would break loudly. No back-compat is provided per parent-SPEC Allen 2026-05-24 "no migration / no back-compat" rule.

6. **`String.to_atom/1` on user input.** Caller-supplied `opts` keys stay as strings (PR #317 r1 HIGH fix); the SPEC pins this as the canonical pattern. Adapters that want atom keys use `String.to_existing_atom/1` against a fixed compile-time allowlist.

---

## 9. Open questions — none

Per the handoff document `/tmp/handoff-facade-audit.md`, Allen settled the 4 open questions 2026-05-25:

- **Q1:** Cap 1 check location → **facade INLINE** (per r4 MED state). Baked into §2.1 + §3.1.
- **Q2:** FacadeNonceTable TTL → **SPEC-pinned 5s** (NOT configurable). Baked into §3.3 + §8.4.
- **Q3:** "wait for related registries" abstraction → **Lift to core** as `Ezagent.Plugin.publish_after_all_registered/2`. Baked into §5.
- **Q4:** Workspace iso (gate 4 → renumbered to gate 3) → **Pre-check in facade** BEFORE target_ownership_check (now gate 4). Baked into §2.1 + §2.2.

No further design discussion required before implementation. Codex r1 may surface implementation-level open questions; those are addressed in PR B's iteration, not in another SPEC round.

---

## Appendix A — Cross-references

- Parent SPEC: `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §4.2 / §8.2 / §3.1 / §7.1
- Caps SPEC: `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` §3.1 (data_owner) / §5.2 (grant enforcement)
- PR #317 commits (each commit body is a primary source):
  - a9d40af — PR-EM-3 base implementation
  - 89904b9 — r1 fixes (CRIT row-id + HIGH atom DoS)
  - 931a0203 — r2 fixes (HIGH-1+3 unified AdapterInstall + HIGH-2 read CapBAC)
  - 4a1637d8 — r3 fixes (CRIT FacadeNonceTable + HIGH-1 per-session read filter + HIGH-2 unique_constraint)
  - 017f5ff2 — r4 fixes (HIGH-1 BootReconciler retry + HIGH-2 let-it-crash + MED Check 1 ordering + META audit recorded)
  - e3ca119f — r5 capture (HIGH-A AdapterInstall ordering + HIGH-B spawn-before-persist; escalated)
  - 4cc0e237 — r5 fixes (atomic persist-then-spawn + symmetric AdapterInstall ordering)
- `docs/futures/todo.md` — section "Facade-auth-model security audit" carries the same 5 r5 starting points this SPEC formalizes
- Memories: `feedback_let_it_crash_no_workarounds`, `feedback_completion_requires_invariant_test`, `feedback_north_star_plugin_isolation`, `feedback_spec_codex_adversarial_review`

---

## Appendix B — The "why we don't lift TrustTransfer too" decision matrix

| Option | Surface change | Future cost | YAGNI verdict |
|--------|----------------|-------------|---------------|
| Keep FacadeNonceTable in domain.external_mirror, same name | 0 modules moved | If next consumer arrives, that PR lifts | ✓ chosen |
| Generalize to `Ezagent.ExternalMirror.TrustTransfer` (same domain) | 1 module renamed | Next consumer reuses without lift | ✗ premature (no second consumer in sight) |
| Lift to `Ezagent.TrustTransfer` in `ezagent_core` | 1 module moved cross-tier | Next consumer reuses cross-domain | ✗ premature + violates plugin-isolation north star until 2nd consumer shapes the API |

The `publish_after_all_registered/2` primitive IS lifted to core because (a) it's structurally a Plugin concern, not an ExternalMirror concern, AND (b) the next consumer is foreseeable (any plugin with cross-registry dependencies). TrustTransfer's next consumer is NOT foreseeable in V1 — no other facade in the codebase needs a forgery-proof handoff to an action body yet. When one does, that PR's author will have FacadeNonceTable as the worked example to lift from.
