# Unified Kind Creation via Templates — Design (rev 2)

**Date:** 2026-06-01
**Status:** Draft rev 2 (codex adversarial review folded in; pending re-review + Allen approval)
**Author:** Claude (with Allen)

> **rev 2 changes** (codex review of rev 1): the unified authorized create entry
> does **not** exist today and must be BUILT (B-1); freshness comes from the
> CORE `ever_created` signal, not a Class's optional `fresh?` meta (A-1); the
> manage-cap is `action: :any` scoped to `Behavior.Manage` + instance (C-1) with an
> explicit Session caveat; `reconfigure` is a NEW per-Class hook, not "rerun
> instantiate" (D-1); a per-Class teardown/rollback contract is defined (G-1); plus
> bridge-join existence predicate (G-2), User create ordering (E-1), one-shot
> migration (F-1).

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

### 3.1 Freshness is a CORE signal, not a Class return (A-1)

`Ezagent.Kind.Template.instantiate/3` MAY return `{:ok, uris}` (2-tuple) or
`{:ok, uris, %{fresh?: bool}}` — the 2-tuple is explicitly valid and
`GenericSession.instantiate/3` (`generic_session.ex:99`) returns it with no signal. So
the manage-cap grant must NOT depend on the Class's `fresh?`.

**Authoritative freshness lives in core:** `Kind.Server.init/1` + `Snapshot.load_or_init`
already decide create-vs-rehydrate, and the Lifecycle `create/1` hook fires exactly once
per URI, gated by the durable `ever_created` marker written atomically with the first
snapshot (`server.ex:185-222`, `snapshot.ex:341-352`). The grant keys off **that** —
i.e. the create entry asks core "was this instance freshly created in THIS call?" via
the `ever_created` transition, independent of any Class return shape.

### 3.2 The unified authorized create entry (BUILD) (B-1)

Introduce one dispatched create surface that every Kind's creation flows through.
Concretely:

- A create action — `kind.create` (carried on a core/domain create behavior, or the
  generalized `Ezagent.Behavior.Template`) — dispatched against the **scope** that owns
  the new Kind (workspace for agents/sessions/users; system/bootstrap for workspaces),
  so `Kind.Runtime` step 5.5 CapBAC runs and `ctx.caller` is the authenticated
  `created_by`. Authorization reuses the existing per-scope create caps (OQ-1) — this
  work does not widen WHO may create, it makes the authz uniform + unavoidable.
- The handler: resolve the target Template Class → `validate/1` → `instantiate/3` →
  observe the CORE `ever_created` transition (§3.1) → on fresh, run the grant (§3.3);
  on any failure after a fresh spawn, run the Class teardown (§5/G-1).
- **Migration of existing create paths onto the entry** (the bulk of the work):
  `create_session/3`, `Workspace.create/2`, `create_user`, the Loader fresh-create
  branch, `Agent.spawn_fresh/4` / `spawn_from_template_content/4`, and the plugin Class
  spawns become callers of (or are replaced by) this entry, each supplying a real
  `created_by`. Boot/login/bridge **rehydrate** stays on `SpawnRegistry.spawn` (no
  ctx.caller needed — no grant on rehydrate).

`Kind.spawn/2` remains the mechanical primitive for rehydrate; **fresh creation outside
the entry is a CI failure** (§6).

### 3.3 Manage-cap grant — CORE step, `:any` action, Session caveat (A-1, C-1)

After a fresh create (§3.1 signal), the core handler grants, for each freshly created
owned Kind URI:

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
undefined and would hit `put_new` `{:already_started}`. So this spec **adds** an
**optional** Template Class callback:

```
@callback reconfigure(uri :: URI.t(), old_data :: map(), new_data :: map(), ctx) ::
            {:ok, [effect]} | {:error, term()}
```

- `validate/1` runs on `new_data` first.
- `reconfigure/4` returns **Lifecycle effects** (`{:set, :state_key, v}` for the durable
  spec, `{:set_transient, …}`, dispatches for re-bind/re-grant/route reconcile) applied
  to the LIVE Kind — same URI, same identity, runtime `transients` untouched except where
  the Class explicitly restarts them.
- Sidecar-bearing Classes (cc PTY, np) relaunch the subprocess against the new config via
  the existing `ensure_subprocess_alive/2` hook (GLOSSARY §128), preserving conversation
  state (durable `state` persists; `transients` rebuilt by `activate/2`).
- A Class without `reconfigure/4` → `manage.reconfigure` returns
  `{:error, :reconfigure_unsupported}` (immutable Kind). Immutable identity fields
  (username, workspace name) are rejected by the Class `validate`/`reconfigure` (OQ-3).

This is a small, well-bounded Lifecycle addition — NOT "rerun instantiate".

### 3.6 Workspace Template Class (proposed)

`Ezagent.Template.Workspace` (workspace domain). `template_data`: `name`, `owner`
(defaults to `created_by`), `default_agent_template` (seeds `<username>-default`),
optional `default_caps_policy`. `instantiate/3` = `Workspace.Store.create/2` +
`Kind.spawn(Workspace)`; teardown = delete the workspace row + terminate the Kind.
`Workspace.create/2` becomes a thin caller of the create entry (authorized).

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
| agent-bridge join (`channel.ex:146`) | **Existence predicate before spawn**: if a durable snapshot/provenance row exists for the agent URI → rehydrate via `SpawnRegistry.spawn` (legitimate); if it was **never created** → `{:error, :agent_not_created}` (no silent fresh create). The predicate is "durable create marker exists" (the `ever_created`/snapshot row), NOT "currently live". |
| `Workspace.create/2` | dispatch the create entry (Workspace Template), authorized |
| plugin Class `instantiate/3` | unchanged Class code; core grant via `ctx.caller` + `ever_created` |
| `Agent.spawn_fresh` / `spawn_from_template_content` | route through the entry; lineage stays (orthogonal) |
| boot Loader / BootReconciler / login | rehydrate — unchanged, `ever_created` already set → no grant |
| mix tasks / seeds | route through the entry (operator principal); low priority |

## 4. Data flow

**Create:** caller → dispatch `kind.create` (CapBAC create cap) → resolve Class →
`validate/1` → `instantiate/3` → core observes `ever_created` fresh transition → grant
`cap(:<kind>, Manage, :any, uri)` to `ctx.caller` → return uris. On post-spawn failure →
Class teardown (§5).

**Modify:** caller → dispatch `manage.reconfigure` (cap `cap(:<kind>, Manage, :any,
instance)`; Session also owner-checked) → `validate/1` → Class `reconfigure/4` effects on
the live Kind → (if sidecar) `ensure_subprocess_alive/2`.

**Delete:** `manage.delete` → Class teardown → Lifecycle `destroy/2`.

**Rehydrate:** `SpawnRegistry.spawn(uri)` → `load_or_init` finds row → rehydrate, no grant.

## 5. Teardown / rollback contract (G-1)

Each Template Class declares a teardown — `@callback teardown(uri, data, ctx) :: :ok |
{:error, term()}` — enumerating what its `instantiate` made durable (rows, snapshots,
caps, bindings, sidecars) and how to undo it. Used by:
- **Create-failure rollback** (after a fresh spawn, before/at grant): the create entry
  calls the Class teardown (mirrors `rollback_session/3`'s explicit reversal,
  `ezagent_domain_chat.ex:871`, generalized per-Class).
- **`manage.delete`**: the same teardown, then Lifecycle `destroy/2`.

Failures during teardown are best-effort + logged; the original create error surfaces
(idempotent, double-teardown-safe). The grant itself is the LAST create step so a grant
failure only has the spawn + Class durables to undo.

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
5. **Grant location:** core create-entry step keyed off the `ever_created` signal +
   `ctx.caller` (plugin Classes unchanged).

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
