# Unified Kind Creation via Templates — Design (rev 4)

**Date:** 2026-06-01
**Status:** Draft rev 4 (three codex adversarial rounds folded in; pending re-review + Allen approval)
**Author:** Claude (with Allen)

> **rev 4 changes** (codex review of rev 3 — closed G-1; fixed the last two blockers):
> the manage-cap grant keys off the **atomic `ever_created` false→true transition
> SURFACED by the create path** (not a pre-spawn probe, which is a TOCTOU and can
> mis-fire on an `:already_started` adopt; A-1), with `created_by` **threaded as a
> create arg** into spawn→init so the grant fires inside the once-only atomic create
> (generalizing the existing Session `owner_uri` pattern). For the ephemeral Workspace
> the once-only signal is `Store.create` row-insert success. The `exists_durably?`
> probe is retained ONLY for the bridge-join existence check (where a race is benign).
> `reconfigure/4` returns `{:dispatch, %Ezagent.Cmd{}}` effects (the actual effect
> grammar) and the inner config-update dispatches are **self-dispatches**
> (caller = Kind `self_uri`; D-1 + authz).
>
> **rev 3** (codex of rev 2): closed B-1/C-1/E-1/G-2; per-Kind freshness; reconfigure
> as Manage dispatches; teardown composes with `destroy/2` (G-1).
> **rev 2** (codex of rev 1): build the entry (B-1); `:any` manage-cap + Session caveat
> (C-1); new reconfigure hook (D-1); per-Class teardown (G-1); User ordering (E-1).

## 1. Problem & context

A team-routing "management authority" discussion surfaced a structural problem,
confirmed by a read-only audit of every Kind creation path:

- There **is** a mechanical single-spawn chokepoint — `Ezagent.Kind.spawn/2`
  (`apps/ezagent_core/lib/ezagent/kind.ex:294`) → `Kind.Server.init/1`
  (`server.ex:104`) → `KindRegistry.put_new/2` (`kind_registry.ex:42`), enforced by
  `single_spawn_entry_test.exs`. **But it is authorization-free and owner-free** —
  pure URI→pid registration. **Registration ≠ authorized creation.**
- There is **no universal authorized create entry today.** `template.instantiate`
  exists only on AgentTemplate/SessionTemplate
  (`apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex:280`), and SessionTemplate
  explicitly refuses it (`:285` → `{:error, :use_generator}`). Session/Workspace/User
  creation go through **domain-specific functions** — `create_session/3`
  (`ezagent_domain_chat.ex:119`), `Workspace.create/2` (`workspace.ex:61`),
  `Users.create/3` via `workspace_user_admin` (`workspace_user_admin.ex:151`) — **none
  carrying a `ctx.caller`**. Authorization is bolted on only at the dispatched
  `workspace.create_*` actions; the ~7 direct-`spawn` paths bypass it (worst: the
  agent-bridge channel join, `agent_bridge/channel.ex:146`, which materializes a fresh
  unowned Agent and is invisible to `agent_create_single_path_test.exs`).
- The **owner-cap-at-creation pattern exists piecemeal** (Session `owner_uri` +
  `grant_first_join_owner_cap`; Template `grant_*_owner_cap`; the `OwnedBehavior` test
  idiom) but is **not** at the chokepoint, and absent for Agents (lineage only),
  Workspaces (no owner), Users.

**Therefore the unified authorized create entry is the thing this spec BUILDS** — it
is not a wrapper over an existing universal action. Allen's directive (2026-06-01):
introduce a Template concept for ALL Kinds and funnel creation + modification through
one authorized chokepoint that threads `created_by` and grants a management capability
at creation; do this foundation FIRST.

R/B/K = Router/Behavior/Kind (internal engine); Lifecycle = public API
(ARCHITECTURE.md §153). A **Template** = Template **Class** (module implementing
`Ezagent.Kind.Template`) + Template **Instance** (the runtime Kind). This generalizes
the existing pattern.

## 2. Goals / non-goals

**Goals**
1. Every Kind type (Session, Agent, Workspace, User, AgentTemplate, SessionTemplate)
   is created through a Template Class via a single **authorized, `ctx.caller`-bearing**
   dispatched entry — **built** by this work.
2. That entry grants `cap(:<kind>, Ezagent.Behavior.Manage, :any, instance)` to
   `created_by` (= `ctx.caller`) on **fresh create only**, where "fresh" is decided by
   the CORE `ever_created` signal (not a Class return value).
3. **Modification** (`reconfigure`/`delete`) is unified through `Ezagent.Behavior.Manage`
   on every Kind, gated by the manage-cap, and is lifecycle-consistent via a **new
   per-Class `reconfigure` hook** that mutates the live Kind preserving identity +
   runtime state (never destroy+recreate).
4. Each Template Class declares a **teardown contract** used for both failed-create
   rollback and `manage.delete`.
5. The ~7 ad-hoc creation paths converge onto the entry (or refuse to create via an
   explicit existence predicate).
6. CI invariants make a future bypass fail loudly.

**Non-goals (this spec)**
- Routing-row edit authz consuming the manage-cap (team-routing follow-up).
- Versioned/blueprint template synthesis.
- Re-modelling Behaviors or the Lifecycle engine (we ADD one hook + one behavior).

## 3. Design

### 3.1 Freshness = the ATOMIC `ever_created` transition, surfaced (A-1)

The grant must fire **iff THIS call durably created the Kind** — race-free, not on an
adopt/rehydrate. Two rejected approaches: (a) the Class's `instantiate/3` `fresh?` meta
is optional (`GenericSession` returns a bare 2-tuple, `generic_session.ex:99`); (b) a
**pre-spawn** `exists_durably?` probe is a **TOCTOU** — between probe and spawn another
path can create it, and a plugin `instantiate` can succeed by *adopting* an
`:already_started` worker (`cc_agent.ex:~789`), so a stale pre-spawn `false` would
mis-grant.

**Resolution — key the grant off the atomic once-only create signal, surfaced from the
create path, with `created_by` threaded in:**

- **Snapshot-backed Kinds** (Agent/Session/User/Templates): the initial-snapshot upsert
  that flips `ever_created` `false→true` is atomic and fires the Lifecycle `create/1`
  hook exactly once (`lifecycle.ex:350`, `snapshot.ex:341`, `server.ex:193`). This work
  **surfaces that transition** — `persist_initial_snapshot` / the upsert returns
  `:created` vs `:existed` (today it returns only `:ok`, `kind_snapshot.ex:198-200`) —
  so the create path knows authoritatively, with no TOCTOU, whether THIS call created it.
- **Ephemeral Workspace** (no snapshot; `workspace.ex:55`): the once-only signal is
  `Workspace.Store.create/2` row-insert success (a duplicate insert conflicts), `:created`
  vs `:exists`.
- **`created_by` is threaded as a create arg** into `Kind.spawn` → `init` (exactly as
  Session already threads `owner_uri`), so the grant — fired inside / immediately after
  the atomic create-success — has the authenticated creator without re-reading any
  racy state.

The grant therefore happens **as part of the atomic once-only create**, not a separate
probe. A `:existed`/adopt result → no grant (the durable manage-cap is already present).

(The `exists_durably?(uri)` *probe* — `KindSnapshot.ever_created?/1`, an exported
`Repo.get`, `kind_snapshot.ex:198-200`; or the `Workspace.Store` row — is retained ONLY
for the **bridge-join existence check** in §3.8, where "does it exist at all, to decide
rehydrate-vs-refuse" tolerates a benign race.)

### 3.2 The unified authorized create entry (BUILD) (B-1)

Introduce one dispatched create surface that every Kind's creation flows through.
Concretely:

- A create action — `kind.create` (carried on a core/domain create behavior, or the
  generalized `Ezagent.Behavior.Template`) — dispatched against the **scope** that owns
  the new Kind (workspace for agents/sessions/users; system/bootstrap for workspaces),
  so `Kind.Runtime` step 5.5 CapBAC runs and `ctx.caller` is the authenticated
  `created_by`. Authorization reuses the existing per-scope create caps (OQ-1) — this
  work does not widen WHO may create, it makes the authz uniform + unavoidable.
- The handler: resolve the target Template Class → `validate/1` → `instantiate/3`
  (threading `created_by`=`ctx.caller` as a create arg) → the atomic create surfaces
  `:created` vs `:existed` (§3.1) → on `:created`, run the grant (§3.3); on any failure
  after a fresh spawn, run the Class teardown then `destroy/2` (§5/G-1).
- **Migration of existing create paths onto the entry** (the bulk of the work):
  `create_session/3`, `Workspace.create/2`, `create_user`, the Loader fresh-create
  branch, `Agent.spawn_fresh/4` / `spawn_from_template_content/4`, and the plugin Class
  spawns become callers of (or are replaced by) this entry, each supplying a real
  `created_by`. Boot/login/bridge **rehydrate** stays on `SpawnRegistry.spawn` (no
  ctx.caller needed — no grant on rehydrate).

`Kind.spawn/2` remains the mechanical primitive for rehydrate; **fresh creation outside
the entry is a CI failure** (§6).

### 3.3 Manage-cap grant — CORE step, `:any` action, Session caveat (A-1, C-1)

After a fresh create (the atomic create path returned `:created`, §3.1, using the
`created_by` threaded as a create arg), the core handler grants, for each freshly
created owned Kind URI:

```
cap(kind_of(uri), Ezagent.Behavior.Manage, :any, instance: uri)  → granted to ctx.caller
```

- **`action: :any`** (not `:manage`): dispatch overwrites the needed-cap action with the
  concrete dispatched action (`runtime.ex:392-431`), and `matches?` compares
  `action_of(cap)` to the needed action (`capability.ex:212-229`). A held `:manage`
  action would NOT match a needed `:reconfigure`/`:delete`. `:any` (scoped to
  `Behavior.Manage` + the specific `instance`) means "any management action on THIS
  instance" — which is exactly "manage" and is NOT over-broad (behavior + instance
  pinned).
- The grant uses `created_by` = `ctx.caller`; a Class cannot influence the grantee.
- Skipped on rehydrate (cap already durable). Idempotent across restart by construction.
- Folds in the piecemeal Session/Template owner-cap grants.

**Session caveat (C-1) — DECISION PENDING (OQ-4):** the kind-axis trick (a `:agent`/
`:workspace`/`:user` manage-cap is NOT matched by the user baseline
`cap(:session, :any, :any)`, `user.ex:175`) cleanly excludes ordinary users for those
three Kinds. But a **`:session`** manage-cap `cap(:session, Manage, :any, S)` **IS**
matched by that baseline wildcard when S is in the user's workspace — so in a shared
workspace any member could `manage.reconfigure`/`delete` any session. Lean:
**session-manage authority retains the existing `owner_uri` gate** (the Manage behavior,
for Session, additionally checks the caller is the session owner or admin), with the
uniform manage-cap serving Agent/Workspace/User. The alternative (narrow the default
user `:session` wildcard) is a broader change. Allen to decide.

### 3.4 `Ezagent.Behavior.Manage` — uniform management surface (C-1)

New core behaviour registered on every Kind via
`CapabilityRegistry.register(<Kind>, <action>, Ezagent.Behavior.Manage)` (same mechanism
as `register(Session, :join, Chat)`, `application.ex:662`). Actions:

- `:reconfigure` — args `%{template_data: map}` → live re-materialize (§3.5).
- `:delete` — `manage.delete`, maps to Lifecycle `destroy/2` via the Class teardown (§5).

`required_caps[:reconfigure] = required_caps[:delete] = cap(:any, Manage, :any)`,
resolved against the target instance at dispatch. The granted manage-cap
(`cap(:<kind>, Manage, :any, instance)`, §3.3) satisfies both. For Session, the handler
adds the `owner_uri`/admin check (§3.3 caveat) until OQ-4 is decided.

### 3.5 `reconfigure` is a NEW per-Class hook (D-1)

There is no existing "re-apply instantiate to a live Kind" capability — `instantiate/3`
is a create/adopt procedure (spawns, starts sidecars, joins members;
`cc_agent.ex:385`, `generic_session.ex:99`); re-running it against a live Kind is
undefined and would hit `put_new` `{:already_started}`.

**Layering constraint (codex D-1):** a Template Class is NOT the Kind's running
Behavior. Dispatch reduces effects into the **dispatched behavior's own slice** only
(`runtime.ex:172-191`, `:993-999`); `{:set, key, v}` writes the current behavior's
slice, not an arbitrary sibling slice (`behavior.ex:1091`). So a Class cannot directly
write the live Kind's config slice.

**Resolution:** `manage.reconfigure` is an action on **`Ezagent.Behavior.Manage`**
(§3.4); the Manage behavior owns a small **`:spec` slice** recording the
`template_data` the Kind was created/last-reconfigured with (present on every Kind via
the Manage registration). The handler:

1. Runs the Class `validate/1` on `new_data`; rejects immutable-identity changes
   (username, workspace name — OQ-3).
2. Writes `new_data` to its OWN `:spec` slice (`{:set, :spec, new_data}` — same-behavior
   effect, legal).
3. Executes the **dispatch effects** the Class's new optional callback returns:

   ```
   @callback reconfigure(uri, old_data, new_data, ctx) ::
               {:ok, [dispatch_effect]} | {:error, term()}
   ```

   `reconfigure/4` returns `{:dispatch, %Ezagent.Cmd{}}` effects — the ACTUAL effect
   grammar (`behavior.ex:893`; `{:dispatch, target, action, args}` is NOT a valid effect
   shape) — for re-bind / re-grant / route-reconcile / **config-update via the Kind's
   OWN behaviors' actions** / sidecar restart via `ensure_subprocess_alive/2` (GLOSSARY
   §128). The effect pipeline already executes the dispatch buckets
   (`runtime.ex` Dispatches/DispatchesReturning), so these reach the right slices through
   the normal dispatch path (no new cross-slice mechanism). **Inner-dispatch authz:**
   these are **self-dispatches** — the `%Cmd{}` carries `caller: self_uri` (the Kind
   reconfiguring its OWN behaviors); the config-update actions authorize self-dispatch
   (a Kind may update its own slices), so no external caller's caps are implicated.
   Behaviors that need the config read the Manage `:spec` slice via the existing
   `reads_sibling_slices`
   mechanism.

- Same URI, same identity; runtime `transients` untouched except where a returned
  dispatch explicitly restarts a sidecar. Durable `state` persists; `transients` rebuilt
  by `activate/2`.
- A Class without `reconfigure/4` → `manage.reconfigure` returns
  `{:error, :reconfigure_unsupported}` (immutable Kind).

This is a bounded addition (one Manage slice + one optional Class callback returning
dispatches) — NOT "rerun instantiate" and NOT a new cross-slice effect type.

### 3.6 Workspace Template Class (proposed)

`Ezagent.Template.Workspace` (workspace domain). `template_data`: `name`, `owner`
(defaults to `created_by`), `default_agent_template` (seeds `<username>-default`),
optional `default_caps_policy`. `instantiate/3` = `Workspace.Store.create/2` +
`Kind.spawn(Workspace)`. `exists_durably?` reads the `Workspace.Store` row (Workspace is
`:ephemeral` — no snapshot marker; §3.1). `teardown` deletes the Store row + undoes
bindings (NOT terminate — `destroy/2` owns that; §5). `Workspace.create/2` becomes a
thin caller of the create entry (authorized).

### 3.7 User Template Class — explicit ordering + rollback (E-1)

`Ezagent.Template.User` (identity domain). `template_data`: `username`, `initial_caps`,
`default_workspace`, `default_agent_spec`. **Ordering (each step rolls back the prior on
failure):**

1. Persist the user row (`Users.create/3`) with `caps_json = default_caps ++ initial_caps`
   **including the user's self manage-cap** — so self-ownership is durable from row
   creation, before any Kind exists (avoids "grant a cap on a Kind that isn't live yet").
   Rollback: delete row.
2. Spawn/hydrate the User Kind (`ever_created` → fresh). Rollback: terminate + delete row.
3. Grant the **admin/registrar** manage-cap on the user via dispatch to the registrar's
   identity (the core §3.3 grant, `created_by` = registrar). Rollback: revoke.
4. Create the `<username>-default` agent **via the same create entry** (nested). Rollback:
   teardown the agent.

manage-cap recipients (Allen-approved): the user (self, step 1) + the creating
admin/registrar (step 3). `Entity.ensure_spawned/1` (login) is a rehydrate → no re-grant.

**Nested-create ordering note:** the default-agent create (step 4) recurses through the
entry but is NOT mutually recursive (a user does not require an agent to exist first;
the agent's `created_by` is the just-created user or the registrar). No bootstrap cycle.

### 3.8 Converging ad-hoc paths + bridge existence predicate (G-2)

| Path | After |
|---|---|
| agent-bridge join (`channel.ex:146`) | Call the **same `exists_durably?(uri)` predicate** (§3.1) before spawn: `true` (durable create marker / row exists, but not live) → rehydrate via `SpawnRegistry.spawn` (legitimate); `false` (never created) → `{:error, :agent_not_created}` (no silent fresh create). For Agents `exists_durably?` = `KindSnapshot.ever_created?/1` (a pre-spawn `Repo.get`, `kind_snapshot.ex:182`). Predicate is "durably exists", NOT "currently live". |
| `Workspace.create/2` | dispatch the create entry (Workspace Template), authorized |
| plugin Class `instantiate/3` | unchanged Class code; core grant via `ctx.caller` + `ever_created` |
| `Agent.spawn_fresh` / `spawn_from_template_content` | route through the entry; lineage stays (orthogonal) |
| boot Loader / BootReconciler / login | rehydrate — unchanged, `ever_created` already set → no grant |
| mix tasks / seeds | route through the entry (operator principal); low priority |

## 4. Data flow

**Create:** caller → dispatch `kind.create` (CapBAC create cap) → resolve Class →
`validate/1` → `instantiate/3` (threading `created_by`=`ctx.caller`) → if the atomic
create returned `:created` (§3.1) grant `cap(:<kind>, Manage, :any, uri)` to `created_by`
→ return uris. On post-spawn failure →
Class teardown (§5).

**Modify:** caller → dispatch `manage.reconfigure` (cap `cap(:<kind>, Manage, :any,
instance)`; Session also owner-checked) → `validate/1` → Class `reconfigure/4` effects on
the live Kind → (if sidecar) `ensure_subprocess_alive/2`.

**Delete:** `manage.delete` → Class teardown → Lifecycle `destroy/2`.

**Rehydrate:** `SpawnRegistry.spawn(uri)` → `load_or_init` finds row → rehydrate, no grant.

## 5. Teardown / rollback contract (G-1)

Each Template Class declares a teardown — `@callback teardown(uri, data, ctx) :: :ok |
{:error, term()}` — that undoes **only the durable side-effects its `instantiate` created
OUTSIDE the engine's own boundary**: domain rows (`workspaces`/`users`), granted caps,
workspace/MCP bindings, external sidecars. It MUST NOT terminate the Kind or delete the
snapshot — those belong to the engine (codex G-1).

Termination + snapshot deletion + the developer destroy hook drain are owned by
Lifecycle `destroy/2` (`lifecycle.ex:554-570`, `server.ex:540-583`). Class teardown
**composes** with it; it does not duplicate or bypass it. Used by:
- **Create-failure rollback** (after a fresh spawn fails at/after grant): run the Class
  teardown (undo durables) **then** `destroy/2` (terminate + delete snapshot). Mirrors
  `rollback_session/3`'s explicit reversal (`ezagent_domain_chat.ex:871`), generalized
  per-Class + delegating termination to the engine.
- **`manage.delete`**: Class teardown (undo durables) **then** `destroy/2`.

Teardown is best-effort + idempotent (double-teardown-safe); failures are logged and the
original create error surfaces. The grant is the LAST create step, so a grant failure has
only the spawn + Class durables to undo.

## 6. Testing / CI invariants

- **Single authorized create path:** strengthen `agent_create_single_path_test.exs` to
  detect **variable-argument** `SpawnRegistry.spawn`/`Kind.spawn` fresh-create calls
  across ALL schemes (`session://`/`workspace://`/`entity://user`/`template://`);
  allowlist only the engine + rehydrate sites; the bridge join must NOT be allowlisted as
  a create.
- **Grant-at-create:** a freshly created Agent/Workspace/User carries
  `cap(:<kind>, Manage, :any, self)` for `created_by`; rehydrate does NOT re-grant or
  duplicate.
- **Template Class + Manage coverage:** every Kind type has a registered Template Class
  and `Behavior.Manage` registered (`CapabilityRegistry`).
- **Reconfigure preserves identity + state:** `manage.reconfigure` keeps the URI and a
  representative runtime-state field (Session members; Agent conversation/PTY-alive).
- **Manage authz:** non-owner without the manage-cap is denied `:reconfigure`/`:delete`;
  for Session, a non-owner workspace member is denied (encodes the OQ-4 decision).
- **No external forge of `created_by`:** `created_by` is `ctx.caller` (authenticated);
  `template_data` cannot carry it.

## 7. Out of scope (this spec)

Routing-row edit authz (team-routing follow-up); `manage.transfer`; versioned templates;
narrowing the default user `:session` cap (unless OQ-4 chooses it).

## 8. Decisions (Allen-approved 2026-06-01)

1. **D1:** Template concept for ALL Kinds; unified create chokepoint (BUILT here).
2. **D2:** Modify = lifecycle-consistent re-materialization preserving identity + state
   (NOT destroy+recreate) — realized as the new `reconfigure/4` Class hook (§3.5).
3. **Manage surface:** dedicated `Ezagent.Behavior.Manage` on every Kind; manage-cap =
   `cap(:<kind>, Manage, :any, instance)` (`:any` action — C-1).
4. **User manage-cap recipients:** user (self, in `caps_json` at row create) + creating
   admin/registrar.
5. **Grant location:** core create step, gated by the atomic `ever_created`
   `false→true` (`:created`) transition surfaced from the create path (§3.1), using
   `created_by` = `ctx.caller` threaded as a create arg (plugin Classes unchanged).

## 9. Open questions

- **OQ-1:** Does `kind.create` reuse existing per-scope create caps
  (`workspace.create_agent` etc.) as its authz, or get a dedicated create-cap? (Lean:
  reuse; the entry is the dispatch surface, the cap is per-scope.)
- **OQ-2 (F-1):** Migration of pre-existing Kinds with no manage-cap → a **one-shot
  migration** deriving owners from durable tables (Session `owner_uri`; Agent
  lineage/`creator_uri`; Workspace — no owner field, needs a chosen default e.g.
  bootstrap-admin or `:no_owner`) with explicit "no owner found" handling. NOT
  activate-backfill (`activate/2` only reconciles a Kind's own slice; the cap lives on
  the owner's identity — F-1).
- **OQ-3:** Per-Kind immutable identity fields (username, workspace name) — rejected by
  `validate`/`reconfigure`.
- **OQ-4 (C-1) — Allen:** Session-manage authority: retain `owner_uri`/admin gate (lean)
  vs narrow the default user `:session` wildcard.
