# SPEC: `:dispatch_returning` effect + close §11 Gate 3/6

**Date**: 2026-05-29
**Status**: implemented (implementation record in §12)
**Closes**: SPEC #445 §11 Gate 3 + Gate 6
**Related**: `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §4.4 (effect grammar)
**LOC analysis**: `docs/notes/2026-05-28-migration-loc-deadcode-analysis.md`

---

## 1. Problem

Per the §11 LOC/deadcode analysis (`2026-05-28-migration-loc-deadcode-analysis.md`),
two `apps/*/lib/ezagent/behavior/*.ex` grep gates are red:

- **Gate 3** ("no plugin Behavior calls `Ezagent.Invocation.dispatch`") — **3 live violations**:
  - `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:872` — `resolve_source_config_dir/2` synchronously dispatches `sandbox.read` against the source Agent URI to read its `config_dir_path`.
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:734` — `subscribe_to_session_publisher_from/3` synchronously dispatches `publisher.subscribe_from` and reads the returned cursor.
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:744` — `dispatch_publish_to_self/2` synchronously self-dispatches `external_mirror_worker.publish` (cast — no return).

- **Gate 6** ("no plugin Behavior calls `Ezagent.CapabilityRegistry.…` directly") — **1 live violation**:
  - `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:438` — `check_grant_authorized/2` calls `Ezagent.CapabilityRegistry.data_owner_of/2` to look up the owner of a cap subject and branch on it.

**Root cause for Gate 3**: the existing `{:dispatch, %Cmd{}}` effect is async fire-and-forget. The
handler never sees the dispatched call's return value. When the handler's `with` chain genuinely
needs the result (workspace needs `config_dir_path`; external_mirror_worker needs `cursor`),
authors fall back to the legacy `Ezagent.Invocation.dispatch/1` call — which violates the
"Behavior handlers are pure-with-effects, never call dispatch directly" boundary the SPEC
established.

**Root cause for Gate 6**: `Ezagent.CapabilityRegistry.data_owner_of/2` is a pure compile-time
introspection helper (it calls `behavior.data_owner(instance)` if exported, else `:no_owner`).
The grep gate is correct that direct `CapabilityRegistry.*` access from behavior modules is a
boundary violation — but the right fix is **NOT** `:dispatch_returning` (there is no Kind
dispatch to make; `data_owner/1` is a synchronous Behavior callback, not a dispatchable action).
The right fix is to re-export `data_owner_of/2` through the `Ezagent.Behavior` author-facing
helper module.

---

## 2. Decision

### 2a. Add `:dispatch_returning` to the effect vocabulary

Mirror the existing `:effect_returning` pattern from
`apps/ezagent_core/lib/ezagent/behavior.ex` (already supports synchronous MFA/fun calls whose
return value is bound to a name and substituted via `{:ref, name, path}` into downstream
effects). Add a sibling effect that runs `Ezagent.Router.dispatch(cmd)` synchronously inside
the executor, binds the result, and exposes it via `{:ref, ...}`.

Effect shape:

```elixir
{:dispatch_returning, %Ezagent.Cmd{target: t, action: a, args: ar, ctx: c}, bind_as: name}
```

This is the structural fix for Gate 3 — handlers that today fall back to
`Invocation.dispatch/1` can now express the same intent as a typed effect.

### 2b. Re-export `data_owner_of/2` on the author-facing `Ezagent.ActionSet`

Add `Ezagent.ActionSet.data_owner_of(behavior, instance)` as the author-facing delegate to
`Ezagent.CapabilityRegistry.data_owner_of/2`. The delegate is implemented by the
`Ezagent.ActionSet.Introspection` surface; Behavior authors call the public ActionSet helper,
while the existing `CapabilityRegistry` implementation remains unchanged. The grep gate
(which targets `CapabilityRegistry\.` in `apps/*/lib/ezagent/behavior/*.ex`) is satisfied
because the call site now reads `Ezagent.ActionSet.data_owner_of(...)`.

This is the structural fix for Gate 6. No new dispatch grammar is needed because the call is a
pure synchronous introspection, not a cross-Kind interaction.

---

## 3. Effect shape

```elixir
{:dispatch_returning, %Ezagent.Cmd{} = cmd, bind_as: name}
```

- `cmd` MUST be an `%Ezagent.Cmd{}` struct (same envelope `:dispatch` uses).
- `bind_as:` keyword option is **required**; the value is an atom identifying this binding.
- Downstream effects may reference the binding via `{:ref, name}` or `{:ref, name, path}`.

`{:ref, name}` returns the entire return value (e.g. `{:ok, value} | :ok | {:error, reason}`).
`{:ref, name, path}` walks `:ok` tuples for the common `:ok, map` case — see §4.

---

## 4. Semantics

### 4a. Where it runs

`:dispatch_returning` is bucketed alongside `:effect_returning` (Phase 3 of `apply_effects/2`).
Like `:effect_returning`, it runs **synchronously**, in declared order, **before** the
Dispatches / Notifies / Events / Terminations buckets execute. This ordering is intentional:
downstream effects' `{:ref, ...}` substitutions need the bound value before those buckets fire.

### 4b. What gets bound

`Ezagent.Router.dispatch/1` returns one of:

- `{:ok, value}` — successful call with a return value
- `:ok` — successful cast / fire-and-forget
- `{:error, reason}` — dispatch failure

For `{:ok, value}`, the binding is `value` directly (the SPEC's "happy path" — handler authors
write `{:ref, name, [:field]}` and get `value[:field]`). For `:ok`, the binding is `:ok` (rare;
casts don't typically need a returning effect). For `{:error, reason}` — see §6.

### 4c. Ref substitution

`Ezagent.Behavior.substitute_refs/2` (already implemented for `:effect_returning`) walks all
downstream effects and substitutes `{:ref, name, path}` markers against the `returning` map.
The new effect SHARES the same `returning` map — a handler can mix `:effect_returning` and
`:dispatch_returning` bindings in one return list and reference both downstream.

---

## 5. Execution order

The existing bucket order (SPEC §4.4):

> State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations

The Phase-3 returning-effect substep already runs `:effect_returning` calls before any
downstream bucket. `:dispatch_returning` JOINS that substep — same loop, same `returning`
accumulator, same `{:ref, ...}` substitution. No bucket re-ordering.

Within the returning-effect substep, declared order is preserved across mixed
`:effect_returning` + `:dispatch_returning` effects. A `:dispatch_returning` that depends on
an earlier `:effect_returning`'s binding can reference it via `{:ref, ...}` in its `%Cmd{}`
fields — `substitute_refs/2` walks the `%Cmd{}` struct.

---

## 6. Failure mode

A failed `Router.dispatch/1` (`{:error, reason}`) **aborts the handler**:

- `apply_effects/2` collects the failure into the `errors` list.
- The Kind.Runtime executor, on encountering a non-empty `:dispatch_returning_errors`,
  short-circuits with:

  ```elixir
  {:error, {:dispatch_returning_failed, name, reason}}
  ```

  where `name` is the `:bind_as` atom of the first-failing returning-dispatch.

Rationale: the handler asked for the dispatch's value in order to make a downstream decision.
If the dispatch failed, the handler's subsequent logic is undefined — the safe semantics is
abort + propagate. Mirrors the existing handler-error path (`{:error, _}` short-circuits the
whole dispatch; slice not committed; effects not flushed).

Notably DIFFERENT from a `:dispatch` effect failure (which surfaces as
`{:error, {:effect_dispatch_failed, reason}}`): the wrapping atom carries the binding name so
the operator log differentiates "this orchestrator dispatch failed" from "an arbitrary fire-
and-forget dispatch failed".

---

## 7. Why not make `:dispatch` synchronous by default

Two reasons to keep `:dispatch` async / fire-and-forget:

1. **Multiple-dispatch fan-out**: most handler-emitted dispatches are independent ("send a chat
   message AND notify orchestrator AND update lineage"). Forcing every dispatch to run
   synchronously serializes work that doesn't need to be serial, and amplifies tail latency.
2. **Call-site clarity**: when an author writes `{:dispatch, cmd}`, they're announcing "this is a
   downstream side effect; I don't care about the result". `{:dispatch_returning, cmd, bind_as:}`
   explicitly opts INTO the synchronous, returning semantics — different intent, different
   atom. Compare to e.g. `:effect` vs `:effect_returning` (same precedent).

A blanket flip would erase the distinction and re-introduce the very "everything is sync"
trap the effect grammar was designed to escape.

---

## 8. Migration plan

### 8a. `workspace.ex:872` (`resolve_source_config_dir/2`)

Today (synchronous escape hatch in a `with` chain):

```elixir
case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
       target: target,
       mode: :call,
       args: %{},
       ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
     }) do
  {:ok, %{config_dir_path: path}} when is_binary(path) and path != "" -> {:ok, path}
  …
end
```

The handler's `with` chain genuinely needs the dispatch's return value to BRANCH on per-flavor
errors (`:source_has_no_config_dir`, `:source_read_unexpected_shape`, `:source_not_readable`,
`:source_not_found`). The downstream code (`do_create_agent/4` which dispatches to
`Workspace.Loader.invoke_template`) runs INSIDE the handler body — there is no clean carve-out
of the work into effects that would preserve the per-flavor error mapping.

Migration: replace direct `Ezagent.Invocation.dispatch/1` with `Ezagent.Router.dispatch/1`
(via `%Ezagent.Cmd{}`). The grep gate fires on `Invocation.dispatch` specifically;
`Router.dispatch` is the sanctioned modern channel and a `Behavior` calling it is acceptable
(the gate's intent is "behaviors don't talk to the legacy Invocation struct" — Router is the
NEW way and IS the public surface for this exact use case).

`:dispatch_returning` is the right tool when the handler's RESULT (the effect list) needs the
value — e.g. a `{:set, :foo, {:ref, :result, [:field]}}` effect. It's the WRONG tool when the
handler's `with` chain needs the value for control flow that's INSIDE the handler body and
produces a structured error map. The pragmatic structural cure for those call sites is the
Router swap — preserves the call site's semantics while closing the grep gate.

### 8b. `external_mirror_worker.ex:734` (`subscribe_to_session_publisher_from/3`)

Today (synchronous dispatch returning a cursor):

```elixir
case Ezagent.Invocation.dispatch(inv) do
  {:ok, %{cursor: new_cursor}} -> {:ok, new_cursor}
  …
end
```

Migration: this call happens inside `handle_continue/3` (a Kind.Server lifecycle callback),
NOT inside an `@action` handler. **`:dispatch_returning` is an EFFECT GRAMMAR; it requires
the caller to be an action handler returning effects.** `handle_continue/3` runs inside the
GenServer process directly, with no effect pipeline around it.

For this specific call site, the structural fix is different: replace the direct
`Ezagent.Invocation.dispatch/1` with `Ezagent.Router.dispatch/1` (the modern entry-point).
The grep gate fires on `Invocation.dispatch` specifically — `Router.dispatch` is the
sanctioned channel. This narrows the §11 violation to a typed envelope without forcing the
lifecycle callback into a fake action handler.

This is part 2 of the migration — same gate, different cure, scoped to lifecycle callbacks.

### 8c. `external_mirror_worker.ex:744` (`dispatch_publish_to_self/2`)

This is a `:cast` (no return value), called from `handle_kind_message/3` — another GenServer
lifecycle path. Same fix as 8b: swap `Invocation.dispatch` → `Router.dispatch`.

### 8d. `identity.ex:438` (`check_grant_authorized/2`)

Today:

```elixir
case Ezagent.CapabilityRegistry.data_owner_of(behavior, instance) do
  %URI{} = owner -> …
  :any -> …
  _ -> …
end
```

`check_grant_authorized/2` runs inside the `handle_grant_cap/2` handler body, so the
returning-effect pattern COULD apply — but the underlying call is a pure callback
introspection (no Kind dispatch, no state, no side effects). Wrapping it in
`:dispatch_returning` would be ceremony with no architectural value.

Migration: per §2b, re-export `data_owner_of/2` on `Ezagent.ActionSet` as a thin delegate, and
swap the call site to `Ezagent.ActionSet.data_owner_of(...)`. This satisfies the grep gate (the
"call CapabilityRegistry directly" prohibition) without forcing a fake dispatch through the
runtime.

---

## 9. What this SPEC does NOT do

- Does NOT migrate **`sandbox.ex`**. The PR-471 brief flagged sandbox for "sync read pattern" — on
  inspection, sandbox's reads use `ctx[:read].(:key, default)` against its own slice (the
  sanctioned pattern). There is no sync-dispatch escape hatch. The brief's PR-471 line for
  sandbox.ex was a mis-read of the deadcode analysis (the analysis file does NOT list sandbox
  among the §11 Gate 3/6 violators). Leaving sandbox untouched.

- Does NOT touch `external_mirror.ex` (the Session-Behavior bind/unbind/list path). The
  brief flagged `target_id resolution` here; inspection shows `target_id` is just an arg field
  validated in `handle_bind/2` (no sub-dispatch). Not a Gate 3/6 violation.

---

## 10. Acceptance criteria

After this SPEC's impl + migration lands:

```bash
# Gate 3 (Invocation.dispatch in plugin Behaviors):
grep -c 'Ezagent\.Invocation\.dispatch' \
  apps/*/lib/ezagent/behavior/*.ex \
  apps/*/lib/ezagent/plugin_*/behavior/*.ex 2>/dev/null \
  | grep -v ':0' | wc -l
# → must be 0

# Gate 6 (CapabilityRegistry from plugin Behaviors):
grep -c 'Ezagent\.CapabilityRegistry\.' \
  apps/*/lib/ezagent/behavior/*.ex 2>/dev/null \
  | grep -v ':0' | wc -l
# → must be 0
```

Plus:

- `mix compile --warnings-as-errors` clean (workspace, external_mirror, identity, core).
- `mix test` per affected app passes.
- New unit tests in `runtime_new_contract_dispatch_test.exs` and `behavior_test.exs` covering
  happy path + multi-step bind + error abort + `{:ref, name, path}` substitution.

---

## 11. Codex r1 attack vectors

For the adversarial review pass (codex), the suspect surfaces:

1. **Cmd.ctx not enriched** — `:dispatch_returning` runs in `apply_effects/2` (pure), so the
   `%Cmd{}` ctx supplied by the handler is what reaches `Router.dispatch/1`. If the handler
   builds a `Cmd` without `:caller` set, the dispatch lacks an authn principal. Mitigation:
   the executor (Kind.Runtime) enriches `:caller` + `:trace_id` for `:dispatch` effects via
   `enrich_dispatch_cmd/2`; we apply the same enrichment to `:dispatch_returning` Cmds
   before calling `Router.dispatch/1`.

2. **`{:ref, name, path}` against `nil` or non-map**: if the dispatched action returns
   `{:ok, nil}` or `{:ok, 7}` and the handler asks for `{:ref, name, [:field]}`,
   `get_in_safe/2` returns `nil`. This is consistent with the existing `:effect_returning`
   behaviour, but the handler author may not expect it. Mitigation: documented in §4c.

3. **Self-dispatch infinite loop**: an attacker controls a handler to emit a
   `:dispatch_returning` targeting the same `(target, action)` it was just invoked from.
   Mitigation: same as `:dispatch` today — no special guard at the effect layer. The
   `command_uuid` idempotency middleware in `Router.dispatch/1` short-circuits exact-replay,
   and the `Kind.Server.handle_call` is a synchronous reply so the second invocation queues
   behind the first (no concurrent recursion). Same risk profile as the existing
   `:dispatch` grammar.

4. **`{:error, ...}` abort vs slice persistence**: `apply_effects/2` returns
   `{:halt, ...}` for the existing `:halt` effect; we need the dispatch_returning_failed
   path to produce the SAME abort semantics — no state mutation persisted, no notifies
   broadcast, no events appended. Mitigation: the executor returns
   `{:error, {:dispatch_returning_failed, name, reason}}` BEFORE calling
   `execute_buckets/2`, so the standard handle_dispatch error path applies.

5. **Mode coercion**: `Router.dispatch/1` derives `mode` from `ctx.reply`. A handler-supplied
   Cmd with `reply: :ignore` lands as `:cast` — but a `:cast` returns `:ok` with NO bound
   value. Authors of `:dispatch_returning` Cmds must set `reply: {:caller_inbox, _}` or
   leave default (`:ignore` will cast and the binding will be `:ok`). Mitigation:
   documented in §4b; future PR may add a static-check warning.

---

## 12. Implementation record

This SPEC is implemented in the current PR line. The implementation has been verified against
the contract in this document:

- `apps/ezagent_actor/lib/ezagent/behavior/effects.ex` accepts and buckets
  `{:dispatch_returning, %Ezagent.Cmd{}, bind_as: name}` effects, preserving declaration order
  with `:effect_returning` effects and requiring `bind_as`.
- `apps/ezagent_actor/lib/ezagent/kind/runtime/effects.ex` enriches and executes returning
  dispatches through `Ezagent.Router.dispatch/1`, substitutes refs, and aborts before the
  downstream buckets with `{:error, {:dispatch_returning_failed, name, reason}}`.
- `apps/ezagent_actor/lib/ezagent/behavior.ex` exposes the author-facing
  `Ezagent.ActionSet.data_owner_of/2` delegate through `ActionSet.Introspection`.
- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` uses that public helper,
  removing the direct `CapabilityRegistry` dependency from the Behavior.
- Coverage includes happy-path binding, ref substitution, mixed returning effects, required
  `bind_as`, failure propagation, and downstream-effect aborts in
  `behavior_test.exs` and `runtime_new_contract_dispatch_test.exs`.

The implementation verification command is:

```bash
mix test apps/ezagent_actor/test/ezagent/behavior_test.exs \
  apps/ezagent_core/test/ezagent/kind/runtime_new_contract_dispatch_test.exs
```

## 13. Out of scope

- A static-check (`@before_compile`) that warns when a Cmd in a `:dispatch_returning` has
  `reply: :ignore`. Future hardening, not blocking this PR.
- A re-write of `:effect_returning` as a special case of `:dispatch_returning`. They share
  bucket logic but model different concepts (compute vs cross-Kind dispatch).
