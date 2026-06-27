# SPEC — F7: session participant lifecycle (remove participant + delete session)

**Status:** DESIGN (not implementation).
**Branch:** `docs/f7-remove-delete-spec` (off `origin/main`, do NOT merge).
**Scope:** session-ownership authority model + the cap-model change that lets the
session tear down a participant + the **isomorphic** `remove_participant` design +
delete-session cascade + current-state gaps (per participant type, CLI/UI/cross-op)
+ security. No code lands from this doc.

> **Process note (read first).** This is the SECOND framing of this SPEC. The
> first draft ("operator reconstructs the orchestrator's caps") was codex-validated
> as #154-clean, then **reframed by the team lead** to a session-ownership model.
> The reframe is adopted on technical merit — it cleanly handles the
> dead-orchestrator case (the F7-critical scenario) that the first draft handled
> only by fallback. The reframe arrived via the coordinator and carries **no user
> authority**; the scope increase (a core cap-model change vs. the original's
> reuse-existing-mechanism) is flagged here for the user to adjudicate. The prior
> design is preserved as a documented rejected alternative (§2.4) — validated work
> is not silently discarded.

---

## 0. Naming reconciliation

Tracked as **"F7"** in the #1027 QA stream = ESR field blockers **F20** (no
operator path to remove a session member) + **F21** (no session delete), per
`docs/together/2026-06-24/evidence/blockers.md`. (`blockers.md`'s own "F7" is an
unrelated codex-TUI-crash item.) This SPEC reframes both as one concern:
**session participant lifecycle.**

---

## 1. The design principle — agent and user participants are ISOMORPHIC

> **A participant is a participant.** `session.remove_participant` does NOT
> special-case agent-vs-user. Removing an agent-participant and removing a
> user-participant are the SAME operation, gated by the SAME session authority,
> through the SAME interface. The ONLY difference is the **teardown side-effects**,
> expressed as a uniform per-type hook — NOT two code paths.

| Participant type | Membership teardown | Resource teardown (the uniform hook) |
|---|---|---|
| **agent** spawned INTO the session (orchestrator-managed worker) | `session.leave` | terminate its worker process + GC its `config_dir` + prune its routing rows + forget lineage |
| **agent** invited (an existing agent, not spawned by this session) | `session.leave` | prune its routing rows; do NOT terminate (the session did not spawn it) |
| **user** participant (invited / self-joined) | `session.leave` | prune its routing rows; NEVER destroy the User entity |
| **self-leave** (a participant removing *itself*) | `session.leave` | same per-type hook, scoped to the caller |

The spine of the design (§3): one generic `remove_participant(participant_uri)`
that (a) checks the session authority once, (b) runs the membership leave, (c)
dispatches a single `teardown_participant_resources/2` hook that branches on
**provenance** (was this participant *spawned into* this session?) — not on
"is it a user or an agent." A spawned agent has a worker to reap; everything else
(invited agent, user, self) just leaves + prunes routing. The branch is on
*ownership of the participant's lifecycle*, which is exactly the isomorphism the
lead asked for.

---

## 2. Authority model — the session OWNS participant lifecycle

### 2.1 The session owner holds, at create, authority to manage its membership AND to tear down participants it spawned

Two authorities, both `granted_by: owner_uri` at session-create (real granter,
#154-clean), modeled on the existing owner-grants in
`session_creator/materializer.ex` (`grant_owner_orchestrator_admin_cap`,
`grant_owner_orchestrator_manage_cap`):

1. **Membership authority** — `cap(:session, Behavior.Session, :remove_participant,
   <session_uri>, <ws>)`, the entry gate on the unified action (§3.1). Mirrors the
   `OrchestratorAdmin :restart` cap-only precedent: owner-rooted, session-scoped,
   admin-superset (bootstrap admin's all-`:any` satisfies it).
2. **Participant-teardown authority (the crux — §2.2)** — a cap that lets the
   session owner terminate a worker the session caused to be spawned, WITHOUT the
   orchestrator's `{:spawned_by, orchestrator}` cap.

For **delete**, the owner already holds `cap(:session, Manage, :any, <session_uri>)`
(the create-entry creator grant, `Ezagent.CreatorGrant.manage_cap/4`) →
`manage.delete`. Delete reuses it; the cascade rides `Session.destroy/2` (§4).

### 2.2 The cap-model change — how the session terminates an orchestrator-spawned worker WITHOUT `{:spawned_by, orchestrator}`

This is the crux. The mechanism, grounded in the real lineage + cap-match code:

**The lineage ALREADY makes the owner an ancestor of every spawned worker.**
- A managed member worker is spawned by the orchestrator
  (`Tools.spawn_member → Agent.spawn_from_template_content(content, member_uri,
  caller=orchestrator, …)`), so `AgentLineage.record(worker, orchestrator)`.
- The orchestrator itself is spawned/owned by the session owner:
  `entity/session/orchestrator.ex:201 AgentLineage.record(orchestrator_uri,
  owner_uri)`.
- Therefore the durable lineage chain is **`worker → orchestrator → owner`**.
- `Ezagent.Capability.Match.instance_match?({:spawned_by, P}, needed)` resolves via
  `Ezagent.AgentLineage.spawned_in_lineage?(needed, P)`, which **walks the chain
  upward** (`agent_lineage.ex` `walk_lineage/3`, bounded depth, inclusive). So
  `spawned_in_lineage?(worker, owner_uri)` is **already TRUE** today.

**The change:** grant the session OWNER, at create, the teardown cap

```elixir
cap(:agent, Ezagent.Behavior.Sandbox,    :destroy,   {:spawned_by, owner_uri}, ws)
cap(:agent, Ezagent.Behavior.Terminable, :terminate, {:spawned_by, owner_uri}, ws)
# granted_by: owner_uri   (self-rooted: the owner IS the lineage root)
```

This authorizes `sandbox.destroy` / `lifecycle.terminate` on ANY agent in the
owner's spawn lineage — which includes every worker spawned into any of the owner's
sessions. The cap is a **scope-bounded `{:spawned_by, %URI{}}` instance**, the
SAME legality class as the orchestrator's cap #2 — confirmed grant-legal by
`Ezagent.Behavior.Identity.rule_cap_bounded?/1` (a scope-bounded instance permits
`action: :any`; a concrete action is fine too). No unowned/forged cap.

**Why this is the right lever (and why the lineage is NOT changed):**
- It works against the **existing, unchanged** lineage chain — no spawn-path or
  `AgentLineage.record` change. Critically, it does NOT re-parent anything:
  - Re-parenting the worker to the session (`worker.spawned_by = session`) would
    BREAK the orchestrator's cap #2 (`spawned_in_lineage?(worker, orchestrator)`
    would no longer hold — lineage is single-parent), regressing
    `Tools.update_member_template` (regenerate = terminate+respawn under cap #2).
  - Inserting the session as an intermediary (`orchestrator → session → owner`)
    would BREAK **credential resolution**:
    `user_default_credential_source.ex:205 validate_source_owner` does a DIRECT
    `AgentLineage.lookup` and requires the parent to be the owning user; an
    intermediary session node fails that check. (`api_keys.ex` + `terminable.ex`
    notify also read the direct parent.)
  - **Conclusion: do NOT touch the lineage graph.** Add a cap that exploits the
    chain that already exists. This is the minimal, regression-free change.
- It is **durable + orchestrator-independent**: `spawned_in_lineage?` walks the
  SQLite-backed ETS lineage table, NOT live processes. So the session owner can
  tear down a worker **even when the orchestrator has crashed** (the F7 headline
  bug: SIGABRT'd codex orchestrator). This is the decisive advantage over the
  first draft (which reconstructed the dead orchestrator's caps → empty set → had
  to fall back).

**Blast radius (the honest cost):** `{:spawned_by, owner_uri}` authorizes the
owner to tear down workers across ALL their sessions, not just one. This is
defensible — an owner CAN reap any worker they ultimately own — and the *entry
gate* (§2.1 membership cap) is session-scoped, so the practical reach via the
`remove_participant` action is one session at a time. A strictly session-scoped
teardown cap would require either a lineage change (rejected above) or a new
membership-as-scope match type (§2.4 alt B, heavier). Recommend the
owner-scoped cap; flag the blast radius as OQ-2.

### 2.3 De-entanglement: parallel authority, not replacement

The reframe's goal ("de-entangle the orchestrator from session lifecycle") is
achieved for the **lifecycle** path: `remove_participant` / delete run under the
SESSION OWNER's teardown cap, never the orchestrator's. But the orchestrator's
cap #2 is NOT retired — `Tools.update_member_template` (live team-editing:
terminate old worker → respawn) legitimately terminates under cap #2. Correct
framing: **the session-owner teardown authority is PARALLEL to cap #2.**
`session.remove_participant` is the unified *lifecycle* entry; cap #2 remains the
orchestrator's *live-editing* authority. Both coexist #154-cleanly because both
caps have real granters and bounded scopes.

### 2.4 Rejected alternatives

| Option | Verdict | Why |
|---|---|---|
| **(prior draft) operator reconstructs the orchestrator's caps** (SessionManager step-2 pattern) | ✅ valid, ❌ superseded | Genuinely #154-clean (codex-validated in the v1 of this doc): cap #2 stays on the orchestrator, reconstructed transiently session-side. BUT it needs a LIVE orchestrator — `Identity.list_caps_for(dead_orchestrator)` returns `MapSet.new()`, so it fell back to `Lifecycle.destroy` for the dead case. The session-ownership model handles dead-orchestrator *natively* (durable lineage), so it's strictly better. Kept as a documented fallback path for any case where the owner cap is somehow absent. |
| re-parent worker `spawned_by = session` | ❌ | Breaks cap #2 (single-parent lineage) → regresses `update_member_template`. |
| insert session as lineage intermediary (`orch → session → owner`) | ❌ | Breaks credential resolution (`validate_source_owner` direct-parent check) + the terminate/api-keys direct-parent reads. |
| mint operator a `{:spawned_by, orchestrator}` cap | ❌ | Unowned/forged — operator did not spawn the worker; #154 violation. |
| wire operator past the bridge-token `run_tool` gate | ❌ | Bridge-token bypass; token is the orchestrator transport's credential. |
| **(alt B) membership-implies-terminable** — a new `{:participant_of, session}` cap scope match type that checks live session membership | ⚠️ heavier | Strictly session-scoped (no cross-session blast radius) and conceptually pure ("you can tear down anyone IN your session"). BUT it adds a new core `Capability.Match.instance_match?` clause that does a **process read** (session members slice) inside cap matching — cap matching is currently pure/process-free. Larger blast on the core matcher + a perf/coupling concern. Note as the principled alternative; recommend the owner-scoped lineage cap (§2.2) for minimality. |

---

## 3. Design — `session.remove_participant` (the isomorphic spine)

### 3.1 One generic, cap-gated dispatch action

On `Ezagent.Behavior.Session`:

```elixir
action(:remove_participant,
  args: %{participant: :uri},          # role_name accepted as an alias (§OQ-3)
  returns: %{status: :atom, torn_down: :atom, deleted_rules: :integer, repointed_rules: :integer},
  caps: [:remove_participant],
  modes: [:call])

def required_caps, do: %{..., remove_participant: cap(:session, __MODULE__, :remove_participant)}
```

`data_owner/1` already resolves to the session's `:owner_uri`, so the cap's
ownership story matches the existing Chat caps. NO agent-vs-user branch in the
action signature or the cap.

### 3.2 The handler — generic over participant type, uniform teardown hook

`handle_remove_participant/2` (runs inside the Session Kind process, members slice
directly readable):

1. **CapBAC already passed** at the dispatch chokepoint (the owner-rooted
   `:remove_participant` cap, or admin all-caps, or — for self-leave — see §3.3).
2. Resolve `participant_uri` (from `participant` URI, or `role_name` if supplied).
3. **`session.leave`** the participant — the membership removal. This is the SAME
   for every type and emits `{:member_left, participant_uri}` via
   `Delivery.broadcast_membership_effects` (`behavior/session.ex:712`) — the
   cross-surface convergence signal (§5).
4. **`teardown_participant_resources(participant_uri, ctx)`** — the UNIFORM hook,
   branching on **provenance** (not user-vs-agent):
   - **spawned-into-this-session agent** (member carries a `source_template_uri`
     facet AND `AgentLineage.spawned_in_lineage?(participant, owner_uri)`):
     dispatch `?action=sandbox.destroy` on the worker under the OWNER's teardown
     cap (§2.2) — runs `Sandbox.handle_destroy` (config-dir GC, verified
     `sandbox.ex:415-462`) + schedules termination. Then `AgentLineage.forget/1`
     (parity with rollback; the prior draft's codex Q5 finding). `torn_down:
     :worker`.
   - **everything else** (invited agent, user, self): no worker to reap.
     `torn_down: :membership_only`. NEVER destroy a User entity; NEVER terminate an
     agent the session did not spawn.
   - In ALL branches: prune routing rows naming the participant, scoped
     `created_by == session_uri` (reuse `Tools.prune_routing_rules_for`'s
     session-scoped, atomic prune-or-fail — codex B2 fix).
5. Return `{:ok, %{status: :removed, torn_down:, deleted_rules:, repointed_rules:}}`
   / `{:ok, :already_removed}` / `{:error, reason}`.

The teardown hook is ONE function with a provenance branch — the type-specific
behavior the lead asked for, NOT two code paths.

### 3.3 Self-leave routes through the SAME interface

A participant removing ITSELF dispatches the SAME `session.remove_participant`
with `participant == caller`. Authority: a participant holds (from
`Membership.mount_participation_caps` / `provision_join_authority`) a self-scoped
authority; `remove_participant` accepts a self-leave when `participant == caller`
even WITHOUT the owner `:remove_participant` cap (self-removal is always
permitted). The teardown hook still runs (a self-leaving spawned agent reaps its
own worker). Implementation: `handle_remove_participant` checks
`caller == participant OR holds(:remove_participant cap)` — fail-closed otherwise.
This unifies operator-removes-other, orchestrator-removes, and self-leave on one
action.

### 3.4 Orchestrator as a caller (not a special path)

If the orchestrator removes a member (e.g. its existing `remove_member` MCP tool),
it routes through the SAME `session.remove_participant` action. The orchestrator
holds cap #1 `{:within_session, S}` (kind `:session`, behavior/action `:any`),
which authorizes `session.remove_participant` (a session-kind action) — so the
orchestrator is just another authorized caller of the unified entry. Its worker
terminate inside the hook can run under EITHER the owner teardown cap (if the
dispatch ctx carries it) OR — to preserve the exact current orchestrator behavior
— the orchestrator continues to use its own cap #2 via the existing
`Tools.remove_member` path. Recommendation: keep `Tools.remove_member` as a thin
wrapper that calls `session.remove_participant`, so all callers converge (OQ-4).

### 3.5 Where the caps are granted (real granters)

At session create, in `session_creator/materializer.ex`, add two owner grants
alongside the existing two:
- `grant_owner_remove_participant_cap/2` →
  `cap(:session, Behavior.Session, :remove_participant, <session_uri>, ws)`,
  `granted_by: owner`.
- `grant_owner_participant_teardown_cap/2` →
  `cap(:agent, Sandbox, :destroy, {:spawned_by, owner_uri}, ws)` +
  `cap(:agent, Terminable, :terminate, {:spawned_by, owner_uri}, ws)`,
  `granted_by: owner`. Idempotent via `Identity.Grant.grant_cap/3`. (This is the
  owner's self-rooted lineage-teardown authority — granted once per owner; a
  re-grant on the second session is a logical-equality no-op.)

---

## 4. Design — Delete session (cascade-remove all participants)

### 4.1 Delete = cascade `remove_participant` over all participants + teardown the session

Delete is `manage.delete` on the session (owner's existing `Manage :any` cap), and
the cascade rides `Behavior.Session.destroy/2` so EVERY delete path (operator,
admin, test, bare `manage.delete`) cascades — NOT just the UI handler. (codex
v1-Q5 + the lead both flagged: a UI-only cascade lets bare `manage.delete` orphan,
because `Manage` schedules `Lifecycle.destroy/2` generically — `manage.ex:87-120`.)

`Behavior.Session.destroy/2` (today only stops the SessionManager —
`behavior/session.ex:939-950`) is extended to call a shared
`cascade_teardown/1` BEFORE stopping the SessionManager, while the Kind is still
LIVE (members slice readable):

1. Read live members + working copy (`orchestrator_uri`, `owner_uri`).
2. For EACH participant: run the SAME `teardown_participant_resources/2` hook from
   §3.2 — terminate spawned workers (owner teardown cap, durable lineage; works
   for a dead orchestrator), GC config dirs, prune routing, forget lineage. Invited
   agents/users: membership-only. **Uniform with remove_participant** — delete is
   just "remove every participant, then tear down the shell."
3. Terminate the orchestrator agent itself + GC its config dir (the owner holds
   `cap(:agent, Manage, :any, orchestrator_uri)` — the existing
   `grant_owner_orchestrator_manage_cap`; AND the orchestrator is in the owner's
   own lineage so the §2.2 teardown cap also reaches it).
4. Prune ALL session routing rows (`created_by == session_uri`, force) +
   reload registry — the `rollback.ex delete_session_rule_rows/1` primitive.
5. Stop the SessionManager executor (keep the current behavior).
6. `AgentLineage.forget/1` for every terminated worker + the orchestrator.

Best-effort + idempotent on the `destroy/2` safety-net path (`safe/1`-wrapped,
log on failure). On the operator/CLI delete *entry*, per-participant failures are
COLLECTED and surfaced (Invariant #9, no silent drop).

### 4.2 Dead-orchestrator: handled natively

Because teardown uses the owner's durable-lineage cap (§2.2), NOT reconstructed
orchestrator caps, delete works when the orchestrator is dead — the exact junk-
session-cleanup (F21) + crashed-codex (F7) scenario. The members are enumerable
from the still-live Session slice independent of orchestrator liveness, and
`spawned_in_lineage?` walks the durable table. **No `Identity.list_caps_for` on a
dead Kind, no fallback needed.** This is the model's headline win.

---

## 5. Current-state gaps (per participant type + CLI/UI/cross-op)

Audited against `origin/main`. The design must CLOSE these.

### 5.1 Per-participant-type achievability (TODAY)

| Operation | agent (spawned) | agent (invited) | user | self-leave |
|---|---|---|---|---|
| **invite/join** | ✅ orchestrator `add_managed_member` + world `session.invite` | ✅ world `session.invite` (`conversation_actions.ex:434`) | ✅ world `session.invite` + `self_join` | ✅ `self_join` on view |
| **remove** | ⚠️ ONLY via orchestrator MCP `Tools.remove_member` (agent-driven, bridge-token-gated). NO operator/CLI path. | ❌ no path at all (orchestrator `remove_member` targets *managed* members by role_name; an invited agent has no role) | ❌ **no path at all** — `Tools.remove_member` is keyed on `role_name`/managed members; a plain invited USER cannot be removed by anyone | ❌ no self-leave UI/dispatch action wired (`:leave` exists on the Behavior but no caller surfaces it) |
| **delete session** | ❌ no operator/CLI delete; `manage.delete` works for the owner but does NOT cascade (orphans workers — §4) | ❌ | ❌ | n/a |

**Key finding (answers the lead's Q2):** PR-3b ("World invite/remove members")
landed INVITE for all types but **remove is effectively agent-(managed)-only via
the orchestrator MCP tool** — `lv_parity_test.exs:91` confirms "`remove_member`
stays pending — in LV it is WORKSPACE member removal." So:
- **User-participant removal is NOT achievable today** by ANY caller (no
  session-scoped user-remove path exists).
- **Invited-agent removal is NOT achievable** (the only remove path keys on
  managed `role_name`).
- **Self-leave is NOT surfaced.**
The isomorphic `remove_participant` (§3) closes ALL of these uniformly — that is
its primary justification.

### 5.2 CLI

- **No `mix ezagent.session.remove_member` / `.remove_participant`** and **no
  `mix ezagent.session.delete`** exist. The only related CLI is
  `mix ezagent.workspace.remove_member` (`ezagent.workspace.remove_member.ex`) —
  a DIFFERENT concern (workspace membership, `Ezagent.Workspace.remove_member/2`),
  not session participant removal.
- **Gap to close:** add `mix ezagent.session.remove_participant <session_uri>
  <participant_uri>` and `mix ezagent.session.delete <session_uri>` as thin CLI
  front-ends that dispatch the SAME `session.remove_participant` /
  `manage.delete` actions under the caller's caps — the "same function the
  operator UI calls" pattern the workspace task already documents.

### 5.3 UI

- World UI has `session.invite` + per-member panel but **no remove control** and
  **no session-delete control** (`world_live.ex:236 @conversation_actions` lacks
  `session.member.remove` / `session.delete`; the React Conversation panel has
  `onInvite` only). These are the controls the QA-fix subagent pulled.
- **Gap to close:** add `session.remove_participant` + `session.delete` to
  `@conversation_actions` + cap-gated React controls (§6).

### 5.4 Cross-op consistency (CLI ↔ UI ↔ live) — the convergence trace

**Good news: a convergence mechanism EXISTS and is surface-agnostic.**
- `Behavior.Session.handle_leave` emits `{:member_left, member_uri}` via
  `Delivery.broadcast_membership_effects` (`behavior/session.ex:712`); join emits
  `{:member_joined, …}` (`membership.ex`).
- `world_live.ex:152` subscribes and handles `{:member_joined | :member_left}` →
  `ConversationActions.push_members/1` → re-reads the live members slice and
  pushes `members:update` to React.
- Because this is a **server-side PubSub broadcast keyed on the session**, it
  fires regardless of which surface triggered the leave. So **a CLI
  `remove_participant` (which dispatches `session.leave`) WILL live-update an open
  UI**, and a UI remove is visible to a subsequent CLI `list` (both read the same
  persisted members slice). **State converges across surfaces** — IF removal goes
  through `session.leave`.

**The real divergence/staleness risks (gaps the design must guard):**
1. **Worker-terminate emits NO membership broadcast.** `sandbox.destroy` /
   `lifecycle.terminate` reap the worker PROCESS but do not emit `:member_left`.
   If removal terminated the worker WITHOUT a preceding `session.leave`, the
   members panel would show a now-dead member until the Session's `:DOWN` monitor
   flips it offline (and `:DOWN` only sets `online: false`, it does NOT remove the
   member — `behavior/session.ex` `handle_signal`). **Design guard:**
   `remove_participant` ALWAYS does `session.leave` FIRST (§3.2 step 3), THEN the
   teardown hook — so the `:member_left` broadcast always fires and the UI
   converges. (This is why the order in §3.2 matters.)
2. **Delete-session emits no per-session "deleted" signal to other open UIs.** An
   operator on another tab viewing the deleted session won't be auto-evicted.
   **Design guard:** the cascade should broadcast a session-level
   `{:session_deleted, session_uri}` on the session events topic
   (`Delivery.session_events_topic`) so open views `push_patch` away; the deleting
   surface already navigates away. (OQ-5.)
3. **CLI has no socket**, so it relies entirely on the PubSub broadcast for UI
   convergence — which holds for remove (via `:member_left`) but needs the
   §5.4(2) signal for delete. No client-side cache to invalidate (the world UI
   re-reads the slice on every broadcast), so no stale-cache bug for remove.

**Verdict on cross-op:** remove converges across CLI/UI by construction once
removal routes through `session.leave` first; delete needs the added
`:session_deleted` broadcast to fully converge. Both are folded into the design.

---

## 6. UI + CLI re-instatement

- **React:** members panel gains a per-member remove (✕) control (cap-gated on
  `:remove_participant`); conversation header / sessions table gains a Delete
  control (cap-gated on the owner `Manage` cap). Self-leave = a "Leave" control
  visible to any participant.
- **LV:** add `"session.remove_participant"` + `"session.delete"` to
  `@conversation_actions`; the handlers dispatch the unified actions under the
  operator's real caps (CapBAC at the chokepoint), then rely on the
  `:member_left` / `:session_deleted` broadcasts for convergence. Partial-failure
  on delete surfaced via the `world:state` error channel `session.create` uses.
- **CLI:** `mix ezagent.session.remove_participant` + `mix ezagent.session.delete`
  dispatch the SAME actions (§5.2).

All three surfaces are thin front-ends over the SAME two dispatch actions — the
isomorphism extends to surfaces, not just participant types.

---

## 7. Security analysis

| Concern | Mitigation |
|---|---|
| **Unowned cap** | Both new caps are `granted_by: owner_uri` at create (the membership cap; the teardown cap is owner-self-rooted — the owner IS the lineage root). Scope-bounded `{:spawned_by, owner_uri}` is grant-legal (`rule_cap_bounded?` ✓), same class as cap #2. No `:plugin_declared`, no forged cap. |
| **Lineage integrity / cap #2 regression** | The design adds a cap; it does NOT mutate the lineage graph. `spawned_in_lineage?(worker, orchestrator)` stays true → cap #2 + `update_member_template` unaffected. Credential resolution (direct-parent reads) unaffected. (codex must verify — §8.) |
| **Bridge-token bypass** | None. `remove_participant` / `manage.delete` are cap-gated dispatch entries authenticated by the caller's owner/admin cap at the chokepoint, not the bridge token. `run_tool`'s token gate is untouched. |
| **Cross-session blast radius** | The `{:spawned_by, owner_uri}` teardown cap reaches the owner's workers across sessions, BUT the `:remove_participant` ENTRY cap is `instance: <session_uri>` — practical reach via the action is one session. (OQ-2: tighten to session scope only if alt-B's cost is accepted.) |
| **Destroying a non-spawned participant** | §3.2 teardown branches on provenance: only a participant `spawned_in_lineage?(·, owner)` with a `source_template_uri` facet is terminated. Invited agents/users → membership-only; a User entity is NEVER destroyed. |
| **Self-leave privilege** | A caller may remove ONLY itself without the owner cap (`caller == participant`); removing ANOTHER participant requires the `:remove_participant` cap. Fail-closed. |
| **Silent orphan** | Removal does `leave` THEN teardown, so the `:member_left` broadcast always fires (no zombie panel member — §5.4). Delete cascade reaches workers via durable-lineage teardown even with a dead orchestrator. Per-op failures collected + surfaced (Invariant #9). |
| **Fail-closed** | Missing entry cap (and not self-leave) → `:unauthorized` before any teardown. |

---

## 7a. Codex adversarial-review verdict

*(Filled in after the §8 codex run — see the bottom of this file.)*

---

## 8. Implementation surface (for the eventual plan — NOT this SPEC)

- `behavior/session.ex` — `:remove_participant` action + handler + the uniform
  `teardown_participant_resources/2` hook; `destroy/2` calls `cascade_teardown/1`;
  emit `{:session_deleted, …}` on delete.
- NEW shared `cascade_teardown/1` (session-lifecycle module).
- `session_creator/materializer.ex` — `grant_owner_remove_participant_cap/2` +
  `grant_owner_participant_teardown_cap/2` at create.
- `Tools.remove_member` — refactor to a thin wrapper over `session.remove_participant`
  (converge callers; OQ-4).
- `apps/.../world/conversation_actions.ex` + `world_live.ex` — two new dispatch
  clauses + the `:session_deleted` handler.
- NEW `mix ezagent.session.remove_participant` + `mix ezagent.session.delete`.
- React members panel + sessions table — remove / delete / leave controls.
- Tests (TDD, each an F20/F21 regression):
  - remove a spawned-agent participant → worker gone + config_dir gone + routing
    pruned + `:member_left` broadcast + lineage forgotten;
  - **remove a USER participant → membership dropped, User entity intact** (closes
    the §5.1 user-removal gap);
  - remove an invited (non-spawned) agent → membership-only, agent NOT terminated;
  - self-leave (caller == participant) works WITHOUT the owner cap;
  - remove WITHOUT cap and not-self → `:unauthorized`;
  - delete cascades ALL participants (zero orphans) + works with a DEAD
    orchestrator;
  - **cap #2 + `update_member_template` still work** (lineage unchanged — the
    no-regression gate);
  - CLI remove → open UI live-updates (`:member_left`); UI remove → CLI `list`
    reflects it (cross-op convergence).

---

## 9. Open questions

- **OQ-1 (cap #2 non-regression).** Confirm via test that granting the owner
  `{:spawned_by, owner_uri}` teardown does NOT alter `spawned_in_lineage?(worker,
  orchestrator)` (it shouldn't — additive cap, no lineage write). This is the
  load-bearing safety property; codex must verify.
- **OQ-2 (teardown blast radius).** Accept owner-scoped `{:spawned_by, owner_uri}`
  (cross-session reach, minimal change) vs. build the session-scoped alt-B
  (`{:participant_of, session}` match type — pure but adds a process read to the
  core matcher)? Recommend owner-scoped.
- **OQ-3 (participant arg axis).** `participant: :uri` is the isomorphic shape (all
  types have a URI); `role_name` accepted only as an alias for managed members.
- **OQ-4 (orchestrator caller convergence).** Make `Tools.remove_member` a wrapper
  over `session.remove_participant`, or leave it parallel? Wrapper converges all
  callers but touches a codex-validated tool; confirm no behavior change for the
  orchestrator's own removals.
- **OQ-5 (`:session_deleted` broadcast).** Define the topic + payload for evicting
  other open views of a deleted session; ensure it's idempotent with the deleting
  surface's own navigation.
- **OQ-6 (admin force-delete ownerless session).** For a session whose owner is
  gone AND orchestrator dead: does workspace/system admin all-caps satisfy both the
  entry gate AND the teardown (it does via `:any`)? Confirm the cascade needs no
  live owner.
