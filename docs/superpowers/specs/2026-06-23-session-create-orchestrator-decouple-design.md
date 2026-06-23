# De-orchestrator-ize the Session: Orchestrator as a `role` Member + Provision-on-Route — Design (rev5)

## 0c. What changed in rev5 (resolves the rev4 adversarial-review: 1 BLOCKER + 3 HIGH)

- **BLOCKER — delivery-time transport-readiness (not a create-time wait):**
  deleting the gate must NOT lose the bridge-readiness guarantee. `PendingDelivery`
  buffers on **Kind** readiness, but a cc agent can be Kind-ready while its
  claude/MCP bridge never joins → a routed message would vanish silently. rev5
  adds a **delivery-time transport-readiness buffer** for bridge-backed members
  (§4.5): a message routed to such a member buffers until its bridge has joined
  (`LiveJoinRegistry`), or fails **visibly** — never silently. This is a delivery
  contract, NOT a create-time wait (create stays pure; Allen's no-wait-at-create
  holds).
- **HIGH — tagged routing receiver schema:** rule receivers are stored today as
  plain URI strings (`rule_store.ex receivers: {:array,:string}`). Role-targeting
  needs a **tagged receiver form** (`role | uri | magic`) + DB migration +
  RuleStore/Resolver/UI/CLI changes + dual-read of legacy URI/magic receivers
  (§4.3).
- **HIGH — caps via the existing fail-closed Role policy (not a genesis carve-out):**
  role-member caps go through `Ezagent.Role`'s existing fail-closed
  `requested ∩ flavor/tenant policy` materialization (`role.ex`). The system
  orchestrator role's caps are whitelisted in that policy; **tenant-authored
  roles cannot mint genesis-backed `behavior:any`/`{:spawned_by}` authority**
  (negative tests required). Owner-delegation (#153/#154) stays out of scope (§4.6).
- **HIGH — PR sequencing:** the create-flip + gate-delete PR MUST also retarget
  the create-return contract, `Workspace.create_session` meta, HomeLive, and
  Scenario-32 G1 in the SAME PR — otherwise CI is red or implementers keep an
  eager path (§12).

> Status: design (brainstorm-approved 2026-06-23). **rev4 is a major redesign**
> of rev1–rev3 (which kept the orchestrator special and added an eager
> reconciler + bounded await). Per Allen's 2026-06-23 direction, rev4 removes the
> orchestrator concept from the session entirely: it becomes an ordinary
> `role: orchestrator` member, brought up **lazily by routing** (no separate
> reconciler, no readiness wait). Supersedes the create→orchestrator coupling in
> `2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md` and
> `2026-05-26-session-create-orchestrator-unified.md`. Fixes PR #902.
>
> **Deliverable: this spec + a handoff doc + a codex prompt.** Implementation is
> by codex, sequenced as green-at-each-step PRs. The §13 de-orchestrator-ization
> checklist (derived from the full audit) is the completeness gate.

## 0. What changed across revisions

- rev1–3: kept orchestrator special; create either waited (atomic, rollback) or
  spun an **eager reconciler** + bounded-await worker + CAS status. The proper
  adversarial-review + Allen's review showed the wait itself is agent-layer and
  the eager reconciler is unnecessary.
- **rev4 (this)**: orchestrator is just a `role: orchestrator` member; the
  "bring the declared member into existence" function folds into **role-based
  routing as provision-on-route** (lazy); the readiness gate is **deleted**;
  the Session Kind / session domain is **fully de-orchestrator-ized**.

## 1. Summary

Today the session and its orchestrator agent are welded together: `create_session`
synchronously spawns the orchestrator, **waits up to 90s** for the orchestrator's
live MCP bridge-join, and on timeout **kills the orchestrator and rolls the whole
session back — deleting the session's respawnable snapshot**. A hung orchestrator
(e.g. its claude process stalls at an onboarding dialog) therefore destroys an
otherwise-fine session (PR #902).

rev4 removes the coupling at the root by removing the *specialness*:

1. **`create_session` is pure** — it creates the session, joins the owner, and
   records the SessionTemplate's declaration (members + routing rules + legends +
   prompts). It never spawns, waits for, or rolls back on the orchestrator.
2. **Orchestrator = a `role: orchestrator` member** — one entry in
   `SessionTemplate.members`; the dedicated `orchestrator_template_uri` field and
   the special `[owner, orchestrator]` create arm are removed.
3. **Provision-on-route (lazy)** — routing rules target **roles**. When routing
   resolves a rule to a declared role that has **no live member**, the router
   provisions it (spawn the declared agent + join + materialize its rules) and
   then delivers (buffered until the agent is ready — no wait). This is the single
   primitive that replaces both the old synchronous ensure and the (rejected)
   eager reconciler.
4. **Readiness gate deleted** — no 90s wait, no kill, no rollback. Orchestrator
   readiness is the agent's own concern; the session only *reads/displays* it via
   `Orchestrator.Health` + `LiveJoinRegistry`.
5. **Session Kind de-orchestrator-ized** — no orchestrator-specific fields,
   caps-special-casing, tools-naming, or transport references remain in the
   session domain (§13 checklist).

## 2. The bug (root cause, verified on `main` 2026-06-23)

Chain (each link code-verified; reproduced ×5 via in-node erpc by the
`world-deploy-e2e-pg` pass — PR #902 `docs/together/2026-06-23/e2e-blocker-analysis.md`):

1. The orchestrator is a cc agent; its claude process can hang at the project MCP-
   trust onboarding dialog (`esr-bridge`) → it never live-joins. *(Agent-side
   onboarding fix is OUT OF SCOPE — other devs. rev4 makes the session robust
   regardless of why bring-up is slow/fails.)*
2. `SessionCreator.create_session/3` ensures the orchestrator **synchronously**
   (`finalize_fresh_session` → `ensure_orchestrated_session(new_session?: true)`).
3. The ensure **waits up to 90s** for the live bridge-join
   (`Ezagent.Entity.Session.Orchestrator.await_orchestrator_ready/3`, polling
   `LiveJoinRegistry.joined?`, `@orchestrator_readiness_timeout_ms 90_000`). The
   outer `workspace.create_session` `:call` only has the 5s framework dispatch
   budget (`Ezagent.Invocation`, `inv.ctx[:deadline_ms] || 5_000`), so the caller
   times out at 5s while the server grinds toward 90s.
4. On step-4..8 failure the create-NEW arm calls `rollback_session/3`, which
   **terminates the Session Kind AND deletes its `kind_snapshots` row**.
5. A later `:session :send` lazy-spawns from snapshot; with the snapshot deleted,
   `Ezagent.Invocation` returns `{:error, :no_such_actor}`.
6. The error is invisible: the world composer sends `mode: :cast` + `reply:
   :ignore` (`conversation_actions.ex` `send_message`).

Not a capability problem (admin holds the wildcard cap; a snapshot-bearing
session accepts the identical send). The defect is the create→orchestrator
coupling + the snapshot-deleting rollback.

## 3. Goals / non-goals

**Goals**
- `create_session` returns a usable session immediately, independent of any
  agent member's bring-up.
- No code path waits for, kills, or rolls back a session because of an
  orchestrator (or any agent member).
- Orchestrator is an ordinary `role: orchestrator` member; the Session Kind /
  session domain contains zero orchestrator-specific logic (§13).
- A declared agent member is brought up **lazily, on first route to its role**,
  spawned + joined + its rules installed; delivery buffers until it is ready.
- Orchestrator status is a pure read (`Health`/`LiveJoinRegistry`); swallowed
  dispatch errors are surfaced.

**Non-goals (YAGNI for this work)**
- No eager reconciler / activation sweep (rejected — provision-on-route covers
  it). A future pre-warm option may add an `on_ready` "prepare member" trigger;
  NOT in this work.
- Owner-delegated cap authority for the orchestrator's `{:spawned_by}` cap
  (#153/#154) stays deferred — the role-member keeps today's system/genesis-backed
  grant (§4.6).
- The cc onboarding / MCP-trust auto-dismiss (agent-side, other devs).
- Rate-cap / loop detection beyond what exists.

## 4. Design

### 4.1 `create_session` is pure

`create_session/3` for any template synchronously does only:

1. spawn the Session Kind (`Ezagent.Kind.spawn(Session, …)`) — init writes the
   respawnable snapshot atomically with `ever_created`,
2. bind the session to its workspace (`WorkspaceRegistry.bind/2`),
3. join the **owner** (a user — no spawn),
4. install the SessionTemplate's **declaration** that does not require agent
   members to exist yet: the **role-targeted** routing rules, legends, prompt
   templates (§4.3), and record the member **declarations** (role → agent
   template) on the working copy,

then returns `{:ok, session_uri, %{}}`. It does **not** spawn agent members, does
**not** call `ensure_orchestrated_session`, does **not** wait, and has **no
orchestrator arm**. The old plain-vs-orchestrated branch collapses into this one
path. Agent members are provisioned later, lazily, by routing (§4.4).

The synchronous-create rollback (`rollback_session/3`) is retained ONLY for
failures of these cheap synchronous steps (snapshot/bind/owner-join). It never
fires for an agent member.

### 4.2 Orchestrator becomes a `role: orchestrator` member

- `SessionTemplate`: **delete** the dedicated `orchestrator_template_uri` field
  (+ its `@config_atom_keys` entry, working-copy default, the plain-vs-orchestrated
  comments). The orchestrator becomes one entry in the existing
  `members: [map()]` list: `%{role_name: "orchestrator", source_template_uri:
  "template://…/cc-orchestrator", in_session_template: true}`.
- The default SessionTemplate seed (`application.ex do_seed_default_session_template`
  + `config :default_orchestrator_template_uri`) seeds the orchestrator **as a
  member**, not a separate field.
- The destination is half-built already: the cc-orchestrator AgentTemplate already
  carries `role: "orchestrator"` (`cc_orchestrator_seed.ex`), `OrchestratorRole`
  is a flavor-agnostic Role recipe, and scenario_32 already asserts "orchestrator
  is a member of its session." rev4 finishes this migration.

### 4.3 Role-targeted routing rules (resolve at route-time)

Today `materialize_template_team` resolves rules `role → uri` at materialize-time
(`install_template_rule_sets(role_to_uri)`), which requires members to exist.
rev4 changes rules to **carry the role** and resolve to a member **at route-time**:

- `create_session` installs the SessionTemplate's rule-sets as **role-targeted**
  rules (no member URIs needed yet).
- At route-time the router resolves a rule's role-target to the session's live
  member for that role (via membership + role lookup, all runtime).

This is what lets routing both (a) deliver to an existing role-member and (b)
trigger provisioning when the declared role has no live member (§4.4).

**Tagged receiver schema (rev5 HIGH fix).** Today rule receivers are stored as
plain strings interpreted as URIs (`rule_store.ex receivers: {:array, :string}`,
parsed via `Ezagent.URI.new!`; magic tokens are the only non-URI form). A bare
role string like `"orchestrator"` would crash URI parsing or collide with
URI/magic receivers. rev5 introduces a **tagged receiver form** — `{:role, name}`
| `{:uri, uri}` | `{:magic, token}` — with: a `RuleStore` schema/migration to
persist the tag, `Resolver` changes to dispatch on tag (role → resolve-or-provision
at route-time; uri/magic unchanged), and UI/CLI validation. **Dual-read** during
transition: legacy untagged strings are read as `{:uri, _}`/`{:magic, _}` (their
current meaning) so existing rules keep working; only role-targeting requires the
new tag. No rule silently changes meaning.

### 4.4 Provision-on-route (the single bring-up primitive)

When the router resolves a rule whose target **role** is **declared** by the
SessionTemplate but has **no live member** in the session:

1. **Provision** the member: read the declaration (role → agent template), spawn
   the agent (the generic member-spawn path — `Tools.spawn_member` /
   `spawn_from_template_content`), join it to the session, and install any rules
   that target it (resolve its role → its new URI). All fast; no wait for the
   agent's claude/bridge to become ready.
2. **Deliver** the routed message to the now-joined member. If the member is not
   yet ready, delivery buffers via `PendingDelivery` and runs when it announces
   ready (existing lazy-dispatch behavior). The router is never blocked.

Properties:
- **Idempotent / race-safe**: provisioning holds the per-session create lock (the
  existing `:create_session` `:global` lock id, reused) so concurrent routes /
  a manual restart cannot double-spawn; a member already live short-circuits.
- **Self-healing on death**: a member that crashes is re-provisioned on the next
  route to its role (no separate reconciler needed).
- **No boot storm**: members are provisioned only when actually routed to, so
  there is no cold-restart fan-out of N concurrent bring-ups (the 2026-05-31
  boot-storm warning is satisfied by laziness).
- **Cross-workspace** (audit surprise #6): provisioning must preserve the
  sanctioned system-template → tenant-workspace spawn that `ensure_orchestrator`
  does today (it bypasses `Behavior.Template.resolve_workspace_uri/3`'s
  anti-cross-workspace guard); the generic member-spawn path used here must keep
  that sanctioned bypass for system-scoped role templates.

### 4.5 Readiness gate: DELETE (not move)

Delete the entire wait→kill→rollback gate from the bring-up path:
`gate_orchestrator_readiness`, `await_orchestrator_ready`,
`@orchestrator_readiness_timeout_ms`, `poll_orchestrator_ready`,
`kill_orchestrator`, the lifecycle subscribe/unsubscribe. **Keep** the durable
`LiveJoinRegistry` join-marking (`McpChannel.join/3`) and `Orchestrator.Health`
read as the pure status surface. The provisioning step does **not** wait for the
join.

**Delivery-time transport-readiness buffer (rev5 BLOCKER fix).** The deleted gate
also guaranteed that a message only reached a *bridge-joined* orchestrator.
`PendingDelivery` does NOT preserve this — it buffers only while the **Kind**'s
`ReadyGate` is `:not_ready`, but a bridge-backed agent (cc) can be Kind-ready
while its claude/MCP bridge has not joined (`LiveJoinRegistry.joined?` false). A
message dispatched in that window would reach a Kind-ready-but-bridge-dead agent
and silently vanish. rev5 therefore requires a **per-member transport-readiness
buffer for bridge-backed members**: a dispatch routed to such a member is held
until its bridge join is durably marked, then delivered; if the member is
declared dead / never joins, the send **fails visibly** (surfaced, not swallowed)
— never silently dropped. There is **no fixed timeout at create**; this is a
delivery contract, not a create gate. Two acceptable mechanisms (codex picks one,
prove with the test below):
  1. extend the bridge-backed agent's readiness so its `ReadyGate` does not flip
     to `:ready` until bridge-join — then existing `PendingDelivery` covers it
     uniformly (preferred if it doesn't widen the not-ready window for non-message
     dispatches); or
  2. a dedicated transport-readiness queue keyed on `LiveJoinRegistry`, drained on
     the bridge-join broadcast, with a visible-failure path for declared-dead
     members.
Required test: Agent Kind is `ReadyGate`-ready but `LiveJoinRegistry` never joins
→ assert the routed message is durably queued and eventually delivered on join,
or fails visibly — and is NEVER silently lost.

> Production-semantics to preserve (audit surprises #2/#3): the planned member URI
> must be written to the durable working copy BEFORE the live MCP join so the join
> can self-register. Under rev4 the member URI is written at provision time
> (spawn+join), before the agent's bridge connects — preserving the self-register
> ordering without any wait.

> Production-semantics to preserve (audit surprises #2/#3): the planned member URI
> must be written to the durable working copy BEFORE the live MCP join so the
> join can self-register (the `prestore_planned_orchestrator_uri` /
> `2026-06-15-live-orchestrator-mcp-registration-bug.md` concern). Under rev4 the
> member URI is written at provision time (when we spawn+join), before the agent's
> bridge connects — preserving the self-register ordering without any wait.

### 4.6 Caps for the role-member (carve-out)

Today the orchestrator's scoped caps are granted with `granted_by: owner_uri` but
**authorized via a genesis/system-backed tag** (`caps.ex tag_for/2`), NOT by the
owner delegating from caps they hold.

**rev5 routes role-member caps through the EXISTING fail-closed Role policy, not a
genesis carve-out (HIGH fix).** `Ezagent.Role` already materializes a role's
`requested_caps` through an explicit fail-closed `requested ∩ flavor/tenant
policy` step (`role.ex`: "a requested cap not permitted by policy is dropped, not
granted"). A provisioned role-member's caps therefore come from its
`Role.requested_caps` materialized through that fail-closed policy. The system
**orchestrator** role's caps (today's orchestrator scoped-cap set, currently
`OrchestratorRole.requested_caps == []` pending PR-2) are populated and
**whitelisted in the policy as a built-in system role**. Crucially:
**tenant-authored roles cannot obtain genesis-backed `behavior: :any` /
`{:spawned_by}` authority** — the fail-closed policy drops anything not
whitelisted. Negative tests must prove a tenant role declaring such caps gets them
dropped. The "owner truly delegates the `{:spawned_by}` cap" problem (#153/#154)
stays **out of scope** and separately deferred — this work neither solves nor
regresses it.

### 4.7 Status display + error surfacing

- World session view shows a non-blocking member/orchestrator-status badge from
  `Orchestrator.Health` (generalized to per-member) + `LiveJoinRegistry`. Send is
  never disabled by member status.
- `conversation_actions.ex send_message` surfaces dispatch errors instead of
  swallowing them into `data-last-dispatch` only.
- The "Restart orchestrator" action becomes "restart this member" → re-provision
  (spawn+join) the role-member; reuses the same provisioning primitive.

### 4.8 Future option (not v1)

If pre-warm is later wanted (orchestrator ready before the first routed message),
add an `on_ready`/`activated/2` "prepare declared members" trigger that calls the
SAME provision primitive eagerly. Designed-for, not built here.

## 5. The four concentrations (where the specialness lives)

The audit's 11 axes concentrate in four areas; structure the work around these:

1. **Create flow** (`SessionCreator`, `materializer`, `rollback`,
   `template_resolver`) — collapse the orchestrator arm into the pure path
   (§4.1); generalize team materialization to role-members; drop OTU readers.
2. **Readiness gate + MCP transport** (`Entity.Session.Orchestrator`,
   `OrchestratorReadinessPort`, `SessionManager`, cc `McpServer/McpChannel/
   McpSocket/McpRegistry/LiveJoinRegistry`) — DELETE the gate (§4.5); the MCP
   transport stays agent/plugin-layer (it already is); keep `LiveJoinRegistry` +
   `Health` as the status read.
3. **SessionTemplate field** (`session_template.ex`, `config_actions.ex`,
   `application.ex` seed, `config.exs`, `uri_query_resolvers`, `template_resolver`)
   — replace `orchestrator_template_uri` with a `role: orchestrator` member (§4.2);
   migrate data.
4. **Routing** (`template_team.ex`, `routing/rule_store`, `router`,
   `default_rules`) — role-targeted rules resolved at route-time + provision-on-
   route (§4.3/§4.4).

## 6. Data flow

```
create_session (any template)
  ├─[sync] Kind.spawn(Session)               # snapshot written in init
  ├─[sync] WorkspaceRegistry.bind
  ├─[sync] join OWNER (owner authority)
  ├─[sync] install role-targeted rules + legends + prompts + record member decls
  └─[sync] return {:ok, uri}                 # fast; no agent spawn / wait / rollback-on-orch

first message routed to role:orchestrator (e.g. a mention / default rule)
  └─ router resolves rule.target_role → live member?
       ├─ yes → deliver
       └─ no (declared but absent) → PROVISION (under create lock):
              spawn declared agent + join + install its role-targeted rules
              → deliver (buffers via PendingDelivery until agent ready; no wait)

member crashes → next route to its role re-provisions (self-heal)
cold restart → first route after restart re-provisions; nothing eager
status → Orchestrator.Health + LiveJoinRegistry (pure read, never blocks)
```

## 7. Error handling

- A provisioned member failing to spawn: the route's provision step returns an
  error for THAT delivery (logged/surfaced); the session + snapshot + other
  members are untouched; the next route retries. **Never** `rollback_session/3`.
- Partial provision (spawn ok, a later step fails): compensate ONLY that
  attempt's residue (the generic `compensate_spawned_members` + rule rows),
  leaving the session intact. (This is far smaller than the old ensure's residue
  surface because there is no readiness gate / SessionManager-before-members
  ordering to unwind.)
- Synchronous-create residue (snapshot/bind/owner-join): unchanged
  `rollback_session/3` — only this arm rolls back.

## 8. Migration

- Existing sessions whose working copy has `orchestrator_template_uri` set: a data
  migration converts it into a `role: orchestrator` member declaration; existing
  live orchestrators (already joined) are unaffected (they remain members).
- The default SessionTemplate seed is updated to the member form; re-seed is
  idempotent.

## 9. Supersedes prior specs

- `2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`: its
  create→orchestrator **atomicity + fail-loud readiness gate + rollback** are
  removed. Session-level atomicity (session + snapshot + bind + owner) is kept;
  the orchestrator is no longer part of the create transaction at all. The
  slice-unwrap / Lifecycle work in that spec is untouched.
- `2026-05-26-session-create-orchestrator-unified.md`: the "unified synchronous
  ensure" is replaced by provision-on-route.

## 10. Testing (each gate fails when the architectural goal is unmet)

1. **No-rollback invariant (would have caught PR #902):** a route/provision that
   FAILS to bring up the orchestrator leaves the session alive, snapshot present,
   `rollback_session` NOT invoked.
2. **Create within budget regardless of orchestrator:** `create_session` returns
   promptly even if the orchestrator template would hang on spawn (create no
   longer spawns it).
3. **Session usable immediately:** owner can send into a fresh session before any
   orchestrator exists; messages persist.
4. **Provision-on-route:** first message routed to `role: orchestrator` on a
   session with no live orchestrator spawns + joins it and delivers (buffered);
   asserts the member is now present.
5. **Idempotent / race-safe provision:** concurrent routes + manual restart for
   the same session yield at most one orchestrator; a live member short-circuits.
6. **Self-heal:** kill a joined orchestrator → next route to its role
   re-provisions.
7. **No boot storm:** provisioning is lazy — respawning M sessions spawns zero
   orchestrators until each is routed to.
8. **De-orchestrator-ization invariant (the completion gate):** an arch test
   asserting the **session domain has no `orchestrator`-named field/function/branch
   and no orchestrator-specific cap special-casing** (the §13 checklist
   mechanized — e.g. grep/AST gate over `ezagent_domain_session` excluding the
   role-member generic path). This is the test that fails if any specialness is
   left behind.
9. **Role-member health/status:** `Health` reports the orchestrator role-member's
   `:not_spawned/:alive/:crashed`; UI badge reflects it; send never blocked.
10. **Error surfacing:** a `send_message` dispatch error is surfaced, not only in
    `data-last-dispatch`.
11. **Cross-workspace spawn preserved:** a system-template role-member provisions
    into the tenant workspace (the sanctioned bypass still works).
12. **Transport-readiness (rev5 BLOCKER):** Agent Kind is `ReadyGate`-ready but
    `LiveJoinRegistry` never marks join → a routed message is durably held and
    delivered on join, OR fails visibly — and is NEVER silently lost. Positive:
    held message delivers once join is marked.
13. **Tagged receiver dual-read (rev5 HIGH):** a legacy untagged URI/magic
    receiver still routes unchanged; a `{:role, "orchestrator"}` receiver resolves
    (or provisions) at route-time; a bare role string never reaches `URI.new!`.
14. **Cap fail-closed (rev5 HIGH):** a tenant-authored role requesting
    `behavior: :any` / `{:spawned_by}` caps gets them **dropped** by the
    fail-closed `Role` policy (no genesis-backed grant); the system orchestrator
    role still receives its whitelisted caps.

All gates on PostgreSQL; `mix precommit` EXIT=0 authoritative. Because the
readiness path is compile-bypassed in `:test`, add an explicit
integration/e2e gate for provision-on-route + no-rollback so a regression of the
deleted-gate semantics is caught (deterministic unit tests alone will not).

## 11. Arch-invariant & baseline retargeting (in-scope deliverable — name for codex)

These WILL go red on the move and are part of the work:
- `im_session_agent_acyclic_test.exs` — allowlists must stay empty. The
  provision-on-route logic lives in routing (core) + the session domain
  (member/rule/legend materialization) and calls DOWN to the agent layer to spawn
  (session→agent, allowed); no agent→session dependency is introduced. Re-verify
  `@allowlist_session_to_mcp []` holds (the MCP transport stays agent/plugin-
  layer; the deleted readiness gate removes the session-side reference that
  `OrchestratorReadinessPort` was shielding — the port may now be removable; if
  so, delete it and its allowlist note).
- `oversized_modules_test.exs` + `arch_baseline_manifest.exs` —
  `def_count_orchestrator_tools`, `def_count_session_creator`, and any LOC caps
  shift; rebaseline with `# arch-cap-bump:` annotations.
- `uri_query/scan.ex` `:orchestrator_derivation` rule — retarget or delete (role-
  based member resolution replaces the `:orchestrator` UriQuery resolver).
- `ezagent.arch.scan.ex` / `check_invariants*.ex` — update orchestrator path
  registrations + the `@layer_vocab_words` "Orchestrator" entry if the namespace
  changes.

## 12. PR sequencing (green at each step — NOT one PR)

1. **PR-A** — role-member representation: add the `role: orchestrator` member to
   the default SessionTemplate ALONGSIDE the existing field (no behavior change);
   data migration; tests that both forms resolve.
2. **PR-B** — role-targeted routing rules: rules carry roles, resolve at route-
   time (dual-read old URI-resolved rules for back-compat during transition).
3. **PR-C** — provision-on-route primitive + lazy bring-up + the **delivery-time
   transport-readiness buffer** (§4.5 BLOCKER fix); route-time resolution uses it;
   create still also ensures (parallel) so this PR is independently verifiable.
   Tests 4, 5, 6, 7 + the bridge-ready-but-not-joined buffering test.
4. **PR-D (atomic flip — must retarget contracts in the SAME PR, HIGH fix)** —
   flip create to the pure path (drop the synchronous ensure arm) AND **delete**
   the readiness gate AND, in the same PR, retarget every consumer that asserts an
   eager orchestrator: the `create_session` return meta (drop required
   `orchestrator_status`), `Workspace.create_session` meta + CLI + `HomeLive` flash
   (drop the `:ready`/`:pending`/`:failed` orchestrator arms), and **Scenario-32
   G1** (from "owner AND orchestrator are members immediately after create" → "after
   the first route to `role: orchestrator`, the provisioned member is joined").
   Doing these together keeps CI green and prevents implementers from keeping an
   eager path to satisfy stale tests. Tests 1, 2, 3, 11.
5. **PR-E** — remove the special `orchestrator_template_uri` field + the
   `[owner,orchestrator]` arm + OTU readers; route role-member caps through the
   fail-closed `Role` policy (§4.6) + cap-escalation negative tests; generalize
   Health to role-member.
6. **PR-F** — de-orchestrator-ize naming + arch-invariant/baseline retargeting +
   the §13 completion-gate test (test 8); transport/`OrchestratorReadinessPort`
   cleanup.
7. **PR-G** — UI: status badge generalized + send-error surfacing + "restart
   member" (test 9, 10) + agent-browser E2E.

Each PR `mix precommit` EXIT=0 + check_invariants green.

## 13. De-orchestrator-ization checklist (completeness gate — from the full audit)

"Done" = every item below is resolved (no orchestrator-specialness left in the
session domain). Tags: MOVE→agent / GENERALIZE→member / DELETE / KEEP-rename /
MIGRATE-data.

**SessionTemplate field**: `orchestrator_template_uri` (type/`@config_atom_keys`/
working-copy default/plain-vs-orch comments) [DELETE→member]; `template_resolver
.orchestrator_template_uri_of` [GENERALIZE]; `uri_query_resolvers.resolve_orchestrator`
+ `:orchestrator` registration [GENERALIZE]; `config.exs default_orchestrator_template_uri`
+ `application.ex` seed + `agent_contract_g4.ex` fixture [MIGRATE-data];
`tools/templates.ex` snapshot of OTU [GENERALIZE].

**Create flow**: `finalize_fresh_session` orch arm + `ensure_orchestrated_session`
+ `ensure_orchestrator_and_finalize` + `[owner,orchestrator]` join +
`session_complete?` orch-readiness axis [DELETE/GENERALIZE]; `materializer`
`materialize_orchestrator_working_copy`/`store_session_orchestrator_uri`/
`prestore_planned_orchestrator_uri`/`grant_owner_orchestrator_*` [GENERALIZE/MOVE];
`rollback` orch teardown [GENERALIZE]; create-meta `orchestrator_status/_uri/_error`
+ workspace 3-state consumer + `home_live` `:pending` arm [GENERALIZE/DELETE-dead].

**Readiness gate + transport**: `Entity.Session.Orchestrator` gate/await/poll/kill
+ `@orchestrator_readiness_timeout_ms` [DELETE]; `OrchestratorReadinessPort`
[DELETE if now unreferenced, else KEEP]; `SessionManager` [MOVE→agent]; cc MCP
transport + `LiveJoinRegistry` + `cc_orchestrator_seed` [KEEP agent-layer];
`Health`/`owner_notifier` [GENERALIZE→member].

**Caps / tools / Session Kind**: `orchestrator/caps.ex` [GENERALIZE under §4.6];
`behavior/orchestrator_admin.ex` [GENERALIZE→member-admin]; `orchestrator/tools.*`
[KEEP-rename → session member tools]; `entity/session.ex` orch defdelegates +
`behavior/session.ex` orch-only gates + `config_actions.orchestrator_cap_present?`
+ `membership.grant_first_join_owner_cap` orch cap [GENERALIZE]; UI
`session.orchestrator.restart` [KEEP-rename].

**Hidden couplings to honor** (audit surprises): positional `[owner,orchestrator]`
(#1) → role lookup; `orchestrator_uri`-as-readiness-proof (#2/#3) → provision-time
write before join; deterministic `cc_orchestrator-<disc>` name (#5) → generic
member URI + role resolution; acyclic `OrchestratorReadinessPort` crutch (#7) →
re-derive after gate deletion; `:orchestrator_derivation` scan (#8) → retarget;
create-lock serialization (#9) → reused by provision-on-route; owner-delegation
cap #2 (#10) → out of scope (§4.6).

## 14. Open questions

None blocking. Resolved 2026-06-23 with Allen: pure create; orchestrator =
role-member; provision-on-route lazy (no reconciler); gate deleted; session-domain
placement; caps carve-out; on_ready prepare deferred. A `/codex:adversarial-review`
of rev4 runs before the handoff is finalized.
