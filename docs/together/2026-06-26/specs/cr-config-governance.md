# SPEC — CR (change-request) config governance

> **Design doc, NOT implementation.** An **EXTENSION** of the shipped `ConfigStore`
> primitives, not a rebuild. The hard parts — immutable objects, atomic
> object+pointer writes, idempotency, repoint-based rollback, soul projection —
> **already ship and are REUSED verbatim.** This SPEC adds only the *governance
> workflow* (draft aggregation → review gate → publish ceremony → rollback) that
> sits ON TOP of them.
>
> Status: draft for codex adversarial-review → lead decision. Skills loaded:
> `ezagent-developer`, `ezagent-socialware`. All code citations verified against
> `origin/main` (`4a7a7bed`).

---

## 0. The one-sentence framing

Today a config delta is applied **one-at-a-time, immediately, by the agent to
itself** (`ConfigEvolve.apply_config_delta` → `ConfigStore.write_and_point`).
There is no way to **stage N deltas, review them together, and publish them as
one reviewed unit** — and no human-facing review gate before they go live. A
**change request (CR)** is exactly that staging+review envelope. It does **not**
introduce a new storage model for config; it *defers and batches* the existing
`write_and_point` / `put_pointer` operations and gates them behind a review +
explicit confirm.

---

## 1. What ALREADY exists (verified on origin/main — the storage half is built)

This is the load-bearing section. The SPEC's whole premise is that these are
**reused, not re-created.**

### 1.1 Immutable object + mutable pointer (`config_store.ex`)
- **`ConfigObject`** (`socialware/config_object.ex`) — append-only, immutable row
  `(id, workspace_uri, subject_uri, key, body, created_by, source_turn_id)`.
  Moduledoc: *"Objects are append-only. Rollback and update semantics are
  represented by repointing `ConfigPointer`, never by mutating this row."*
  Partial unique index `socialware_config_objects_unique_source_turn` enforces
  **one object per `source_turn_id`** (idempotency at the DB).
- **`ConfigPointer`** (`socialware/config_pointer.ex`) — the **mutable cascade
  layer value**: `(id = layer|ws|subject|key, layer, config_id,
  previous_config_id, pointed_by, source_turn_id)`. Three layers:
  `workspace | user | session` (`validate_inclusion`). `previous_config_id`
  retains the prior object id — **this is the rollback breadcrumb, already there.**
- **`write_and_point/1`** — the ONE public durable-write path. A single
  `Ecto.Multi`: `Multi.insert(:object) |> Multi.run(:pointer, put_pointer)` in
  one `Repo.transaction`. Atomic ⇒ **no orphan object** ⇒ "object exists ⟺
  applied" invariant holds. (The object-only insert was deliberately REMOVED —
  PR-7 comment in `config_store.ex`.)
- **`put_pointer/1`** — repoint a layer to an *existing* object id, returning
  `previous_config_id`. `Repo.insert(on_conflict: {:replace, [...]},
  conflict_target: :id)` ⇒ an idempotent upsert keyed on the pointer id.
- **`resolve/4`**, **`layer_objects_for_key/2`**, **`list_keys_for_subject/1`**,
  **`current_user_object/2`**, **`fetch_object/1`**, **`fetch_matching_object/1`**
  (the cross-tenant guard for repoint), **`merge_delta/5`** — the full read +
  scope-validation surface the review/diff/publish steps consume.
- **Idempotency markers** — **`applied_for_turn?/1`** and **`object_for_turn/1`**
  (object-existence-keyed, superseded-turn-safe). The CR publish ceremony reuses
  `source_turn_id` for the SAME purpose.

### 1.2 Agent-owned evolution (`behavior/config_evolve.ex`)
- `apply_config_delta` (step 1: durable object+pointer write, `source_turn_id`
  idempotent, manage-cap gated), `repoint_config` (rollback/advance — validates
  `config_id` via `fetch_matching_object/1`, then `put_pointer`), `read_cascade`
  (manage-cap-gated cascade read), `reconcile_cascade` (boot self-heal).
- **CE-1 self-binding** (`assert_subject_self/2`): an agent may only ever apply
  config to ITSELF. The dispatch is gated by the TARGET agent's manage-cap; the
  handler re-binds `subject_uri`/`workspace_uri` to `self_uri`. **This invariant
  is inherited by CR publish unchanged** (see §6).
- The **deferred sandbox `write_path` self-dispatch** (step 2) that refreshes the
  on-disk cascade cache after a pointer move. CR publish emits the **same** step-2
  effect — it does not bypass it.

### 1.3 Materialization (`config_projection.ex`)
- `object_uri/2` gives an immutable object a stable `resource://<ws>/socialware-
  config-object/<b64(id)>` URI (workspace-segment is cap-checked authority,
  re-asserted in `resolve_config_dir/1`).
- `render_soul/1` is **deterministic** (keys sorted; `soul_md` verbatim) — *"two
  materializations of the same object yield byte-identical files."* **The review
  DIFF (§5) reuses `render_soul/1` to render the proposed vs released soul** so the
  human reviews the *actual projected CLAUDE.md*, not a raw map.

### 1.4 Console facade (`agent/config.ex`)
- `Ezagent.Agent.Config` already exposes `read_cascade/4`, `read_key/5`,
  `apply_delta/4`, `delete_path/4`, `repoint/4` to UI/domain, each routing through
  the **manage-cap gate via `Invocation.dispatch`** (never reading `ConfigStore`
  directly for the gated paths). **The CR console surface extends THIS facade** —
  it is the established boundary world already calls.

> **What is therefore NOT in this SPEC:** any new version-history table, any new
> immutability mechanism, any new atomic-write path, any new idempotency scheme,
> any new rollback mechanism. Those are §1 and are REUSED. See the explicit
> reuse-vs-new ledger in §9.

---

## 2. The gap CR closes

| Capability | Today | With CR |
|---|---|---|
| Stage many deltas before they go live | ✗ each `apply_config_delta` is immediate | ✓ accumulate N deltas under one open CR |
| Review the *combined* effect before publish | ✗ | ✓ lint + sandbox-vs-released diff + explicit confirm |
| One reviewed publish unit | ✗ N independent writes | ✓ one publish ceremony flips the pointer(s) atomically/idempotently |
| Reject a staged change wholesale | ✗ (already written) | ✓ reject an open CR — nothing was ever pointed-to |
| Roll back a published CR | ✓ `repoint_config` per-pointer (manual) | ✓ same `repoint_config`, surfaced as a CR action over the recorded prior pointers |
| Auto-proposed config changes ("dream") | ✗ | ✓ (optional sub-phase) a Dream becomes a CR source |

The decisive new property: **the period between "I want to change config" and
"config is live" becomes a reviewable, rejectable, single-confirm transaction.**

---

## 3. Data model (NEW — the only new schemas)

Two new tables in **`domain.identity`** (same app/domain as `ConfigStore`, so no
cross-domain dependency; the CR references `ConfigObject`/`ConfigPointer` rows
that live in the same domain). Both per-tenant ⇒ **`workspace_uri NOT NULL`**
(invariant #14).

### 3.1 `ConfigChangeRequest` (the envelope)
```
socialware_config_change_requests
  id                : string  (UUID, pk)
  workspace_uri     : string  NOT NULL          # invariant #14
  subject_uri       : string  NOT NULL          # the agent (or workspace) being changed
  status            : string  NOT NULL          # open | review | published | rejected | rolled_back
  opened_by         : string  NOT NULL          # entity URI (accountable; mirrors granted_by discipline)
  reviewed_by       : string                    # entity URI, set at confirm
  published_by      : string                    # entity URI, set at publish
  published_turn_id : string                    # the source_turn_id stamped on ALL objects published by this CR (idempotency)
  title             : string
  note              : string
  inserted_at / updated_at
```
- **One active (open/review) CR per `(workspace_uri, subject_uri)`** — a partial
  unique index `WHERE status IN ('open','review')`. Rationale: two concurrent open
  CRs against the same subject would race on the same pointers at publish. A CR is
  "the active change set for this subject." (Published/rejected/rolled_back CRs are
  historical and unconstrained.)
- `subject_uri` is the cascade subject — for the agent-config case it is the
  agent URI (the CE-1 self-binding subject). For a workspace-layer change it is a
  workspace URI. The cap model (§6) keys off it.

### 3.2 `ConfigChangeItem` (a staged delta, references a ConfigObject)
```
socialware_config_change_items
  id                : string  (UUID, pk)
  change_request_id : string  NOT NULL  (fk → change_requests.id)
  workspace_uri     : string  NOT NULL
  layer             : string  NOT NULL  # workspace|user|session (same allow-list as ConfigPointer)
  key               : string  NOT NULL  # cascade key, e.g. advisor.behavior
  staged_object_id  : string  NOT NULL  # → ConfigObject.id : the immutable, ALREADY-WRITTEN proposed object
  base_object_id    : string            # → ConfigObject.id : the object currently pointed-to at draft time (the diff base / expected-current guard)
  inserted_at / updated_at
```
- **Unique `(change_request_id, layer, key)`** — at most one staged item per
  cascade slot per CR (a later edit to the same slot replaces the item's
  `staged_object_id`, pointing at a newer immutable object — never mutates one).
- **`staged_object_id` references a REAL `ConfigObject` that is written
  immediately at stage time** via the existing path (see §4.2). This is the key
  reuse: **staging does NOT invent a "draft body" column — it writes a normal
  immutable object and simply does not point any layer at it yet.** The object is
  inert until publish flips the pointer. (Append-only objects with no pointer are
  the natural representation of "proposed but not live" — and `object_for_turn`
  /`applied_for_turn?` are unaffected because they key on `source_turn_id`, which
  for staged objects is the CR's own scheme, see §4.3.)
- **`base_object_id`** is the optimistic-concurrency / diff anchor: the object the
  layer pointed at when the item was staged. At publish, if the live pointer has
  moved off `base_object_id` (someone else changed config underneath the CR), the
  publish fails loud with a conflict (§4.4) — never silently clobbers.

> **Why an immediate immutable object at stage time, not a deferred body:**
> writing the object up-front means (a) the review DIFF renders the *real*
> projected soul from a real object via `render_soul/1`/`ConfigProjection`, not a
> speculative merge; (b) publish is a pure pointer flip (`put_pointer`) — the
> already-built atomic/idempotent operation — with **no object write in the
> ceremony**, so the ceremony cannot half-write. This is the cleanest reuse of the
> "object-keyed pointer" design the projection moduledoc calls out as *what makes
> apply naturally atomic.*

---

## 4. Lifecycle

```
        open ──stage/unstage items──▶ open
          │                              │
          │ request-review              │ (edits return it to open if in review)
          ▼                              │
        review ──confirm(reviewer)──────▶ published
          │                                  │
          │ reject                           │ rollback (repoint prior)
          ▼                                  ▼
        rejected                         rolled_back
```

### 4.1 `open` — create the CR
A manage-cap holder opens a CR for `(subject_uri)`. Fails if an active CR
already exists for that subject (the partial unique index). No config side effect.

### 4.2 stage / unstage items (CR stays `open`)
**Stage = write an immutable `ConfigObject` now, record a `ConfigChangeItem`
pointing at it, point NO layer.** Reuse:
- body computation: `ConfigStore.merge_delta/5` (patch) or an explicit
  `replace_body` — **identical to `ConfigEvolve.do_apply_config_delta`'s body
  step.**
- object write: a **new thin entry point** `ConfigStore.write_object_staged/1`
  that does `Multi.insert(ConfigObject.changeset(...))` **without** the pointer
  step. (See §4.2.1 — this is the ONE genuinely new ConfigStore function, and it
  is a deliberate, narrow re-opening of the object-only insert that PR-7 closed,
  fenced so it cannot create the orphan-class bug.)
- `base_object_id` = current `resolve/4` object id for that `(layer, subject,
  key)` (`:none` ⇒ nil, a fresh slot).

Unstaging deletes the `ConfigChangeItem`. The orphan `ConfigObject` it referenced
is simply left append-only and unreferenced (objects are never deleted — same as
a superseded object today).

#### 4.2.1 The orphan-object concern, addressed head-on
PR-7 removed the public object-only insert *because* it let a caller create an
object with no pointer, breaking "object existence ⟺ applied" that
`applied_for_turn?/1` relies on. **Re-introducing a staged object IS an
object-with-no-pointer.** This SPEC keeps the invariant sound by **scoping
staged objects out of the idempotency namespace**:
- Staged objects carry `source_turn_id = "cr-stage:<cr_id>:<item_id>"` (a CR-owned
  scheme), **NEVER a real settled `turn_id`**. So `applied_for_turn?(turn_id)` /
  `object_for_turn(turn_id)` for a *real* turn are unaffected — a staged object's
  `source_turn_id` never collides with a turn's.
- The "object existence ⟺ applied" invariant is specifically about **settled-turn
  deltas** (the `ConfigEvolve` recovery path). Staged objects are not part of that
  path; they become "applied" only when the CR publish points a layer at them
  under the CR's *publish* turn id (§4.3). Until then they are deliberately inert.
- `write_object_staged/1` is **not** a general re-opening of object-only insert: it
  requires a `cr-stage:` `source_turn_id` prefix (rejected otherwise), so it
  cannot be used to forge a settled-turn orphan.

> **OPEN QUESTION Q1 (lead):** is the `cr-stage:` `source_turn_id` namespace
> fence sufficient, or does the lead prefer staged objects carry no
> `source_turn_id` at all (NULL) — which would require relaxing
> `ConfigObject`'s `validate_required(:source_turn_id)` and the partial unique
> index semantics? The fence keeps the existing NOT-NULL + unique index intact,
> which is why it is the recommended option.

### 4.3 publish ceremony (CR `review` → `published`)
After an explicit reviewer confirm (§5), publish:
1. Mint ONE `published_turn_id = "cr-publish:<cr_id>"` for the whole CR. This is
   the `source_turn_id` stamped on EVERY pointer the publish flips — so the whole
   publish is **idempotent as a unit** (re-running publish for the same CR is a
   no-op upsert, same `source_turn_id`, via `put_pointer`'s `on_conflict`).
2. For each `ConfigChangeItem`, in ONE `Ecto.Multi` (see §4.3.1 for the
   atomicity decision): `ConfigStore.put_pointer/1` with
   `{layer, workspace_uri, subject_uri, key, config_id: staged_object_id,
   actor_uri: published_by, source_turn_id: published_turn_id}`. **`put_pointer`
   already returns `previous_config_id`** — captured per item.
3. Flip `status → published`, set `published_by`, `published_turn_id`, and record
   each item's returned `previous_config_id` (so rollback in §4.5 has the prior
   pointer per item without a new history mechanism).
4. Emit the **existing** deferred `sandbox.write_path` self-dispatch (the step-2
   cascade-cache refresh) — exactly as `ConfigEvolve` does after a pointer move,
   so the on-disk soul is refreshed. (Mechanism: publish is dispatched to the
   agent so it runs inside the agent's own handler with `ctx.siblings[:sandbox]`,
   and reuses `sandbox_write_effects/3` — see §6/§7.)
5. "Recycle": the CR is now terminal-`published`; the active-CR unique index frees
   up so a new CR can be opened for the subject. No object/pointer cleanup — append
   -only objects stay; superseded objects remain for rollback (same as today).

#### 4.3.1 Atomicity decision (the sharp edge)
A CR can stage items across **multiple `(layer, key)` slots** ⇒ multiple
pointers. Two options:
- **(A) one `Repo.transaction` wrapping all `put_pointer` calls** — all-or-nothing
  across pointers. Clean, but `put_pointer` is currently called standalone; CR
  publish would wrap N of them in a `Multi`. **Recommended.** Each `put_pointer`
  is already a single upsert, so composing them in one Multi is mechanical and
  preserves per-item `previous_config_id` capture.
- (B) per-pointer idempotent flips (no outer transaction), relying on the shared
  `published_turn_id` to make a crashed/partial publish *resumable* (re-run
  flips the not-yet-flipped pointers; already-flipped ones are `on_conflict`
  no-ops). Weaker atomicity, stronger crash-resumability.

> **OPEN QUESTION Q2 (lead):** A (atomic, all-pointers-in-one-Multi) vs B
> (resumable via shared `source_turn_id`)? A matches the "one reviewed publish
> unit" mental model best; B matches `ConfigEvolve`'s existing
> idempotent-resume philosophy. Recommended: **A**, since the per-item
> `previous_config_id` capture wants a single transaction anyway, and resumability
> is less important when publish is a fast pure-pointer flip.

### 4.4 base-drift conflict (concurrency safety)
Before flipping each pointer, assert the live pointer still resolves to the item's
`base_object_id` (via `resolve/4`). If it has moved (config changed underneath the
CR since staging), abort the whole publish with `{:error, {:cr_base_drift, item}}`
— the reviewer must re-review against the new base. Reuses `resolve/4`; no new
read. (Per the let-it-crash / no-silent-clobber principle.)

### 4.5 rollback (CR `published` → `rolled_back`)
**REUSES the existing repoint — no new version-history mechanism.** For each
published item, dispatch the **existing** `ConfigEvolve.repoint_config` (or
`ConfigStore.put_pointer`) with `config_id = previous_config_id` (recorded at
publish in step 4.3.3). `repoint_config` already:
- validates the prior object exists + is in scope (`fetch_matching_object/1`),
- advances the pointer back (`put_pointer`, returning the now-current id),
- emits the step-2 sandbox refresh.

The CR row flips to `rolled_back`. **Rollback is literally "publish the prior
objects"** — the SAME pointer-flip operation aimed backward, which is exactly the
design `ConfigStore`'s moduledoc states: *"Rollback is the same repoint operation
aimed at a prior retained object."* If `previous_config_id` is nil (the slot was
fresh at publish), rollback for that item is "no prior pointer" — Q3.

> **OPEN QUESTION Q3 (lead):** for a CR item whose slot had NO prior object
> (`previous_config_id == nil`, a brand-new key), rollback cannot "repoint to
> prior." Options: (a) leave the new pointer in place (partial rollback, logged);
> (b) delete the pointer row entirely (a new operation — `ConfigStore` has no
> pointer-delete today; would be genuinely new). Recommended: **(a)** to avoid
> adding a pointer-delete primitive (keeps "no new mechanism"); document the
> partial-rollback semantics.

---

## 5. Review gate (lint + sandbox-vs-released DIFF + explicit confirm)

The review step is **pure reads over existing data + a deterministic projection
diff** — no new persistence.

### 5.1 lint
Per-item structural checks reusing the existing validators:
- `ConfigStore.normalize_layer/1`, `validate_key/1`, `normalize_uri/2` (the
  #607 round-5 upfront chokepoint already used by `ConfigEvolve`).
- body shape: each `staged_object_id` resolves (`fetch_object/1`) and its body is
  a map (so `render_soul/1` won't crash).
- base-drift pre-check (§4.4) surfaced as a lint warning at review time (not just
  at publish), so the reviewer sees "base moved" before confirming.

### 5.2 the DIFF (the heart of the gate)
For each item compute **released-vs-proposed** entirely from existing reads:
- **released** body = `ConfigStore.resolve(layer, ws, subject, key)` →
  `object.body` (the currently-pointed object), or `%{}` if `:none`.
- **proposed** body = `ConfigStore.fetch_object(staged_object_id).body`.
- **rendered diff** = `ConfigProjection.render_soul(released)` vs
  `render_soul(proposed)` — a text diff of the **actual projected CLAUDE.md
  (soul)**, plus a structural map diff of the bodies. `render_soul/1` is
  deterministic, so the diff is stable and reproducible.
- **effective-cascade diff** (optional, richer): reuse the
  `ConfigEvolve.handle_read_cascade` `effective_body/1` merge (workspace→user→
  session) to show the *effective* config before/after, not just the single
  layer. This is the same merge the console read already exposes, so the review UI
  and the live read agree.

No new diff storage — the diff is computed on demand from `ConfigObject` bodies +
`render_soul/1`. Two reviewers opening the same CR see byte-identical diffs.

### 5.3 explicit confirm (the chokepoint)
`request_review` moves `open → review`. `confirm` moves `review → published`
(triggering §4.3) and is the **single human gate**: it requires the review cap
(§6) and records `reviewed_by`. `reject` moves `review → rejected` (or
`open → rejected`) — no config side effect ever happened, so reject is free.

> Editing items while in `review` returns the CR to `open` (the diff the reviewer
> approved must match what publishes — a staged-set change invalidates the
> review). Enforced by the lifecycle transition table, not by trusting the caller.

---

## 6. Cap model (who can open / review / publish — the chokepoint)

CR governance introduces a **three-role separation** mapped onto the existing
CapBAC machinery (`references/capbac.md` §1; Decision #154 — every `granted_by` a
real entity). The principle: **publish must be gated on a cap distinct from
"can edit config," so the reviewer is a real chokepoint, not the same authority
that stages.**

| CR action | Required cap (declared in `required_caps/0`) | Rationale |
|---|---|---|
| `open` / `stage` / `unstage` | `cap(:agent, ConfigEvolve, :apply_config_delta)` resolved to the subject — i.e. **the existing manage-cap** (the runtime overwrites needed-action; manager's `Manage :any` matches) | staging writes inert objects only; whoever may edit config may stage. Same authority as `apply_config_delta` today. |
| `request_review` | manage-cap (same as stage) | a procedural move, no side effect |
| `confirm` (publish) | **a NEW distinct cap** `cap(:agent, ConfigGovernance, :publish_cr)` over the subject | THE chokepoint — separates "propose" from "approve." A reviewer holds publish authority the stager need not. |
| `reject` | publish-cap OR manage-cap | either the reviewer rejects, or the opener withdraws |
| `rollback` | publish-cap (rolling back is a publish-class action) | only an approver may revert a published CR |

### 6.1 Where the cap is enforced — REUSE the dispatch gate, do not hand-roll
CR governance actions are **Behavior actions on the subject agent** (a new
`Ezagent.Behavior.ConfigGovernance` Lifecycle behavior mounted on the agent Kind,
sibling to `ConfigEvolve`), so authorization is the **standard dispatch step-5.5
cap check** (`runtime.ex`), NOT a facade `if`-check. This mirrors exactly how
`ConfigEvolve.read_cascade` was deliberately routed through dispatch *"so the gate
is structural, not a hand-rolled facade check"* (its moduledoc). The console
facade (§8) dispatches; the gate runs in the runtime.

### 6.2 CE-1 self-binding inherited
Publish dispatches to the subject agent and runs in its own handler; like
`ConfigEvolve`, it **re-binds `subject_uri`/`workspace_uri` to `self_uri`**
(`assert_subject_self/2`) before any `put_pointer`. A caller managing agent A
cannot publish a CR whose pointers target agent B even if the CR row claims B —
the self-bind rejects it. The CR's `subject_uri` is validated == the dispatched-to
agent at publish.

### 6.3 granter discipline
The new `publish_cr` cap is granted via the existing `Ezagent.Identity.Grant`
chokepoint. It is **concrete-scoped** (`kind: :agent, behavior: ConfigGovernance,
action: :publish_cr, instance: <agent or scope-tuple>`), so it is rule-eligible
(`rule_cap_bounded?`) — e.g. a workspace policy "workspace admins may publish CRs
for agents in their workspace" mints it under `{:rule, "ws_admin_publish", admin}`
with `granted_by = admin`. No new system principal.

> **OPEN QUESTION Q4 (lead):** is `publish_cr` a brand-new Behavior+cap
> (`ConfigGovernance`), or should publish reuse the manage-cap with the *human
> confirm* being the only gate (i.e. governance is procedural, not a separate
> authority)? A distinct cap gives a real two-person-rule chokepoint; reusing
> manage-cap is simpler but means "anyone who can edit can also self-approve."
> Recommended: **distinct cap**, defaulting (for backward compat / single-operator
> workspaces) to *also granted to manage-cap holders* so existing flows don't
> regress, while leaving room for a real separated reviewer.

---

## 7. Where it lives + reuse map (three-tier)

All in **`domain.identity`** (where `ConfigStore` + `ConfigEvolve` live):
- `Ezagent.Socialware.{ConfigChangeRequest, ConfigChangeItem}` — new Ecto schemas
  (§3), beside `ConfigObject`/`ConfigPointer`.
- `Ezagent.Socialware.ConfigChangeStore` — new thin module: open/stage/unstage/
  transition/list/diff query helpers. **Delegates every config read/write to
  `ConfigStore`** (`write_object_staged/1`, `put_pointer/1`, `resolve/4`,
  `fetch_object/1`, `merge_delta/5`). Owns ONLY the CR/item rows.
- `Ezagent.Behavior.ConfigGovernance` — new `use Ezagent.Lifecycle` Behavior on
  the agent Kind (sibling to `ConfigEvolve`); actions: `open_cr`, `stage_item`,
  `unstage_item`, `request_review`, `confirm_cr` (publish), `reject_cr`,
  `rollback_cr`, `review_diff` (read). Each `put_pointer`/`repoint` it performs is
  the EXISTING `ConfigStore`/`ConfigEvolve` operation; it emits the EXISTING
  step-2 sandbox refresh. Declares `reads_siblings([:sandbox, :identity])` exactly
  as `ConfigEvolve` does.
- `Ezagent.Agent.Config` (existing facade) — extended with CR methods
  (`open_change_request/4`, `stage/4`, `review/4`, `publish/4`, `rollback/4`),
  each dispatching the corresponding `config_governance.<action>` — the same
  dispatch pattern its existing methods use.
- `ConfigStore.write_object_staged/1` — the ONE new `ConfigStore` function (§4.2.1).

---

## 8. Console surface (which reads the review UI consumes)

The world review UI is **read-only over existing reads + one confirm dispatch**:
- **CR list / detail**: new `ConfigChangeStore` queries (CR rows + items) — these
  are the only genuinely new reads, and they are over the new CR tables only.
- **Per-item diff panel**: consumes `Agent.Config.review/4` → dispatches
  `config_governance.review_diff` → returns, per item, `{released_body,
  proposed_body, released_soul, proposed_soul, effective_before, effective_after}`
  computed via §5.2 (all from `ConfigStore.resolve/4` + `fetch_object/1` +
  `render_soul/1` + the `effective_body` merge). The UI renders a text diff of the
  souls + a structural body diff — **no new data, the same projection the live
  agent reads.**
- **Confirm button** → `Agent.Config.publish/4` → `config_governance.confirm_cr`
  (publish-cap gated). **Reject** / **Rollback** are sibling dispatches.
- Reuses the existing cascade read (`read_cascade`) for the "current live config"
  column so the review UI and runtime never diverge.

No new wire contract beyond the CR list/detail/diff shapes; the diff shape is a
superset of what `read_cascade` already returns per key.

---

## 9. Reused vs new — the explicit ledger

| Concern | Status | Where |
|---|---|---|
| Immutable config object | **REUSED** | `ConfigObject` |
| Mutable cascade pointer | **REUSED** | `ConfigPointer` |
| Atomic object+pointer write | **REUSED** | `write_and_point/1` (used at stage for the object via `write_object_staged`; publish reuses `put_pointer`) |
| Pointer flip / repoint | **REUSED** | `put_pointer/1` |
| **Rollback** | **REUSED — explicitly NOT a new mechanism** | `repoint_config` → `put_pointer(config_id: previous_config_id)`; `previous_config_id` is the existing breadcrumb |
| **Idempotency** | **REUSED** | `source_turn_id` (CR uses `cr-publish:<id>`); `put_pointer` `on_conflict` upsert; `object_for_turn`/`applied_for_turn?` namespace-fenced |
| Cross-tenant target guard | **REUSED** | `fetch_matching_object/1` |
| Soul projection / diff render | **REUSED** | `ConfigProjection.render_soul/1`, `object_uri/2` |
| Cascade read / effective merge | **REUSED** | `ConfigStore.resolve/4`, `layer_objects_for_key/2`, `ConfigEvolve.effective_body` shape |
| Self-binding (subject == self) | **REUSED** | `assert_subject_self/2` pattern |
| Manage-cap dispatch gate | **REUSED** | `required_caps/0` + step-5.5 |
| Step-2 sandbox cache refresh | **REUSED** | `sandbox_write_effects/3` |
| Console facade boundary | **EXTENDED** | `Ezagent.Agent.Config` |
| CR envelope + staged items | **NEW** | `ConfigChangeRequest`, `ConfigChangeItem` |
| Object-only staged insert | **NEW (narrow, fenced)** | `ConfigStore.write_object_staged/1` (`cr-stage:` `source_turn_id` only) |
| Governance behavior + lifecycle | **NEW** | `Ezagent.Behavior.ConfigGovernance` |
| Publish cap | **NEW** | `cap(:agent, ConfigGovernance, :publish_cr)` |
| Review diff query | **NEW (pure read)** | `ConfigChangeStore` / `review_diff` action |

---

## 10. Test plan

Unit + invariant-style, matching the repo's "a test that fails when the
architectural goal is unmet" gate philosophy.

1. **Stage writes an inert object** — after `stage_item`, a `ConfigObject` exists
   (`fetch_object`) but `resolve/4` for the slot is unchanged (no pointer moved).
2. **Idempotency namespace fence** — a staged object's `source_turn_id` is
   `cr-stage:…`; `applied_for_turn?(real_turn_id)` and `object_for_turn(real_turn
   _id)` are unaffected by staging (the PR-7 invariant regression guard).
3. **Publish flips pointers atomically** — after `confirm_cr`, every item's slot
   `resolve/4`s to its `staged_object_id`; each item records the prior
   `previous_config_id`. (Option-A: a forced mid-publish failure leaves NO pointer
   moved.)
4. **Publish idempotency** — re-running `confirm_cr` for the same CR
   (`source_turn_id = cr-publish:<id>`) is a no-op upsert (no new pointer rows, no
   change).
5. **Base-drift conflict** — change the live config underneath an open CR, then
   publish ⇒ `{:error, {:cr_base_drift, _}}`; nothing flipped.
6. **Rollback = repoint prior** — publish a CR, then `rollback_cr`; every slot
   `resolve/4`s back to its `previous_config_id` object; CR `rolled_back`. Assert
   it goes through `repoint_config`/`put_pointer` (no new mechanism).
7. **Cap chokepoint** — a caller with manage-cap but WITHOUT `publish_cr` can
   `stage`/`open` but gets `:unauthorized` on `confirm_cr` (the two-role
   separation). A caller with neither gets `:unauthorized` on `open`.
8. **CE-1 self-binding inherited** — a CR row whose `subject_uri` ≠ dispatched-to
   agent is rejected at publish (`assert_subject_self`).
9. **One active CR per subject** — opening a second CR for a subject with an
   open/review CR fails the partial unique index.
10. **Reject is free** — `reject_cr` from `open`/`review` leaves `resolve/4`
    unchanged (no config side effect ever).
11. **Diff determinism** — `review_diff` for the same CR is byte-identical across
    calls (reuses deterministic `render_soul/1`).
12. **Sandbox refresh on publish** — `confirm_cr` emits the step-2
    `sandbox.write_path` self-dispatch (reuse, not bypass).
13. **Edit-in-review invalidation** — staging into a `review` CR returns it to
    `open` (the approved diff can't drift from what publishes).

---

## 11. Optional later sub-phase — Dream auto-proposal as a CR source (MARK OPTIONAL)

> Not in the initial scope. Recorded so the data model doesn't foreclose it.

A "Dream" (an agent-generated self-improvement proposal) becomes **just another CR
source**: the dream process opens a CR (`opened_by = the agent itself` or a
designated dreamer principal) and stages items the same way a human would. The
review gate is then the human-in-the-loop check on machine-proposed config. No new
data model — `opened_by` simply records the dreamer entity, and the same
review/publish/reject/rollback lifecycle applies. The only addition would be a
`source` discriminator (`human | dream`) on `ConfigChangeRequest` for UI filtering.
The cap model already covers it: the dreamer needs only the stage (manage) cap;
publishing a dream-CR still requires the separate `publish_cr` cap — so a machine
can propose but a human (or a cap-holding reviewer) must approve.

---

## 12. Risks

- **R1 — orphan-object invariant.** The whole staging model re-opens object-with-
  no-pointer. Mitigated by the `cr-stage:` `source_turn_id` namespace fence
  (§4.2.1) + `write_object_staged/1` rejecting non-`cr-stage:` turn ids. **This is
  the #1 codex-review surface** (does it truly not regress PR-7's invariant?).
- **R2 — multi-pointer publish atomicity** (§4.3.1, Q2) — A vs B.
- **R3 — base drift** — handled (§4.4) but adds a read per item at publish.
- **R4 — cap-model default** (Q4) — distinct `publish_cr` vs manage-cap reuse;
  must not regress single-operator flows.
- **R5 — nil-prior rollback** (Q3) — partial rollback vs new pointer-delete
  primitive.

---

## 13. Acceptance (/goal — to set after review)

- A CR aggregates N config deltas under one envelope per subject; staging writes
  inert immutable objects (no pointer moved) — proven by test 1+2.
- Review computes a deterministic sandbox-vs-released soul diff from existing reads
  + `render_soul/1` — test 11.
- Publish flips the pointer(s) via `put_pointer` (atomic/idempotent via the
  existing Multi + `source_turn_id`), emits the existing sandbox refresh, and
  records prior pointers — tests 3,4,12.
- Rollback reuses `repoint_config`/`put_pointer` aimed at `previous_config_id` —
  **no new version-history mechanism** — test 6.
- Publish is gated on a cap distinct from stage (the chokepoint) — test 7.
- Zero regression to the PR-7 "object existence ⟺ applied" invariant — test 2.
- full `mix test` 0 failures + CI green (incl. `check_invariants`).

---

## Open questions for the lead (consolidated)

- **Q1** — `cr-stage:` `source_turn_id` namespace fence vs NULL `source_turn_id`
  for staged objects (§4.2.1). Recommended: the fence (keeps NOT-NULL + index).
- **Q2** — publish atomicity: single Multi (A) vs resumable-via-`source_turn_id`
  (B) (§4.3.1). Recommended: A.
- **Q3** — rollback of a nil-prior (brand-new-key) item: leave pointer (a) vs add
  a pointer-delete primitive (b) (§4.5). Recommended: a.
- **Q4** — `publish_cr` distinct cap vs manage-cap reuse with human-confirm as the
  only gate (§6, Q4). Recommended: distinct cap, also-granted-to-manage by default
  for back-compat.
- **Q5** — subject scope: agent-only first, or also workspace-layer CRs in v1?
  (The data model supports both via `subject_uri`; scoping v1 to agent subjects is
  smaller.)
