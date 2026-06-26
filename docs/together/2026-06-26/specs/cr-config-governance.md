# SPEC — CR (change-request) config governance (MINIMAL)

> **Design doc, NOT implementation.** A thin **EXTENSION** of the shipped
> `ConfigStore` + sandbox-materialization primitives — **not a rebuild, and
> deliberately minimal.** The hard parts (immutable objects, atomic
> object+pointer write, repoint-based rollback, soul projection, sandbox
> config_dir materialization on publish) ALL ALREADY SHIP and are REUSED. This
> SPEC adds only: **draft aggregation** (stage N objects with no pointer) +
> **publish** (flip the pointer, which fires the existing sandbox materialization)
> + **rollback** (existing repoint). Preview is a plain `render_soul/1` diff —
> **no lint, no review pipeline, no two-person rule.**
>
> Status: **rev 3 — minimal form per lead simplification (2026-06-26)** → codex
> re-review → implement. Skills loaded: `ezagent-developer`, `ezagent-socialware`.
> All code citations verified against `origin/main` (`4a7a7bed`).

---

## rev 3 — what the lead cut (and why this is now minimal)

The lead's directive: cut complexity hard — *"较为复杂的核验功能目前都不应该上"*
(no complex validation features ship now). Versus rev 2:

- **DROPPED — the two-person rule** (the old OQ-6 `published_by != opened_by`).
  Gone entirely, not even an optional flag. The cap is the agent's **manage cap**,
  the same one `apply_config_delta` uses today. Whoever may edit config may publish
  a CR. (Re-add a reviewer-separation cap later only if a real need appears.)
- **DROPPED — the lint gate + elaborate review pipeline** (rev 2 §5.1 / the
  `review` status / `request_review` transition / a separate reviewer authority).
  No structural lint, no `review` state. The lifecycle is just `open → published`
  (+ `rejected`, `rolled_back`).
- **DROPPED — any new preview/sandbox system.** The lead recalled the existing
  mechanism correctly: `Ezagent.Sandbox.ConfigDir` + config-evolve's **deferred
  `sandbox.write_path` self-dispatch** already materialize an agent's resolved
  config (soul → `CLAUDE.md`) into its config_dir on every pointer move. CR
  publish **reuses that** — it does not build a preview sandbox. "Preview" before
  publish is a plain in-memory `render_soul/1` diff (no materialization, no checks).
- **KEPT minimal-new:** draft aggregation (the CR envelope + items) and ONE
  rollback column (`published_prev_object_id`). That is the entire new surface.

What survives from rev 2's codex review (still load-bearing **correctness**, kept
because they are *bugs*, not *features* — they do not add a "complex verification
feature"):
- publish idempotency is the **CR-status gate** (`open`→`published` is one-way),
  NOT `source_turn_id` (`put_pointer/1` is a pointer-id upsert that overwrites
  `previous_config_id`, so it is not a same-turn no-op);
- rollback reads the **durable `published_prev_object_id`** column, not the live
  pointer breadcrumb (which the publish flip overwrote);
- publish validates the staged object's scope via the existing
  `fetch_matching_object/1` (the same one-line guard `repoint_config` already
  uses) — REUSE, not a new lint feature;
- the cap declares `action == dispatched action` (runtime overwrites needed-action
  with the dispatched action);
- the `cr-stage:`/`cr-publish:` `source_turn_id` prefixes are reserved + rejected
  at non-CR write entry points (so a staged object never spoofs a settled-turn
  idempotency marker).

---

## 1. What ALREADY exists (verified on origin/main — REUSED, not rebuilt)

### 1.1 Immutable object + mutable pointer (`socialware/config_store.ex`)
- **`ConfigObject`** — append-only immutable `(id, workspace_uri, subject_uri,
  key, body, created_by, source_turn_id)`. Moduledoc: *"Objects are append-only.
  Rollback and update semantics are represented by repointing `ConfigPointer`,
  never by mutating this row."* Partial unique index on `source_turn_id`.
- **`ConfigPointer`** — the mutable cascade-layer value `(id =
  layer|ws|subject|key, …, config_id, previous_config_id, pointed_by,
  source_turn_id)`; layers `workspace|user|session`.
- **`write_and_point/1`** — atomic `Multi`: insert object + advance pointer in one
  `Repo.transaction` (no orphan object).
- **`put_pointer/1`** — repoint a layer to an EXISTING object id; returns
  `previous_config_id`. Upserts on the pointer **id** (`conflict_target: :id`),
  replacing `[:config_id, :previous_config_id, :pointed_by, :source_turn_id,
  :updated_at]` on conflict. **NOT a `source_turn_id` no-op** — re-flipping
  rewrites the breadcrumb (drives §4.3/§4.5).
- **`resolve/4`**, **`fetch_object/1`**, **`fetch_matching_object/1`** (the
  workspace+subject+key scope guard), **`merge_delta/5`**, **`object_for_turn/1`**,
  **`applied_for_turn?/1`** — the reads CR consumes.

### 1.2 Agent-owned evolution (`behavior/config_evolve.ex`)
- `apply_config_delta` (durable object+pointer write, manage-cap gated,
  `source_turn_id` idempotent), `repoint_config` (rollback/advance — validates the
  target object via `fetch_matching_object/1`, then `put_pointer`).
- **CE-1 self-binding** (`assert_subject_self/2`): an agent applies config to
  ITSELF only; the handler re-binds `subject_uri`/`workspace_uri` to `self_uri`.
- **The deferred `sandbox.write_path` self-dispatch** (`sandbox_write_effects/3`):
  after a pointer move it emits `{:dispatch_after_commit, Cmd(self, :write_path,
  rtd)}` that refreshes the on-disk cascade cache. **This is the materialization
  CR publish reuses.**

### 1.3 Sandbox config_dir materialization (`core/sandbox/config_dir.ex`)
- `Ezagent.Sandbox.ConfigDir` — the single authority for the per-agent config_dir
  TARGET path (`path/2`, `allocate/2`) via the hardened `Resource.FsResolver`.
  The `sandbox.write_path` step writes the resolved soul (`CLAUDE.md`) into this
  dir. CR publish triggers this **unchanged** by emitting the same step-2 effect.

### 1.4 Projection + console facade
- `ConfigProjection.render_soul/1` — **deterministic** soul render (keys sorted;
  `soul_md` verbatim). The CR preview diff uses it.
- `Ezagent.Agent.Config` — the manage-cap-gated facade (`read_cascade/4`,
  `apply_delta/4`, `repoint/4`) world already calls; CR extends it.

> **NOT in this SPEC:** any new version-history table, immutability mechanism,
> atomic-write path, rollback mechanism, preview/sandbox system, lint engine, or
> reviewer authority. Those are §1 (reused) or explicitly cut (rev 3).

---

## 2. The gap CR closes

Today config deltas apply **one-at-a-time, immediately**. CR lets you **stage N
deltas, eyeball a plain diff, then publish them as one unit** (or reject the whole
draft before anything goes live; or roll back after).

| | Today | With CR |
|---|---|---|
| Stage many deltas before live | ✗ each apply is immediate | ✓ accumulate under one open CR |
| See the proposed soul before publish | ✗ | ✓ plain `render_soul/1` diff (no checks) |
| Publish as one unit | ✗ | ✓ flip pointer(s); fires existing sandbox materialization |
| Reject a draft wholesale | ✗ | ✓ nothing was ever pointed-to |
| Roll back a published CR | ✓ manual per-pointer repoint | ✓ same repoint, surfaced as a CR action |

---

## 3. Data model (the ONLY new state)

Two tables in **`domain.identity`** (beside `ConfigStore`). Per-tenant ⇒
`workspace_uri NOT NULL` (invariant #14).

### 3.1 `ConfigChangeRequest` (the draft envelope)
```
socialware_config_change_requests
  id                : string  (UUID, pk)
  workspace_uri     : string  NOT NULL
  subject_uri       : string  NOT NULL    # the AGENT being changed (agent-subject only, v1)
  status            : string  NOT NULL    # open | published | rejected | rolled_back
  opened_by         : string  NOT NULL    # entity URI (accountable)
  published_by      : string              # entity URI, set at publish
  published_turn_id : string              # cr-publish:<id> stamped on flipped pointers (provenance/audit only)
  title / note      : string
  inserted_at / updated_at
```
- **Status set is 4 values** (no `review` state — rev 3 cut the review pipeline).
- **One active (`open`) CR per `(workspace_uri, subject_uri)`** — partial unique
  index `WHERE status = 'open'`. Two concurrent open CRs would race the same
  pointers at publish.

### 3.2 `ConfigChangeItem` (a staged delta → references a ConfigObject)
```
socialware_config_change_items
  id                : string  (UUID, pk)
  change_request_id : string  NOT NULL  (fk)
  workspace_uri     : string  NOT NULL
  layer             : string  NOT NULL  # workspace|user|session
  key               : string  NOT NULL  # cascade key, e.g. advisor.behavior
  staged_object_id  : string  NOT NULL  # → ConfigObject.id : the immutable, ALREADY-WRITTEN proposed object (no pointer aimed at it yet)
  base_object_id    : string            # → ConfigObject.id : the object the slot pointed at when staged (diff base + drift guard)
  published_prev_object_id : string     # → ConfigObject.id : the object the slot pointed at IMMEDIATELY BEFORE publish (the durable rollback target; recorded at publish from put_pointer's returned previous_config_id — NOT read from the live pointer later, which the next flip overwrites)
  inserted_at / updated_at
```
- **Unique `(change_request_id, layer, key)`** — one staged item per slot per CR;
  re-staging the same slot replaces `staged_object_id` (points at a newer immutable
  object — never mutates one).
- **`staged_object_id` is a REAL `ConfigObject` written at stage time**, with NO
  pointer aimed at it (inert until publish). This is the key reuse: staging does
  not invent a "draft body" column — it writes a normal immutable object that no
  layer resolves to yet.

---

## 4. Lifecycle (minimal)

```
   open ──stage/unstage items──▶ open
     │                              │
     │ reject                       │ publish (manage-cap; flips pointer + fires sandbox materialization)
     ▼                              ▼
   rejected                     published ──rollback (existing repoint)──▶ rolled_back
```

### 4.1 `open_cr`
A manage-cap holder opens a CR for an agent `subject_uri`. Fails if an `open` CR
already exists for that subject (partial unique index). No config side effect.
**v1 rejects a non-agent `subject_uri`** (CE-1 self-binding requires an agent
handler; workspace-subject CRs are a follow-up).

### 4.2 `stage_item` / `unstage_item` (CR stays `open`)
**Stage = write an immutable `ConfigObject` now, record a `ConfigChangeItem`, point
NO layer.** Reuse:
- body = `ConfigStore.merge_delta/5` (patch) or an explicit `replace_body` —
  identical to `ConfigEvolve.do_apply_config_delta`'s body step.
- object write = a new thin `ConfigStore.write_object_staged/1`:
  `Multi.insert(ConfigObject.changeset(...))` **without** the pointer step (§4.2.1).
- `base_object_id` = current `resolve/4` object id for the slot (`:none` ⇒ nil).

`unstage_item` deletes the `ConfigChangeItem`; the orphan `ConfigObject` is left
append-only and unreferenced (same as a superseded object today).

#### 4.2.1 Orphan-object invariant (kept sound, no new feature)
PR-7 removed the public object-only insert because an object with no pointer would
break "object existence ⟺ applied" (used by `applied_for_turn?/1` /
`object_for_turn/1`). Staged objects ARE objects with no pointer, so:
- staged objects carry `source_turn_id = "cr-stage:<cr_id>:<item_id>"` (a CR-owned
  namespace) — **never a real settled `turn_id`** — so a turn's idempotency lookup
  is unaffected;
- `write_object_staged/1` **requires** a `cr-stage:` prefix (rejected otherwise);
- the reserved prefixes `cr-stage:`/`cr-publish:` are **rejected at every non-CR
  config-write entry** — `ConfigEvolve.apply_config_delta`/`repoint_config`
  validation AND the `Agent.Config` facade (which accepts a caller-supplied
  `turn_id`, `agent/config.ex`) — so a caller cannot pass a `cr-stage:` turn_id to
  the normal path and spoof an early-return.

This is a one-time prefix guard, not a "complex verification feature."

### 4.3 `publish_cr` (CR `open` → `published`)
Manage-cap gated (§6). Steps:
1. **Status gate FIRST** — `publish_cr` is legal only from `open`; the transition to
   `published` is the publish **idempotency mechanism** (a second publish on a
   `published` CR is rejected BEFORE any pointer write). `source_turn_id` is NOT the
   idempotency key (`put_pointer/1` overwrites on conflict).
2. Mint `published_turn_id = "cr-publish:<cr_id>"` (provenance only).
3. For each `ConfigChangeItem`, in ONE `Ecto.Multi` (§4.3.1):
   - **drift guard** — `resolve/4` must still resolve to `base_object_id` (§4.4),
     else abort the whole transaction;
   - **scope guard (REUSE)** — `ConfigStore.fetch_matching_object/1` with
     `{config_id: staged_object_id, workspace_uri, subject_uri, key}` — the same
     guard `repoint_config` already calls — so a bad/tampered CR row cannot
     cross-bind a subject/key to a foreign object;
   - **flip** — `ConfigStore.put_pointer/1` (`config_id: staged_object_id`,
     `source_turn_id: published_turn_id`); capture the returned
     `previous_config_id`.
4. Set `status → published`, `published_by`, `published_turn_id`, and write each
   item's returned `previous_config_id` into `published_prev_object_id`.
5. **Fire the EXISTING sandbox materialization** — publish is dispatched TO the
   subject agent (so it runs in the agent's own handler with
   `ctx.siblings[:sandbox]`), reusing `ConfigEvolve`'s `sandbox_write_effects/3` to
   emit the deferred `sandbox.write_path` self-dispatch that re-materializes the
   resolved soul into the config_dir via `Sandbox.ConfigDir`. **No new
   materialization.**
   > **Implementation note (codex rev-3, verified):** `sandbox_write_effects/3` is
   > `defp` and **no-ops without a `:sandbox` sibling + a `cascade_resolution`**
   > (`config_evolve.ex` ~L541-600). So `ConfigGovernance.publish_cr` MUST run as a
   > genuine agent action ctx (it declares `reads_siblings([:sandbox, :identity])`,
   > §7) — and either (a) `ConfigGovernance` lives on the agent Kind right beside
   > `ConfigEvolve` and inlines the same effect builder, or (b) the effect builder
   > is factored into a small shared/public helper both behaviors call. Recommended
   > (a) — they are siblings on the same Kind, so the private helper is in-module
   > reach; no public API widening. The pointer flip alone (`put_pointer/1`) does
   > NOT trigger materialization — the effect emission is mandatory.
6. The CR is terminal-`published`; the active-CR unique index frees up. Append-only
   objects stay (rollback needs the prior ones).

#### 4.3.1 Atomicity
A CR may stage items across multiple `(layer, key)` slots ⇒ multiple pointers.
Wrap all per-item guard+flip in **one `Repo.transaction`** (all-or-nothing). Each
`put_pointer` is a single upsert, so composing N in one `Multi` is mechanical and
lets per-item `previous_config_id` capture happen in the same transaction.

### 4.4 base-drift conflict
Before flipping a slot, assert `resolve/4` still resolves to the item's
`base_object_id`. If config moved underneath the CR since staging, abort with
`{:error, {:cr_base_drift, item}}`. Reuses `resolve/4`; no new read. (No silent
clobber.)

### 4.5 `rollback_cr` (CR `published` → `rolled_back`)
**REUSES the existing repoint — no new repoint mechanism.** For each published
item, dispatch the existing `ConfigEvolve.repoint_config` with
`config_id = published_prev_object_id` (the durable column from §4.3.4 — NOT the
live pointer's `previous_config_id`, which the publish flip overwrote).
`repoint_config` already validates the prior object (`fetch_matching_object/1`),
advances the pointer back (`put_pointer`), and emits the step-2 sandbox refresh.
CR → `rolled_back`. This is exactly the design `ConfigStore`'s moduledoc states:
*"Rollback is the same repoint operation aimed at a prior retained object."*

If `published_prev_object_id` is nil (the slot was a brand-new key at publish),
that item's rollback leaves the new pointer in place (partial rollback, logged) —
avoids adding a pointer-delete primitive (Q2).

---

## 5. Preview (plain diff — NO lint, NO checks)

The only pre-publish surface, deliberately trivial:
- **proposed** body = `ConfigStore.fetch_object(staged_object_id).body`.
- **current** body = `ConfigStore.resolve(layer, ws, subject, key).body` (or `%{}`).
- **rendered diff** = `ConfigProjection.render_soul(current)` vs
  `render_soul(proposed)` — a text diff of the projected `CLAUDE.md`, plus a raw
  map diff. `render_soul/1` is deterministic so the diff is stable.

That is the whole preview. **No structural lint, no validation gate, no `review`
status, no reviewer.** The diff is computed on demand from existing reads; nothing
is persisted or materialized.

---

## 6. Cap model

**The cap is the agent's manage cap** (lead-confirmed) — the SAME cap
`ConfigEvolve.required_caps/0` declares for `apply_config_delta`:
`cap(:agent, Ezagent.Behavior.Manage, :any)`. A held `Manage :any` cap matches any
dispatched action (the runtime overwrites the needed-cap action with the dispatched
action). **Whoever may edit config may open / stage / publish / reject / rollback a
CR.** No separate publish or reviewer cap (rev 3 cut the two-person rule).

Enforcement is the **standard dispatch step-5.5 gate**, not a facade `if`-check: CR
actions are a new `Ezagent.Behavior.ConfigGovernance` Lifecycle behavior on the
agent Kind (sibling to `ConfigEvolve`), so `required_caps/0` + the runtime gate
authorize them — mirroring how `ConfigEvolve.read_cascade` was routed through
dispatch *"so the gate is structural, not a hand-rolled facade check."*

**CE-1 self-binding inherited:** publish/rollback dispatch to the subject agent and
re-bind `subject_uri`/`workspace_uri` to `self_uri` before any `put_pointer` — a
caller managing agent A cannot publish a CR whose pointers target agent B.

---

## 7. Where it lives + reuse map

All in **`domain.identity`** (where `ConfigStore`/`ConfigEvolve` live), except
`Sandbox.ConfigDir` (core, reused):
- `Ezagent.Socialware.{ConfigChangeRequest, ConfigChangeItem}` — new schemas (§3).
- `Ezagent.Socialware.ConfigChangeStore` — new thin module: open/stage/unstage/
  transition/list/diff helpers; **delegates every config read/write to
  `ConfigStore`** (`write_object_staged/1`, `fetch_matching_object/1`,
  `put_pointer/1`, `resolve/4`, `fetch_object/1`, `merge_delta/5`). Owns only the
  CR/item rows.
- `Ezagent.Behavior.ConfigGovernance` — new `use Ezagent.Lifecycle` behavior on the
  agent Kind; actions `open_cr`, `stage_item`, `unstage_item`, `publish_cr`,
  `reject_cr`, `rollback_cr`, `preview_cr` (read). `reads_siblings([:sandbox,
  :identity])` exactly as `ConfigEvolve`. Reuses `sandbox_write_effects/3`.
- `Ezagent.Agent.Config` (existing facade) — extended with CR methods that dispatch
  the corresponding `config_governance.<action>`.
- `ConfigStore.write_object_staged/1` — the ONE new `ConfigStore` function (§4.2.1).

| Concern | Status |
|---|---|
| Immutable object / mutable pointer / atomic write / pointer flip | **REUSED** (`ConfigObject`, `ConfigPointer`, `write_and_point`, `put_pointer`) |
| Rollback execution | **REUSED** (`repoint_config`) |
| Sandbox config_dir materialization on publish | **REUSED** (`sandbox.write_path` step-2 + `Sandbox.ConfigDir`) |
| Scope guard at publish | **REUSED** (`fetch_matching_object/1`) |
| Soul render / preview diff | **REUSED** (`render_soul/1`) |
| Cascade read / facade | **REUSED / EXTENDED** (`Agent.Config`) |
| Self-binding, manage-cap gate | **REUSED** (`assert_subject_self/2`, `required_caps/0`) |
| Draft envelope + staged items | **NEW** (`ConfigChangeRequest`, `ConfigChangeItem`) |
| Durable rollback target | **NEW** (`published_prev_object_id` column) |
| Object-only staged insert (fenced) | **NEW** (`write_object_staged/1`, `cr-stage:` only) |
| Governance behavior | **NEW** (`Ezagent.Behavior.ConfigGovernance`) |
| Lint gate / review pipeline / reviewer cap / two-person rule | **CUT (rev 3)** |
| Preview/sandbox system | **CUT — reuse existing materialization** |

---

## 8. Console surface

Read-only over existing reads + the CR tables, plus one publish dispatch:
- **CR list / detail** — new `ConfigChangeStore` queries (CR rows + items); the only
  new reads, over the new tables only.
- **Preview panel** — `Agent.Config.preview/4` → `config_governance.preview_cr` →
  per item `{current_body, proposed_body, current_soul, proposed_soul}` (§5); the
  UI renders a plain text/map diff. No new data; same projection the live agent
  reads.
- **Publish / Reject / Rollback** — sibling `Agent.Config` dispatches (manage-cap
  gated).
- Existing `read_cascade` supplies the "current live config" column.

---

## 9. Test plan

1. **Stage writes an inert object** — after `stage_item`, `fetch_object` finds the
   object but `resolve/4` for the slot is unchanged (no pointer moved).
2. **Idempotency namespace fence** — a staged object's `source_turn_id` is
   `cr-stage:…`; `applied_for_turn?(real_turn_id)`/`object_for_turn(real_turn_id)`
   are unaffected (the PR-7 invariant guard).
3. **Reserved-prefix guard** — `Agent.Config.apply_delta` /
   `ConfigEvolve.apply_config_delta` with a caller-supplied `turn_id: "cr-stage:…"`
   / `"cr-publish:…"` is rejected (not silently no-op'd).
4. **Publish flips pointers atomically** — after `publish_cr`, every slot
   `resolve/4`s to its `staged_object_id`; each item records
   `published_prev_object_id`. A forced mid-publish failure leaves NO pointer moved.
5. **Publish idempotency is STATUS-gated** — re-`publish_cr` on a `published` CR is
   rejected before any `put_pointer` call; `published_prev_object_id` is unchanged
   (rollback breadcrumb not corrupted).
6. **Publish scope guard** — a CR item whose `staged_object_id` belongs to another
   subject/key is rejected via `fetch_matching_object/1`; nothing flipped.
7. **Base-drift conflict** — change live config under an open CR, then publish ⇒
   `{:error, {:cr_base_drift, _}}`; nothing flipped.
8. **Rollback = repoint prior** — publish then `rollback_cr`; every slot
   `resolve/4`s back to its `published_prev_object_id` object via `repoint_config`;
   CR `rolled_back`.
9. **Cap = manage cap** — a caller without the agent's manage cap gets
   `:unauthorized` on `open_cr`/`publish_cr`; a manage-cap holder can do all CR
   actions (no separate publish cap).
10. **CE-1 self-binding** — a CR row whose `subject_uri` ≠ dispatched-to agent is
    rejected at publish.
11. **One active CR per subject** — opening a second `open` CR for a subject fails
    the partial unique index.
12. **Reject is free** — `reject_cr` from `open` leaves `resolve/4` unchanged.
13. **Sandbox materialization on publish** — `publish_cr` emits the step-2
    `sandbox.write_path` self-dispatch (reuse, not bypass).
14. **Preview is a pure read** — `preview_cr` changes nothing; the soul diff is
    byte-identical across calls (deterministic `render_soul/1`).
15. **v1 agent-subject only** — `open_cr` with a non-agent `subject_uri` is
    rejected.

---

## 10. Optional later sub-phase — Dream auto-proposal as a CR source (OPTIONAL)

> Not in scope now. Recorded so the model doesn't foreclose it.

A "Dream" (agent self-improvement proposal) becomes **just another CR source**: it
opens a CR and stages items like a human. The manage-cap gate already covers it
(the dreamer needs only the manage cap). The only future addition would be a
`source` discriminator (`human | dream`) on `ConfigChangeRequest` for UI filtering.
No new data model.

---

## 11. Acceptance (/goal — to set after review)

- A CR aggregates N config deltas under one envelope per agent; staging writes
  inert immutable objects (no pointer moved) — tests 1+2.
- Preview is a plain deterministic `render_soul/1` diff from existing reads (no
  lint, no checks) — test 14.
- Publish flips the pointer(s) via `put_pointer` (atomic via one Multi; idempotent
  via the CR-status gate), validates scope via `fetch_matching_object/1`, records
  `published_prev_object_id`, and **fires the existing `sandbox.write_path`
  materialization** — tests 4,5,6,13.
- Rollback reuses `repoint_config` aimed at `published_prev_object_id` — **no new
  repoint mechanism** — test 8.
- Cap is the agent's manage cap; no two-person rule, no separate reviewer — test 9.
- Zero regression to the PR-7 "object existence ⟺ applied" invariant — tests 2+3.
- full `mix test` 0 failures + CI green (incl. `check_invariants`).

---

## Open questions for the lead

- **Q1** — `cr-stage:` `source_turn_id` namespace fence vs NULL `source_turn_id`
  for staged objects (§4.2.1). Recommended: the fence (keeps `ConfigObject`'s
  NOT-NULL + unique index intact).
- **Q2** — rollback of a nil-prior (brand-new-key) item: leave pointer in place,
  logged (a) vs add a pointer-delete primitive (b) (§4.5). Recommended: a (no new
  primitive).
- **Q3** — publish atomicity scope: per-CR single transaction (recommended, §4.3.1)
  — confirm acceptable that a multi-slot publish is all-or-nothing.

(Resolved by the lead in rev 3: cap = manage cap; agent-subject only; no two-person
rule; no lint/review pipeline; reuse existing sandbox materialization.)
