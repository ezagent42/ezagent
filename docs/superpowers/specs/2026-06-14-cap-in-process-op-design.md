# Cap-checked in-process op primitive — design (task #56)

> **Design spec.** Builds on
> [`2026-06-14-cap-in-process-op-analysis.md`](./2026-06-14-cap-in-process-op-analysis.md).
> Recommended answers provisionally approved by Allen 2026-06-14 ("写完 spec + codex
> review 后再决策") — so this spec goes to **codex adversarial-review**, then Allen
> decides before implementation. Implementation sequenced **after 基座化 PR-9c**.
> Touches the CapBAC chokepoint → "never weaken authz" governs every choice.
>
> Bilingual mirror: `2026-06-14-cap-in-process-op-design.zh_cn.md` (to follow this commit).

## 1. Goal

Replace the **un-cap-checked** in-process self/sibling-slice read mechanism
(`reads_siblings` / `reads_sibling_slices` + `get_slice(self)`-avoidance) with a
**cap-checked** in-process read that reuses the existing CapBAC gate — closing
the authz gap without reintroducing the self-call deadlock.

## 2. The primitive

### 2.1 `Ezagent.Capability.authorize_in_process/2` (pure)

```elixir
@spec authorize_in_process(MapSet.t(Capability.t()), needed :: map()) ::
        :ok | {:error, :unauthorized}
def authorize_in_process(caps, needed) do
  if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)),
    do: :ok, else: {:error, :unauthorized}
end
```

- **Pure function** — no process call, so no deadlock. It is the SAME
  `Capability.matches?` decision used by `Kind.Runtime` step 5.5, with the SAME
  `needed` shape `%{kind, behavior, action, instance, workspace_uri}`. It removes
  the *transport* (the cross-process `GenServer.call`), never the *check*.
- This is the whole authz surface. Everything else is plumbing that calls it.

### 2.2 The cap-gated in-process slice accessor (runtime plumbing)

A handler runs *inside* its Kind's GenServer, so the Kind's full slice map is
already in-process — the data never needed a `GenServer.call` to self; only the
*authorization* did, and that is now `authorize_in_process/2`. `Kind.Runtime`
gives handlers a gated accessor in `ctx`:

```elixir
# inside a handler:
case ctx.read_slice.(:sandbox) do
  {:ok, sandbox} -> ...        # authorized + read from in-memory state
  {:error, :unauthorized} -> ...   # cap absent — fail closed
end
```

`ctx.read_slice.(key)` internally: builds `needed` for "read slice `key`"
(§2.3), calls `authorize_in_process(ctx.caps, needed)`, and on `:ok` returns the
slice value straight from the Kind's own state. No declaration, no surfacing of
un-asked slices, no deadlock.

### 2.3 The cap shape for an in-process slice read (the key design point)

`needed` for "Kind reads its own slice `key`":

```elixir
%{kind: self_kind, behavior: owning_behavior_of(key), action: :read,
  instance: self_uri, workspace_uri: self_workspace_uri}
```

`owning_behavior_of(key)` is the Behavior whose `state_slice` is `key` (already
resolvable via `Kind.BehaviorSet`). So a Kind that reads its `:sandbox` slice
must hold a cap matching `{kind, <sandbox-owning behavior>, :read, self, ws}`.

**Implication (codex, scrutinize this):** this makes in-process reads a *granted*
capability where today they are free-by-declaration. Kinds that legitimately
self-read (the 3 consumers) must be **granted the corresponding self-read cap at
creation** — a deliberate strengthening (the read is now authorized, auditable,
revocable), but a real migration cost. The grant happens at the same
create-time cap-minting the Kind already does; no runtime cap-fabrication.

## 3. Migration (one pass — Allen-approved recommendation)

1. Add `authorize_in_process/2` + the `ctx.read_slice` accessor + `:read` cap
   minting for the self-read caps.
2. Convert the 3 live consumers off `reads_siblings`:
   - `behavior/agent/receive.ex` `reads_siblings([:sandbox])`
   - `behavior/external_mirror.ex` `reads_siblings([:publisher])`
   - `behavior/config_evolve.ex` `reads_siblings([:sandbox, :identity])`
   Each becomes `ctx.read_slice.(key)` + a granted self-read cap.
3. Delete `reads_siblings/0` + `reads_sibling_slices/0` (macro, callback,
   introspection union in `behavior/introspection.ex`, the runtime surfacing) +
   the `get_slice(self)`-avoidance.
4. `mix ezagent.check_invariants` / `arch.scan` updated for the removed mechanism.

## 4. Scope guard

- **Reads only.** Cap-gated in-process *writes* (effects on own slice) are a
  separate follow-up — NOT in #56 (matches what `reads_siblings` retires).
- **No deadlock machinery.** Explicitly excludes option-D's runtime-fighting
  parts (per the #56 task note). #56 is *only* the pure-gate + accessor + migration.

## 5. Completion invariant (the gate)

A test proving the read is genuinely cap-checked (per
`feedback_completion_requires_invariant_test`): **a Kind whose self-read cap is
absent gets `{:error, :unauthorized}` from `ctx.read_slice.(key)`** — and a
positive control where the cap present returns `{:ok, slice}`. This fails on the
old `reads_siblings` mechanism (its reads are unconditional) and passes only when
the read is authorized. Plus a regression test that the 3 migrated consumers
still function with their granted caps.

## 6. Sequencing

- Now: this spec → **codex adversarial-review** → Allen decision.
- Implementation: after 基座化 PR-9c. `matches?`/`Kind.Runtime` are `core`; 2 of
  3 consumers are in the just-renamed session/external_mirror/identity domains, so
  starting post-9c keeps churn low.

## 7. Open question surfaced for codex/Allen

- Is `:read` the right action atom, or should each slice declare its own
  read-action (finer-grained)? `:read` is the simplest; a per-slice read-action
  is more precise but more cap rows. Recommendation: start with `:read`.

## 8. Cross-references

- Analysis: `2026-06-14-cap-in-process-op-analysis.md`.
- `Ezagent.Capability` / `Ezagent.Capability.Match` — the gate reused.
- `Ezagent.Kind.BehaviorSet` — `owning_behavior_of(slice_key)` resolution.
- `Ezagent.Behavior` / `Ezagent.Lifecycle` — `reads_siblings` to remove.
