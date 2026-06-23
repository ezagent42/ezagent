# De-orchestrator-ize the Session: Orchestrator as a `role` Member + Provision-on-Route — Design (rev6)

## 0d. What changed in rev6 (closes the rev5 adversarial-review: 1 BLOCKER + 2 HIGH — this is the handoff revision)

rev6 is the **final spec revision before codex implements**. It does NOT re-open
the approach (3 prior adversarial rounds converged; the rev5 findings were all
wiring-level, which is the convergence signal). It does three things:

1. **§4.5 transport-readiness — locked to candidate ① as a domain-agent readiness
   contract (closes the rev5 BLOCKER + answers Allen 2026-06-23).** The rev5
   BLOCKER was "the transport-readiness buffer has no concrete durability/failure
   contract." Allen's call: a **bounded readiness wait → `:failed`** is not a
   session-special buffer — it is *what the domain agent layer should already
   guarantee*. So rev6 fixes the mechanism (was "codex picks one of two"): a
   **bridge-backed agent's `ReadyGate` does not flip to `:ready` until its
   bridge/transport has durably joined** (`LiveJoinRegistry`), with a **bounded
   wait that, on timeout, transitions the agent to `:failed`**. The generic
   `PendingDelivery` (already keyed on Kind `ReadyGate`) then covers transport-
   readiness **uniformly** — the session domain gets **zero** transport-special
   code. Delivery either lands after join or **fails visibly** (`:failed`); the
   message is already persisted in the transcript, so nothing is silently lost.
   This is a **cross-layer touch** done **in this work** (agent layer): the 90s wait
   in `ezagent_domain_session` is DELETED; a bounded readiness wait is ADDED in
   `ezagent_domain_agent`. **Allen's intent (clarified same day):** "fully defer to
   domain.agent" means the contract *belongs in domain.agent* — and in THIS
   implementation codex **test-first discovers** the generic readiness code currently
   in `plugin_cc` (`LiveJoinRegistry`/`OrchestratorRole`, verified), **migrates it
   up** to `ezagent_domain_agent` (generalizing `orchestrator_uri`-keyed →
   `agent_uri`-keyed), **builds** the missing bounded-wait→`:failed` piece there, and
   **adds an anti-recurrence arch invariant** so readiness/transport-join-state
   primitives can never live in an `ezagent_plugin_*` again (§4.5). The #902 fix is
   independent of and not blocked by this migration.

2. **§4.3 tagged-receiver migration — corrected to match how receivers actually
   resolve today (closes a rev5 HIGH).** rev5 wrongly claimed a bare role string
   "would crash `URI.new!`." That is true for **persisted `RuleStore` receivers**
   (stored URI/magic strings) but FALSE for **template-authored `routing_rules`**:
   `template_team.ex` (`receiver_to_uri/2`, ~:360-383) ALREADY resolves a bare
   receiver string as **magic → role (`role_to_uri`) → URI**, so legacy
   SessionTemplate `routing_rules` bare role-names resolve as roles *today*. rev6
   separates the two layers explicitly: (a) template `routing_rules` bare role-
   names keep their current role meaning — the migration must NOT change them; (b)
   the new tagged form `{:role|:uri|:magic, _}` is for the **persisted RuleStore
   receivers** that are URI/magic today, with dual-read of legacy untagged strings
   as `{:uri,_}`/`{:magic,_}`. No receiver — template or persisted — silently
   changes meaning (§4.3).

3. **§4.6 cap policy — reframed as an explicit implementation decision for codex
   with a crisp invariant + mandatory test + code landmines (closes a rev5 HIGH).**
   The rev5 HIGH was "the fail-closed Role policy isn't actually wired." rev6 does
   not pretend it is. It states the **invariant** (tenant roles cannot mint
   genesis-backed authority; the system orchestrator role gets its whitelisted
   caps), names the three code landmines codex must resolve (`Role.CapMint` needs
   an INJECTED policy predicate; `OrchestratorRole.requested_caps == []` must be
   populated; the `caps.ex` genesis carve-out must be replaced by the policy path),
   lists candidate wirings, and makes the negative test the gate (§4.6, test 14).

The §13 audit checklist + the file:line landmines are folded into the **handoff
doc** as hard constraints for codex.

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
- **rev4 (carried forward through rev6)**: orchestrator is just a `role: orchestrator` member; the
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

**Tagged receiver schema (rev6 — corrected from rev5).** There are TWO distinct
receiver layers, and they resolve differently today; the migration must respect
both:

- **Template-authored `routing_rules`** (the `routing_rules` in a SessionTemplate's
  working copy): `template_team.ex receiver_to_uri/2` (~:360-383) ALREADY resolves
  a bare receiver string as **magic → role (`role_to_uri`) → URI** at materialize-
  time. So legacy SessionTemplate bare role-names (e.g. `"orchestrator"`) **already
  mean "the member with this role" today.** The migration MUST preserve this — a
  bare role-name in a template stays a role-target. What changes is *when* it
  resolves: route-time instead of materialize-time (so a not-yet-provisioned role
  resolves-or-provisions rather than requiring the member to exist at materialize).

- **Persisted `RuleStore` receivers** (`rule_store.ex receivers: {:array, :string}`,
  parsed via `Ezagent.URI.new!`; magic tokens the only non-URI form today): here a
  bare role string like `"orchestrator"` WOULD crash `URI.new!`. For this layer
  rev6 introduces a **tagged receiver form** — `{:role, name}` | `{:uri, uri}` |
  `{:magic, token}` — with a `RuleStore` schema/migration to persist the tag, a
  `Resolver` that dispatches on tag (role → resolve-or-provision at route-time;
  uri/magic unchanged), and UI/CLI validation. **Dual-read** during transition:
  legacy untagged persisted strings are read as `{:uri,_}`/`{:magic,_}` (their
  current meaning) so existing persisted rules keep working; only role-targeting
  requires the new tag.

**Invariant: no receiver — template-authored or persisted — silently changes
meaning.** A template bare role-name keeps resolving as a role (just later); a
persisted untagged string keeps resolving as URI/magic; only the new persisted
`{:role,_}` tag adds role-targeting to the RuleStore layer. (Test 13 covers both
layers.)

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

**Transport-readiness = a domain-agent readiness contract (rev6 — locked; closes
the rev5 BLOCKER, per Allen 2026-06-23).** The deleted gate also guaranteed that a
message only reached a *bridge-joined* orchestrator. The generic `PendingDelivery`
does NOT preserve this **as written today** — it buffers only while the **Kind**'s
`ReadyGate` is `:not_ready`, but a bridge-backed agent (cc) can currently be
Kind-ready while its claude/MCP bridge has not joined (`LiveJoinRegistry.joined?`
false). A message dispatched in that window would reach a Kind-ready-but-bridge-
dead agent and silently vanish.

rev6 closes this by **making bridge-join part of the agent's own readiness** rather
than building a session-special buffer. This is candidate ① (rev5 offered two;
rev6 picks ① and discards ②), and it is framed as what the **domain agent layer
should guarantee**:

> A **bridge-backed agent's `ReadyGate` does not flip to `:ready` until its
> bridge/transport has durably joined** (`LiveJoinRegistry`). The wait is
> **bounded**; on timeout the agent transitions to **`:failed`** (not silently
> stuck-not-ready). Until `:ready`, the generic `PendingDelivery` (already keyed on
> Kind `ReadyGate`) buffers any routed message; on `:ready` it drains; on `:failed`
> the buffered send **fails visibly** (surfaced, not swallowed).

Consequences:
- The session domain needs **zero** transport-special code — `PendingDelivery`
  covers transport-readiness uniformly because readiness now *includes* the bridge.
- Delivery is never silently lost: it lands after join, or fails visibly on
  `:failed`. The message is already persisted in the transcript, so a visible
  `:failed` loses nothing recoverable.
- There is **no fixed timeout at create** (create never waits); the bounded wait
  lives in the agent's own readiness lifecycle, off the create path.

**Two layers, two opposite operations — keep them straight.** The 90s readiness
wait in `ezagent_domain_session` (`Entity.Session.Orchestrator`) is **DELETED**
(above). A *bounded* readiness wait is **ADDED** in `ezagent_domain_agent` as the
generic agent readiness contract. These are different modules in different layers:
do NOT re-create a session-side wait to satisfy the contract — the session never
waits.

**Migrate-to-domain-agent, test-first (Allen 2026-06-23 — IN SCOPE for this work,
not a separate effort).** The readiness primitives live in the **wrong layer
today**: `LiveJoinRegistry` and `OrchestratorRole` both sit in `ezagent_plugin_cc`
(verified 2026-06-23: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/
live_join_registry.ex`, `.../orchestrator/orchestrator_role.ex`). The readiness
contract is a **generic domain-agent property** (any bridge-backed agent, not just
cc), so it belongs in `ezagent_domain_agent`. **Codex must, test-first:**
  1. **Discover** via tests: write the test in `ezagent_domain_agent` expressing the
     generic readiness contract (bridge-backed agent not ready until transport-join;
     bounded wait → `:failed`). It FAILS — some pieces are in `plugin_cc`, some don't
     exist yet. (Don't pre-classify "migrate vs build"; the failing test reveals it.)
  2. **Migrate** what exists up from `plugin_cc`, **build** what's missing, both
     driven by the failing test. The join-registry migration is a **generalization,
     not a verbatim copy**: it is orchestrator-keyed today (`orchestrator_uri`) and
     must become **agent-keyed (`agent_uri`, any bridge-backed agent)** — copying it
     as-is would carry forward the orchestrator-specialness this work deletes.
  3. The flavor-specific transport adapter (the actual cc MCP socket/channel) STAYS
     in `plugin_cc`; only the *generic readiness contract* moves up. The
     bounded-wait→`:failed` transition + the new failed/never-joined signal (which
     `LiveJoinRegistry` lacks today) are authored **in `ezagent_domain_agent`**.
  4. **Acyclic stays clean**: `plugin_cc → ezagent_domain_agent` is the *existing*
     dependency direction (plugins depend on domains), so moving generic code up and
     leaving the cc MCP adapter down introduces **no** cycle. Re-verify, don't
     re-litigate.

**Anti-recurrence guard (Allen 2026-06-23 — the point of doing this in-work).** To
stop generic capability from re-accreting in a single plugin, add a narrow,
mechanically-checkable arch invariant: **readiness / transport-join-state primitives
must live in `ezagent_domain_agent`, NOT in any `ezagent_plugin_*`.** Concretely, a
grep/AST gate (extend `ezagent.arch.scan.ex` / `check_invariants`) that fails if a
join-state registry / readiness-gate / bounded-wait-to-`:failed` construct is
defined under any `apps/ezagent_plugin_*/`. This is the fitness function that keeps
the migration from silently regressing. **Allen-confirmed 2026-06-23: readiness /
transport-join-state ONLY for now; broadening to other generic capabilities is
deferred to future work.**

**Decouple correctness is independent of the readiness migration.** The #902 fix —
create never rolls back / the snapshot is never deleted for a hung member, and the
message persists in the transcript — holds **on its own**, before and regardless of
the readiness work. The readiness migration is bundled into the same work (PR-C) to
close the silent-loss window AND relocate the generic contract + guard recurrence;
but the PR sequencing stays honest: the #902 fix (PR-D) does not *block* on the
migration landing perfectly. If the domain.agent effort lands an equivalent contract
first, codex reuses it.

**Codex verification point (re-added from rev5's candidate-① caveat):** making a
bridge-backed agent's `ReadyGate` stay `:not_ready` until bridge-join widens the
not-ready window for **every** dispatch to that agent, not just routed messages.
Confirm this does not strand any non-message dispatch (e.g. control/lifecycle
calls) that must reach the agent before its bridge joins. If any such dispatch
exists, it must either be exempt from the transport-gate or also buffer safely —
prove it with a test. (This is why ① was "preferred *if it doesn't widen the
window for non-message dispatches*"; verify, don't assume.)

> **Implementation landmines for codex (must honor):**
> - `PendingDelivery` (`pending_delivery.ex` ~:35-45) + `invocation.ex` (~:155-158)
>   buffer **only** on Kind `ReadyGate` `:not_ready` and return `:ok`. Do NOT add a
>   second buffer; instead make the bridge-backed `ReadyGate` stay `:not_ready`
>   until join so this existing path covers it.
> - `LiveJoinRegistry` (`live_join_registry.ex` ~:81-117) today exposes ONLY
>   `mark_joined`/`joined?`/`clear` — **no failed / never-joined signal**. The
>   bounded-wait→`:failed` transition is NEW; it must emit a signal the readiness
>   lifecycle consumes to flip the agent to `:failed`.
> - Kind readiness flips in `kind/server.ex` (`on_ready`/`activated` after the
>   `ReadyGate` flip, ~:296-328); the bridge-backed extension must hook the gate
>   flip itself (gate stays not-ready), NOT `on_ready` (which runs AFTER ready).

Required test (test 12): Agent Kind would be `ReadyGate`-ready but
`LiveJoinRegistry` never marks join → assert the routed message is durably held and
(a) delivered once join is marked, or (b) fails visibly when the bounded wait
elapses and the agent goes `:failed` — and is **NEVER** silently lost.

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

**rev6 — this is an implementation decision for codex, not a claim that the wiring
exists.** rev5 asserted the caps "route through the existing fail-closed Role
policy"; the rev5 review correctly found that policy is **not actually wired** for
this. rev6 states the invariant + the candidate wiring + the landmines, and makes
the negative test the gate. Codex chooses and proves the wiring during
implementation.

**Invariant (the gate, test 14):**
- The system **orchestrator** role receives its scoped caps (today's orchestrator
  cap set) when provisioned as a role-member.
- A **tenant-authored** role declaring `behavior: :any` / `{:spawned_by}` /
  genesis-backed authority gets those caps **dropped** — it cannot mint genesis
  authority by naming it in `requested_caps`.

**Candidate wiring (codex picks, must satisfy the invariant):** `Ezagent.Role`
already has a fail-closed `requested ∩ policy` materialization shape (`role.ex`
~:22-28: "a requested cap not permitted by policy is dropped, not granted"). The
intended path is: a provisioned role-member's caps = its `Role.requested_caps`
materialized through a fail-closed policy that **whitelists the system orchestrator
role** and drops un-whitelisted genesis-backed requests.

**Code landmines codex MUST resolve (this is why it's "not wired" today):**
- `Role.CapMint` (`role/cap_mint.ex` ~:42-48) needs an **INJECTED policy
  predicate** — it does not have a built-in policy. Codex must supply/inject the
  fail-closed policy; do not assume `CapMint` enforces one on its own.
- `OrchestratorRole.requested_caps == []` today — it must be **populated** with the
  orchestrator scoped-cap set for the role-member path to grant anything.
- `caps.ex` currently grants the orchestrator caps via a **genesis/system-backed
  tag carve-out** (`tag_for/2`, direct genesis grants ~:63-73,140-148,163-181).
  That carve-out must be **replaced** by the policy path (or the role must be
  whitelisted in the policy and the carve-out removed) — otherwise the "tenant
  can't mint genesis" invariant is bypassable and the de-orchestrator-ization is
  incomplete.
- `Role` (`role/compose.ex`) does NOT currently handle caps — confirm where cap
  materialization actually runs before wiring the policy.

**Out of scope (unchanged):** the "owner truly delegates the `{:spawned_by}` cap"
problem (#153/#154) stays deferred — this work neither solves nor regresses it.
The orchestrator role-member keeps today's system/genesis-backed *authority basis*;
rev6 only requires that tenant roles cannot reach it through `requested_caps`.

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
   McpSocket/McpRegistry/LiveJoinRegistry`) — DELETE the session-side gate (§4.5);
   the cc **MCP socket/channel** stays in `plugin_cc`; but the **generic readiness
   contract** (`LiveJoinRegistry`'s join-state, generalized to `agent_uri`, +
   bounded-wait→`:failed` + `Health`) **migrates up to `ezagent_domain_agent`**
   (test-first), with an anti-recurrence arch invariant barring such primitives from
   any `ezagent_plugin_*` (§4.5).
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
15. **Readiness-in-domain-agent anti-recurrence invariant (Allen 2026-06-23):** an
    arch test (grep/AST gate in `ezagent.arch.scan.ex` / `check_invariants`) that
    **fails** if a join-state registry / readiness-gate / bounded-wait-to-`:failed`
    construct is defined under any `apps/ezagent_plugin_*/`. After the migration the
    generic readiness contract lives in `ezagent_domain_agent`; this gate keeps it
    from re-accreting in a plugin. The migrated `LiveJoinRegistry` is **agent-keyed
    (`agent_uri`)**, not orchestrator-keyed — assert the generalization too.
    **Scope (Allen 2026-06-23, confirmed):** this invariant is intentionally narrow
    — **readiness / transport-join-state only** for now. Broadening it to other
    generic agent capabilities is deliberately deferred to future work; do not
    over-generalize the gate now (a too-broad fitness function fires on everything).

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
  `@allowlist_session_to_mcp []` holds (the cc MCP socket/channel stays in
  `plugin_cc`; the deleted readiness gate removes the session-side reference that
  `OrchestratorReadinessPort` was shielding — the port may now be removable; if
  so, delete it and its allowlist note). The readiness migration moves generic code
  `plugin_cc → ezagent_domain_agent` — the **existing** dependency direction
  (plugins depend on domains), so it introduces **no** cycle; re-verify, don't
  re-litigate.
- `oversized_modules_test.exs` + `arch_baseline_manifest.exs` —
  `def_count_orchestrator_tools`, `def_count_session_creator`, and any LOC caps
  shift; rebaseline with `# arch-cap-bump:` annotations.
- `uri_query/scan.ex` `:orchestrator_derivation` rule — retarget or delete (role-
  based member resolution replaces the `:orchestrator` UriQuery resolver).
- `ezagent.arch.scan.ex` / `check_invariants*.ex` — update orchestrator path
  registrations + the `@layer_vocab_words` "Orchestrator" entry if the namespace
  changes.
- **NEW invariant (not a retarget) — readiness lives in `domain_agent`, never a
  plugin (Allen 2026-06-23):** add a grep/AST gate that fails if a join-state
  registry / readiness-gate / bounded-wait-to-`:failed` primitive is defined under
  any `apps/ezagent_plugin_*/`. This is the anti-recurrence fitness function for the
  readiness migration (test 15). Allen-confirmed 2026-06-23: readiness-only for now;
  broadening deferred.

## 12. PR sequencing (green at each step — NOT one PR)

1. **PR-A** — role-member representation: add the `role: orchestrator` member to
   the default SessionTemplate ALONGSIDE the existing field (no behavior change);
   data migration; tests that both forms resolve.
2. **PR-B** — role-targeted routing rules: rules carry roles, resolve at route-
   time (dual-read old URI-resolved rules for back-compat during transition).
3. **PR-C** — provision-on-route primitive + lazy bring-up + the **readiness-contract
   migration** (§4.5): test-first move the generic join-state/readiness from
   `plugin_cc` → `ezagent_domain_agent` (generalized to `agent_uri`), build the
   bounded-wait→`:failed` piece there, so the generic `PendingDelivery` covers the
   bridge-ready-but-not-joined window. Route-time resolution uses it; create still
   also ensures (parallel) so this PR is independently verifiable. Tests 4, 5, 6, 7,
   12 (+ the anti-recurrence gate test 15 may land here or in PR-F).
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
   the §13 completion-gate test (test 8) + the **readiness-in-domain-agent
   anti-recurrence gate (test 15)** if not already in PR-C;
   transport/`OrchestratorReadinessPort` cleanup.
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
placement; transport-readiness = a **domain-agent readiness contract** (bridge-
backed `ReadyGate` waits for bridge-join, bounded → `:failed`, candidate ①);
on_ready prepare deferred.

**Review status:** four spec revisions went through three `/codex:adversarial-review`
rounds (rev1→rev2→rev4→rev5); findings converged from approach-level to wiring-level
(the convergence signal). Per the advisor, the spec↔review loop stops at rev6 — the
remaining wiring decisions (§4.5 readiness contract, §4.6 cap policy) are
**implementation decisions for codex**, gated by the mandatory tests (12, 14), and
are the right thing for codex to self-review during implementation. **No 4th
adversarial review of the spec.** The handoff doc carries the file:line landmines as
hard constraints.
