# SPEC — F7: operator REMOVE session member + DELETE session, CapBAC-clean

**Status:** DESIGN (not implementation).
**Branch:** `docs/f7-remove-delete-spec` (off `origin/main`, do NOT merge).
**Scope:** authority model + remove-member design + delete-session cascade + UI re-instatement + security. No code lands from this doc.

---

## 0. Naming reconciliation (read first)

The work item is tracked as **"F7"** in the #1027 QA-fix stream. In the ESR
field-blocker ledger (`docs/together/2026-06-24/evidence/blockers.md`) the two
underlying product gaps carry different IDs:

- **F20** — *无操作员 UI 移除 session 成员* — "no operator path to remove a
  session member." `remove_member` exists ONLY as an orchestrator MCP tool
  (`tools.ex`, agent-driven); operators have no dispatch entry.
- **F21** — *无 session 删除/归档* — "no session delete." `world` UI has
  `session.create` but no `session.delete`; the backend has no operator delete
  path (only the rollback-internal `delete_session_rule_rows`).

`blockers.md`'s own "F7" is an unrelated codex-TUI-crash blocker. **In this SPEC,
"F7" = the QA-fix bundle of F20 (remove-member) + F21 (delete-session)**, the two
controls the QA-fix subagent pulled because both hit a CapBAC wall. The spec
addresses F20 + F21.

---

## 1. The problem, stated against the real code

### 1.1 remove_member hits the `{:spawned_by}` (cap #2) wall

`Ezagent.Orchestrator.Tools.remove_member/2`
(`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`) is the only
implementation of member removal. Its inner step
`do_remove_member/4 → terminate_worker/3` dispatches
`?action=sandbox.destroy` on the member worker. That dispatch is CapBAC-gated by

> **Cap #2** `{:spawned_by, orchestrator}` (`Ezagent.Behavior.Terminable`
> / `Ezagent.Behavior.Sandbox` — `required_caps[:terminate]` /
> `[:destroy]` = `cap(:agent, …, …)`, matched via the durable
> `Ezagent.AgentLineage` `agent_uri → spawned_by` table).

An operator does NOT hold `{:spawned_by, orchestrator}`. The only sanctioned path
that *does* run `remove_member` is `Ezagent.Session.SessionManager.run_tool/4`
(`apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex`), gated at
**step 0** by an unforgeable **bridge token** that ONLY the orchestrator agent's
cc transport possesses (Transport Decision C). SessionManager then **reconstructs
the orchestrator's delegated caps session-side**
(`load_orchestrator_caps/1 → Ezagent.Identity.list_caps_for(orchestrator_uri)`)
and runs the tool under those.

So today an operator literally cannot reach `remove_member`: they hold neither
cap #2 nor the bridge token. Wiring an operator past the bridge-token gate, or
minting them a `{:spawned_by}` cap they did not earn, is a **#154 violation**
(every cap must have a real granter; no unowned/forged caps; no bridge bypass).

### 1.2 delete_session: `manage.delete` works but does NOT cascade

`Ezagent.Behavior.Manage` (`apps/ezagent_core/lib/ezagent/behavior/manage.ex`)
gives every Kind a `:delete` action gated by the creator's manage-cap
`cap(:<kind>, Manage, :any, <instance>, <ws>)`. The **session owner already holds
this cap** for the session (granted at create — §3.3). `manage.delete` →
`Ezagent.Lifecycle.destroy/2` → the Session Kind's **`destroy/2` Lifecycle hook**
(`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex`).

But that hook does ONLY ONE thing:

```elixir
def destroy(_reason, ctx) do
  wc = ConfigActions.template_working_copy(ctx[:state] || %{})
  case Map.get(wc, :orchestrator_uri) do
    %URI{} = orchestrator_uri -> _ = Ezagent.Session.SessionManager.stop(orchestrator_uri); :ok
    _ -> :ok
  end
end
```

It stops the **SessionManager executor**. It does NOT:

- terminate orchestrator-spawned **member workers** (their Kind processes survive);
- GC their **config dirs** (the FS cleanup that lives in `Sandbox.handle_destroy`
  / the `destroy_config_dir` hook);
- prune the session's **routing rows** (`MentionRouting` rows stamped
  `created_by == session_uri`);
- terminate the **orchestrator agent itself** + its config dir.

Result: deleting a session silently **orphans worker processes + config dirs +
routing rows** — the exact silent-leak the QA targeted, and the exact accumulation
F21 calls out (junk `bug-*`/`test-*`/`mult-agent` sessions that "只能建不能删").
A naive cascade re-hits the cap #2 wall (terminating each worker needs cap #2).

---

## 2. Authority model — the chosen, #154-clean path

### 2.1 Two layers: outer accountability gate, inner mechanism

The clean design separates **who is allowed to ask** (an owner/admin-rooted cap,
the accountability gate) from **what authority actually terminates the worker**
(the orchestrator's own reconstructed cap #2). The operator never holds cap #2;
the cap stays where it belongs (on the orchestrator). This is the SessionManager
step-2 mechanism, re-triggered from a **parallel cap-gated entry** instead of the
bridge-token entry.

```
operator (LV)                  session domain                       worker Kind
─────────────                  ──────────────                       ───────────
remove_member ──dispatch──►  Behavior.Session :remove_member  ──reconstruct──►
  ctx.caller = operator       (NEW cap-gated action)              orchestrator caps
  ctx.caps   = operator caps  CapBAC checks operator's            (Identity.list_caps_for)
                              owner-rooted cap HERE                      │
                                     │                          terminate_worker/3
                                     ▼                          dispatch sandbox.destroy
                              Tools.remove_member(... caps:            under cap #2  ✓
                                reconstructed orch caps)         (orchestrator's own)
```

**Why this is #154-clean.**

1. **The entry cap has a real granter.** It is granted at session-create by the
   session-creation entry, `granted_by: owner_uri` (mirrors the existing
   `OrchestratorAdmin :restart` and `Manage :any` grants — §3.3). No
   `:plugin_declared`, no self-grant, no unowned cap.
2. **Cap #2 is never spread.** `{:spawned_by, orchestrator}` is reconstructed
   *transiently, session-side*, from the orchestrator's own durable identity
   slice — the SAME read SessionManager already performs. It is never granted to
   the operator and never persisted onto a new principal.
3. **No bridge-token bypass.** The operator authenticates via their owner/admin
   cap **at the dispatch chokepoint** (CapBAC step 5.5), NOT via the bridge token.
   The bridge token authenticates the orchestrator's *transport*; this is a
   *separate authority* on a *separate entry*. The post-auth mechanism
   (reconstruct-then-run) is identical, but the front-door check is a real cap,
   not a forwarded secret. (Codex will probe this — see §6.)
4. **Fail-closed.** Missing entry cap → `{:error, :unauthorized}` before any
   reconstruction or termination.

### 2.2 Why NOT the rejected alternatives

| Option | Verdict | Why |
|---|---|---|
| Mint operator a `{:spawned_by, orchestrator}` cap | ❌ | Unowned/forged authority — the operator did not spawn the worker. #154 violation, and it would let the operator terminate ANY of the orchestrator's workers in ANY session. |
| Wire operator past the bridge-token `run_tool` gate | ❌ | Bridge-token bypass; the token is the orchestrator transport's credential. Hands operator-driven dispatch a credential that authenticates as the orchestrator. |
| Run the inner terminate "under the session OWNER's authority" (the `repair_orchestrator` pattern) | ❌ | **The owner does NOT hold cap #2.** Owner holds Manage-over-session, Manage-over-orchestrator, OrchestratorAdmin:restart — none authorizes `sandbox.destroy` on a worker. `repair_orchestrator`'s "effective owner" pattern works for orchestrator *spawn* (template-instantiate authority), NOT worker *terminate*. This is the trap; it re-hits the cap #2 wall. |
| operator→orchestrator **live delegated request** (ask the running orchestrator agent to call its own `remove_member`) | ⚠️ partial | Genuinely #154-clean WHEN the orchestrator is alive — the cap stays on the orchestrator and it acts on its own authority. BUT it (a) requires a live, responsive orchestrator (fails for the crashed-codex / F7 scenario), and (b) needs an inbound operator→agent command channel that does not exist as a clean dispatch action. **Rejected as the primary path** for fragility; the chosen reconstruct-side mechanism gives the same cap-locality guarantee without a live-agent round-trip. (Reconsider only if reconstruction proves unviable — see open question OQ-1.) |
| New operator-scoped `:remove_member` cap granted at create + bolt member-removal onto `Manage` | ⚠️ | A new owner-rooted cap is correct (§2.1 outer layer). But member-removal is NOT a Manage action (Manage = `:delete`/`:reconfigure` on the instance ITSELF, not "remove a child of it"). Bolting it onto Manage over-broadens Manage. Use a dedicated cap on the Session Behavior instead (§3.1). |

### 2.3 The entry cap shape

A new cap-only authority anchoring **operator/owner authority to manage session
membership + lifecycle**, modeled exactly on `Ezagent.Behavior.OrchestratorAdmin`
(`apps/ezagent_domain_session/lib/ezagent/behavior/orchestrator_admin.ex` — a
cap-only Behavior, owner-rooted, granted at create, `granted_by: owner`).

Two clean realizations are on the table; **the SPEC recommends realization (A)**:

**(A) — extend `Behavior.Session` with cap-gated `:remove_member` (recommended).**
Add a `:remove_member` action to `Ezagent.Behavior.Session` with
`required_caps[:remove_member] = cap(:session, Behavior.Session, :remove_member)`.
Granted at create to the owner as
`cap(:session, Behavior.Session, :remove_member, <session_uri>, <ws>)`,
`granted_by: owner_uri`. For delete, **reuse the existing owner
`cap(:session, Manage, :any, <session_uri>, <ws>)` → `manage.delete`** (this IS
the "reconcile with manage.delete" the task asks for — §3.2). This keeps one new
cap (member removal) and reuses the existing manage-cap for delete.

**(B) — a dedicated cap-only `Behavior.SessionMemberAdmin`** with `:remove` (and
optionally `:delete`) actions, sibling to `OrchestratorAdmin`. Cleaner separation,
but adds a whole Behavior + registration; the delete half still reconciles to
`manage.delete`. Use (B) only if §3.1's host-action analysis shows
`Behavior.Session` is the wrong home.

Either way: **owner-rooted, granted-at-create, real granter, session-scoped,
admin-superset** (the bootstrap admin's all-`:any` cap satisfies it — operators
who are workspace/system admins inherit it; non-admin session owners get it by the
create-time grant).

---

## 3. Design — Remove member

### 3.1 New cap-gated dispatch action `session.remove_member`

On `Ezagent.Behavior.Session`:

```elixir
action(:remove_member,
  args: %{role_name: :string},          # OR member: :uri — see note
  returns: %{status: :atom, deleted_rules: :integer, repointed_rules: :integer},
  caps: [:remove_member],
  modes: [:call])

def required_caps, do: %{... , remove_member: cap(:session, __MODULE__, :remove_member)}
```

`data_owner/1` already resolves to the session's `:owner_uri`
(`Behavior.Session.data_owner(%URI{scheme: "session"})`), so the cap's
data-ownership story matches the existing Chat caps.

**Arg shape:** prefer `role_name` (the stable per-session binding `remove_member`
already keys on) to match `Tools.remove_member/2`. Accept `member` URI as an
alternative for non-orchestrated members (a plain invited user/agent has no
`role_name`). The handler resolves whichever is supplied to a concrete
`member_uri` via `Session.role_name_to_uri/2` / the members slice.

### 3.2 The handler reconstructs orchestrator caps for the inner terminate

`handle_remove_member/2` (runs inside the Session Kind process, where the
`:members` slice is directly readable):

1. **CapBAC already passed** at the dispatch chokepoint — the operator held the
   owner-rooted `:remove_member` cap (or admin all-caps). No second check here.
2. Resolve `member_uri` from `role_name`/`member`.
3. **Branch on member provenance:**
   - **Orchestrator-spawned worker** (member has a `source_template_uri` facet
     and/or `AgentLineage.lookup(member_uri) == {:ok, orchestrator_uri}`):
     reconstruct the orchestrator's caps
     (`Ezagent.Identity.list_caps_for(orchestrator_uri)` — the durable identity
     read; §3.4 covers the dead-orchestrator case) and call the **existing,
     tested** `Ezagent.Orchestrator.Tools.remove_member/2` with
     `caller: orchestrator_uri, caps: <reconstructed>, session_uri:, workspace_uri:`.
     This reuses terminate-worker (cap #2 ✓) + prune-routing (`created_by ==
     session_uri`) + leave-member verbatim — no new termination logic, no cap #2
     spread.
   - **Plain invited member** (a user/agent NOT spawned by the orchestrator, e.g.
     an `add_participant` human or self-joined viewer): the orchestrator never
     owned its lifecycle, so there is no worker to terminate under cap #2. Just
     dispatch `session.leave` (the existing `:leave` action) to drop membership.
     Do NOT terminate the entity (an invited human's User Kind is not ours to
     destroy). Prune routing rows that named it (scoped `created_by ==
     session_uri`), same as the worker path.
4. **Forget lineage for a terminated worker.** `Tools.remove_member` /
   `terminate_worker` does NOT call `Ezagent.AgentLineage.forget/1` today, so a
   removed worker leaves a stale `agent_uri → spawned_by` row. The
   delete-cascade already forgets lineage (§4.2 step 6); the remove-member path
   must do the same after a successful worker terminate, so a re-add at the same
   member URI starts clean (mirrors `rollback.ex compensate_spawned_members/1`,
   which forgets lineage per torn-down member). The plain-invited-member branch
   has no lineage row to forget. *(Codex Q5 — addressed.)*
5. Return `{:ok, %{status: :removed, deleted_rules:, repointed_rules:}}` /
   `{:ok, :already_removed}` / `{:error, reason}` — the `Tools.remove_member`
   contract, surfaced to the operator UI.

**Why the handler (not the LV) reconstructs:** the reconstruction is a privileged
identity read that must run inside the session domain (it is the SessionManager
step-2 pattern). Putting it behind a cap-gated Session action means BOTH the
operator UI AND any future caller get the same gated, reconstruct-then-run
mechanism, and CapBAC is enforced once at the dispatch chokepoint.

### 3.3 Where the entry cap is granted (real granter)

At session creation, alongside the two existing owner grants in
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex`:

- `grant_owner_orchestrator_admin_cap/…` → `OrchestratorAdmin :restart`,
  `granted_by: owner`.
- `grant_owner_orchestrator_manage_cap/…` → `Manage :any` over the orchestrator,
  `granted_by: owner`.

Add a third: `grant_owner_session_member_admin_cap/2` →
`cap(:session, Behavior.Session, :remove_member, <session_uri>, <ws>)`,
`granted_by: owner_uri`, via the same idempotent grant chokepoint
(`Ezagent.Identity.Grant.grant_cap/3`). The owner already gets
`cap(:session, Manage, :any, <session_uri>)` (the create-entry creator grant from
`Ezagent.CreatorGrant.manage_cap/4`) which covers `manage.delete` — no new grant
needed for delete.

This puts both new authorities on the SAME footing as the existing owner caps:
real granter (the owner), session-scoped, idempotent re-grant, admin-superset.

---

## 4. Design — Delete session (cascade)

### 4.1 The cascade must be a shared function, NOT only in the UI handler

The QA's invariant is **"no silent orphan on delete, via ANY delete path."** If
the cascade lives only in the operator `delete_session` LV handler, a
`manage.delete` from any other caller (tests, future tooling, an admin CLI) still
orphans. Therefore:

> **Put the cascade in ONE shared function** —
> `Ezagent.Session.Lifecycle.cascade_teardown/1` (working name) — called by BOTH:
> 1. the operator `delete_session` entry (so it can return per-worker
>    failures to the operator), AND
> 2. the Session Kind's **`destroy/2` Lifecycle hook** (the structural safety net
>    — every delete path, including a bare `manage.delete`, cascades).

The `destroy/2` hook runs **while the Kind is still LIVE** (the moduledoc and
existing code confirm `ctx[:state]` / the `:members` slice are readable there), so
the cascade can enumerate members from the live slice before the process is torn
down. The hook is best-effort + idempotent (already-gone members are no-ops).

### 4.2 What the cascade does (in order, while session still live)

`cascade_teardown(session_uri)`:

1. **Read the live members slice** + the durable working copy
   (`orchestrator_uri`, `owner_uri`).
2. **Terminate every orchestrator-spawned member worker** + GC its config dir.
   - Preferred (alive orchestrator): reconstruct orchestrator caps and call
     `Tools.terminate_worker(member_uri, orchestrator_uri, caps)` per worker —
     dispatches `sandbox.destroy`, whose handler (`Sandbox.handle_destroy`) runs
     `invoke_destroy_config_dir/3` (the FS GC) AND schedules termination. **Use
     `sandbox.destroy`, NOT bare `lifecycle.terminate`** — only `sandbox.destroy`
     runs `destroy_config_dir` (verified in `behavior/sandbox.ex`); a bare
     terminate kills the process but leaks the config dir.
   - Fallback (dead orchestrator — §4.4): `Ezagent.Lifecycle.destroy(member_uri,
     :session_delete)`, the VM-internal trusted primitive the **rollback path
     already uses** (`session_creator/rollback.ex` `compensate_spawned_members/1`).
     `Lifecycle.destroy/2` runs the developer destroy hooks — for an Agent the
     `Sandbox` destroy HOOK does the same config-dir cleanup — then clears the
     durable marker + terminates. This is the same trusted teardown rollback
     uses; it is NOT an operator-forged cap.
3. **Terminate the orchestrator agent itself** + GC its config dir. The owner
   holds `cap(:agent, Manage, :any, orchestrator_uri)` (the
   `grant_owner_orchestrator_manage_cap` grant), so for the operator entry this
   can dispatch `manage.delete` / `sandbox.destroy` on the orchestrator under the
   operator's-→reconstructed authority; the `destroy/2` safety-net path uses
   `Lifecycle.destroy(orchestrator_uri, …)`.
4. **Prune ALL session routing rows.** Reuse the rollback primitive shape:
   delete every `MentionRouting` row with `created_by == session_uri`
   (`force: true`) then `load_into_registry/1` — identical to
   `rollback.ex delete_session_rule_rows/1`. (The per-member prune in
   `Tools.remove_member` only removes rows naming THAT member; delete must remove
   the whole session's rule-set.)
5. **Stop the SessionManager executor** (the one thing the current `destroy/2`
   already does) — keep it.
6. **Forget lineage** for terminated workers + the orchestrator
   (`AgentLineage.forget/1`, as rollback does) so a same-URI recreate is clean.

Steps 2–6 are each `safe/1`-wrapped (best-effort, log on failure) on the
`destroy/2` safety-net path; on the operator entry path, per-worker failures are
COLLECTED and returned so the operator sees "session deleted, but worker X
config-dir cleanup failed" rather than a false success (Invariant #9, no silent
drop).

### 4.3 Reconcile with `manage.delete`

The operator delete entry is just `manage.delete` on the session URI, gated by the
owner's existing `cap(:session, Manage, :any, <session_uri>)`. The ONLY change is
that `Behavior.Session.destroy/2` (which `manage.delete` ultimately triggers via
`Lifecycle.destroy`) now calls `cascade_teardown/1` BEFORE stopping the
SessionManager. So:

- **No new delete cap** — `manage.delete` + the existing owner manage-cap is the
  authority.
- **The cascade rides the existing `destroy/2` hook** — every `manage.delete`
  (operator, admin, test) cascades by construction.
- The operator LV entry calls `cascade_teardown/1` directly first (to collect +
  surface per-worker results), then `manage.delete`; `destroy/2`'s own
  `cascade_teardown/1` call is idempotent, so the double-call is safe (already-gone
  workers are no-ops).

### 4.4 Dead / crashed orchestrator — the F7-critical case (OPEN, but designed)

This is **not cosmetic**: F21's whole use case is deleting accumulated junk
sessions, and F7's headline bug is a **codex orchestrator that crashed
(SIGABRT)**. If the orchestrator is dead:

- `Ezagent.Identity.list_caps_for(orchestrator_uri)` returns **`MapSet.new()`**
  (verified: `Identity.list_caps_for/1` does `KindRegistry.lookup` → `:error` →
  empty set; it requires a LIVE orchestrator Kind). So **cap reconstruction
  yields nothing** → the dispatch-based `sandbox.destroy` would fail closed →
  workers would NOT be cleaned up → the leak persists in exactly the scenario
  this targets.
- **Designed fallback:** when reconstruction yields an empty/cap-#2-absent set
  (dead orchestrator), the cascade falls back to the **VM-internal trusted
  `Ezagent.Lifecycle.destroy/2`** primitive per worker — the SAME path
  `rollback.ex compensate_spawned_members/1` uses to tear down half-spawned
  members. This is legitimate: it is not an operator-forged cap; it is the
  framework's internal teardown primitive, reached only after the operator's
  owner/admin cap authorized the delete at the chokepoint. The member workers are
  enumerable from the (still-live) Session's `:members` slice independent of the
  orchestrator's liveness.
- This keeps delete working when the orchestrator is down — which is precisely
  when an operator most needs to delete the broken session.

See OQ-1 / OQ-2 for the residual questions.

---

## 5. UI re-instatement (the controls the QA pulled)

Backend-first; the UI is re-added only once §3 + §4 land. Two thin additions to
the world plugin, mirroring the existing `session.invite` / `session.create`
dispatch handlers in
`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`:

### 5.1 Remove-member control (F20)

- **React:** the conversation members panel (today `onInvite` only) gains a
  per-member remove (✕) control, shown only when the viewer holds the
  `:remove_member` cap (cap-gated render, mirroring how `OrchestratorHealthCard`
  gates the Restart button on `OrchestratorAdmin :restart`).
- **LV:** add `"session.member.remove"` to `@conversation_actions`
  (`world_live.ex:236`) + a `handle_dispatch(socket, "session.member.remove",
  %{"session_uri" => sid, "member" => m})` clause that dispatches
  `?action=session.remove_member` with `ctx: %{caller: operator, caps:
  operator_caps}` (the operator's real caps — CapBAC checks the owner-rooted
  `:remove_member` cap at the chokepoint). On success, `push_members/1` to refresh
  the panel; on `{:error, :unauthorized}` show the error status.

### 5.2 Delete-session control (F21)

- **React:** the sessions table / conversation header gains a Delete control
  (with confirm), cap-gated on the owner manage-cap.
- **LV:** add `"session.delete"` to `@conversation_actions` + a clause that
  (a) calls `cascade_teardown/1` to collect per-worker results, then
  (b) dispatches `?action=manage.delete` on the session URI under the operator's
  caps. Surface partial-failure results via the same `world:state` error channel
  `session.create` already uses (no silent drop — Invariant #9). On full success,
  `push_patch` away from the deleted session's deep-link.

No new auth in the LV layer — both clauses pass the operator's real caps and let
the dispatch chokepoint decide. This matches the existing `send_message` /
`invite_member` handlers (which forward `socket.assigns.current_caps`).

---

## 6. Security analysis

| Concern | Mitigation |
|---|---|
| **Unowned cap** | The new `:remove_member` cap is `granted_by: owner_uri` at create (§3.3), idempotent, via the `Identity.Grant.grant_cap` chokepoint — identical provenance to the existing `OrchestratorAdmin` / `Manage` owner grants. Cap #2 is reconstructed transiently, never granted to the operator. No `:plugin_declared`, no self-grant. |
| **Bridge-token bypass** | The operator path is a SEPARATE cap-gated dispatch entry (`session.remove_member` / `manage.delete`), authenticated by the operator's owner/admin cap at CapBAC step 5.5 — NOT by the bridge token. The bridge token remains the orchestrator transport's credential, used ONLY on the `run_tool` entry. The two entries share the reconstruct-then-run *mechanism* but have distinct front-door authorities. |
| **Cross-session / cross-member blast radius** | The `:remove_member` cap is `instance: <session_uri>`, so it authorizes removal ONLY in that session. The inner `Tools.remove_member` prune is already scoped `created_by == session_uri` (B2 codex blocker fix), so a same-named member URI referenced by another session's rules is untouched. The reconstructed cap #2 is the orchestrator's own, so it terminates only workers THAT orchestrator spawned. |
| **Terminating a non-worker (invited human)** | §3.2 branches: a plain invited member is dropped via `session.leave` only — its entity is NEVER destroyed. Only orchestrator-spawned workers (provenance-confirmed via `AgentLineage`/`source_template_uri` facet) are terminated. |
| **Fail-closed** | Missing entry cap → `{:error, :unauthorized}` before any reconstruction/termination. Empty reconstructed caps + alive orchestrator → dispatch fails closed (no termination). The dead-orchestrator fallback (§4.4) is reached ONLY after the operator's owner/admin cap authorized the delete. |
| **Partial-cleanup masquerading as success** | Operator entry COLLECTS per-worker failures and surfaces them (Invariant #9); the `destroy/2` safety-net path logs each `safe/1` failure. No `deleted_rules: 0` false-success (the `Tools.remove_member` B2 fix already enforces atomic prune-or-fail). |

---

## 7. Implementation surface (for the eventual plan — NOT this SPEC)

- `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — new
  `:remove_member` action + handler + `required_caps`; `destroy/2` calls
  `cascade_teardown/1`.
- NEW `Ezagent.Session.Lifecycle.cascade_teardown/1` (or a function on an
  existing session-lifecycle module) — the shared cascade (§4.2).
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex`
  — `grant_owner_session_member_admin_cap/2` at create (§3.3).
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex` +
  `world_live.ex` `@conversation_actions` — two new dispatch clauses (§5).
- React conversation members panel + sessions table — cap-gated remove/delete
  controls (§5).
- Tests (TDD, each an F20/F21 regression):
  - operator WITHOUT `:remove_member` cap → `:unauthorized` (fail-closed);
  - operator WITH cap removes an orchestrator-spawned worker → worker Kind gone +
    config dir gone + member's routing rows pruned;
  - operator removes a plain invited member → membership dropped, entity NOT
    destroyed;
  - delete cascades: ALL workers terminated + config dirs gone + ALL session
    routing rows pruned + orchestrator gone + SessionManager stopped (the
    invariant: zero orphans);
  - delete with a DEAD orchestrator still cascades (§4.4 fallback);
  - bridge-token entry still works unchanged (no regression to `run_tool`).

---

## 7a. Codex adversarial-review verdict (static-only, 2026-06-27)

Codex reviewed this spec against the cited source (read-only, no compile/test).
Verdict on the four security questions:

1. **#154-clean — YES.** Cap #2 today is delegated to the *orchestrator identity*
   as `instance: {:spawned_by, orchestrator_uri}`, `granted_by: owner_uri`
   (`apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex:127-151`)
   — NOT to the operator. The proposed `:remove_member` cap matches the
   owner-rooted `OrchestratorAdmin` precedent
   (`materializer.ex:95-128`, granted via `Identity.Grant.grant_cap/3`). The
   `grant_owner_session_member_admin_cap` grant does not exist yet (this spec
   adds it).
2. **Bridge-token bypass — NO.** `run_tool/4` verifies the bridge token before
   anything else (`session_manager.ex:287-309`); the operator path is a separate
   cap-gated dispatch entry, not a forwarded `run_tool` call.
3. **Cascade reaches workers — confirmed the gap + the fix.** Current
   `destroy/2` only stops the SessionManager (`behavior/session.ex:939-950`);
   `sandbox.destroy` (not bare `lifecycle.terminate`) is the config-dir GC path
   (`tools.ex:491-499` → `sandbox.ex:415-462`; `terminable.ex:144-173` only kills
   the process). The cascade-in-`destroy/2` requirement (§4.1) is load-bearing —
   codex independently flagged that a UI-only cascade lets bare `manage.delete`
   orphan (`manage.ex:87-120` schedules `Lifecycle.destroy/2` generically).
4. **Dead orchestrator — YES.** `Identity.list_caps_for/1` returns
   `MapSet.new()` for a dead Kind (`identity.ex:25-31`); the `Lifecycle.destroy/2`
   fallback is a legitimate internal teardown (rollback already uses it,
   `rollback.ex:47-65`).
5. **Remaining gap — lineage GC on remove-member.** Folded into §3.2 step 4:
   `Tools.remove_member` does not `AgentLineage.forget/1`, so remove-member must
   forget lineage after a successful worker terminate (parity with the delete
   cascade + `rollback.ex:87-93`).

No cap leak, privilege escalation, or unaddressed silent-orphan path was found
beyond the (now-folded) lineage-GC gap.

## 8. Open questions

- **OQ-1 (dead-orchestrator reconstruction).** Confirmed: `list_caps_for` needs a
  live orchestrator. The §4.4 `Lifecycle.destroy/2` fallback is the proposed
  answer. Decision needed: is the VM-internal `Lifecycle.destroy` acceptable as
  the dead-orchestrator teardown primitive (it IS what rollback uses), or should
  delete first *repair/restart* the orchestrator (`repair_orchestrator`) so the
  caps reconstruct, THEN cascade via dispatch? Repair-first is cleaner-on-paper
  but fragile (the orchestrator may be unrestartable — the codex-SIGABRT case);
  the fallback is more robust. **Recommendation: fallback, with an admin-only
  audit log entry.**
- **OQ-2 (admin force-delete).** For a session whose owner is gone AND
  orchestrator is dead, is a workspace/system admin's all-caps the sufficient
  authority for both the entry gate and the cascade? (It satisfies the
  `:remove_member` / `Manage` caps by `:any`.) Likely yes; confirm the cascade's
  `Lifecycle.destroy` fallback doesn't need the (absent) owner.
- **OQ-3 (remove-member arg axis).** `role_name` vs `member` URI — orchestrated
  members have a `role_name`; plain invited members do not. The handler should
  accept both. Confirm the React panel passes the member URI (it has it) and the
  handler resolves role_name only when present.
- **OQ-4 (host Behavior).** Realization (A) hangs `:remove_member` on
  `Behavior.Session`; realization (B) uses a dedicated `SessionMemberAdmin`
  cap-only Behavior. (A) is fewer moving parts and `Behavior.Session` already owns
  `:join`/`:leave`/`:merge_member` (membership IS its concern). Recommend (A)
  unless review prefers the cleaner cap-surface separation of (B).
- **OQ-5 (config-dir GC parity worker vs orchestrator).** Confirm the orchestrator
  agent's config dir is GC'd by the same `sandbox.destroy` / `Lifecycle.destroy`
  hook as a worker's (it is an Agent Kind, so it should be) — step 4.2(3).
