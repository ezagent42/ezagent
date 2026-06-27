# Research — is `role` a cross-principal concept? Should there be a `domain.role`?

> **Research + recommendation, NOT implementation.** Skills loaded:
> `ezagent-developer`, `ezagent-socialware`. All code citations verified against
> `origin/main` (`37b71aae`). Worktree off `origin/main`; branch
> `docs/domain-role-research`. Codex adversarial-review record in §9.
>
> **Question (lead's):** we are relocating `RoleRegistry` `ezagent_core →
> ezagent_domain_agent`. The lead asks whether `role` is actually *broader than
> agents* — a named **responsibility/authority a PRINCIPAL (human OR agent)
> holds**, used to route approvals/confirmations/arbitration — and whether it
> should become a dedicated cross-principal **`domain.role`** rather than living
> in `domain.agent`.
>
> **Motivating scenario (lead's):** cc finishes code → needs a `reviewer`
> role-holder to authorize the merge; two role-holders (one human user, one
> agent) give OPPOSITE verdicts → cc escalates to an `arbiter` role to decide.

---

## 0. TL;DR (the verdict)

1. **The word `role` already covers TWO distinct concepts in the codebase, not
   one.** They share a word, not a meaning.
   - **A — the agent RECIPE** (`Ezagent.Role`): a flavor-agnostic *build-time*
     sandbox-content recipe (`skills/plugins/prompt/script/behaviors/
     requested_caps/session_template`). It is *the contents that fill an agent's
     `config_dir` sandbox.* This is what `RoleRegistry` resolves and what the
     in-flight role-as-data work governs.
   - **B — a principal-held LABEL/RESPONSIBILITY** (session-membership
     `role_name` + routing `{:role, name}`): a *runtime* attribute a member
     (user OR agent) carries, used to route messages by name.

2. **Does the agent-recipe role (A) fit a human user? NO.** A human has no
   prompt/skills/behaviors/script/`config_dir`. Recipe-role is *agent-specific by
   construction* — it literally is "the contents of the sandbox". A and a
   human-role are **not the same concept**; they are a homonym.

3. **The lead's scenario lives entirely in B-land, not A-land.** "Find the
   reviewer by role, route a confirmation, collect verdicts, escalate to an
   arbiter" is membership-label + routing + caps — it never touches the agent
   recipe.

4. **But B today is narrower than the scenario needs.** B splits into:
   - **B1 (exists):** per-session, **single-holder**, **single-resolve** routing
     alias. `role_name` is **unique per session** and `{:role, name}` resolves to
     **exactly one URI**. Cross-principal already (user or agent member).
   - **B2 (NEW — what the lead wants):** a **workspace-scoped, MANY-holder**
     principal→responsibility assignment + **approval authority** (caps) +
     **verdict-collection/arbiter** rules. *Two disagreeing reviewers cannot even
     exist under B1's unique-per-session invariant* — so the scenario is genuinely
     new state, not a thin wrapper over B1.

5. **Recommended home: NOT a new `domain.role`.**
   - The **agent recipe (A) stays in `domain.agent`** (the in-flight relocation),
     converging on the role-as-data ConfigObject (`config://<ws>/role/<name>`).
   - The **responsibility concept (B2) splits across EXISTING apps** (corrected
     after codex caught a dep-cycle): durable principal→responsibility
     **assignment → `domain_workspace`** (where role caps already live); the
     **approval/quorum/arbiter workflow → `domain_session`** (the only app with
     message replies + membership; it already deps on workspace, so hosting the
     workflow in workspace would CYCLE). Built on existing primitives: membership,
     identity caps, routing — plus a new assignment↔cap lifecycle and an
     assignment-gated routing boundary.
   - A dedicated `domain.role` does **not** earn its existence today (YAGNI). The
     revisit trigger: if B2's principal→responsibility assignment outgrows a
     workspace facet (cross-workspace responsibilities, a role lifecycle of its
     own).

6. **The relocation is a clean stepping-stone, not a wasted step.** The recipe
   registry is *orthogonal* to B2 (B2 never reads a recipe). De-coring it next to
   the Agent Kind that consumes it is correct regardless of how B2 lands.

---

## 1. The two concepts, precisely

### 1.1 A — Role-as-recipe (`Ezagent.Role`) — agent-only, build-time

`apps/ezagent_core/lib/ezagent/role.ex` (moving to `ezagent_domain_agent`):

```elixir
defstruct name: nil, passive: false, skills: [], plugins: [], prompt: nil,
          script: nil, behaviors: [], requested_caps: [], session_template: nil
```

Its own moduledoc states what it is:

> "The CONTENTS of the sandbox are the ROLE; HOW the sandbox is loaded is the
> FLAVOR." … "what fills an agent's `config_dir` sandbox — skills, plugins, a
> system-prompt persona, an optional operator-authored `script` …, the behavior
> subset it runs, the caps it **requests**, and a **reference** to a
> session-template."

Every field is an **agent build input**. `requested_caps` are *requested*, minted
at materialization (`Role.CapMint`), granted by the instantiating caller
(`{:held_by, caller}`) — **not** caps the role "holds". `Role.new/1` even rejects
flavor fields and cap materialization axes. A human user has none of: a system
prompt, a skill set, a behavior subset, a `config_dir`, a script. **The recipe
shape cannot describe a human.** It is not "a role a human could hold" — it is a
manufacturing spec for an agent's sandbox.

- `RoleRegistry` (`apps/ezagent_core/lib/ezagent/role_registry.ex`): a
  `name → %Role{}` ETS map seeded from each plugin's `roles/0` callback. This is
  what is being relocated to `ezagent_domain_agent` (`Ezagent.Agent.RoleRegistry`),
  and what the role-as-data spec converts to a ConfigStore read-through (§5).
- Consumers: `RoleStep` (agent create), `OrchestratorBootstrap` — both *instantiate
  an agent from a recipe*. No human-user consumer exists or is conceivable.

### 1.2 B — Role-as-responsibility (membership `role_name` + routing) — cross-principal, runtime

This concept **already spans users AND agents** and **already lives outside
`domain.agent`** (in `domain_session` + `ezagent_core` routing). It has nothing
to do with the recipe.

**B1 — what exists today:**

- **Membership facet.** A session member is `{URI, meta}`; `meta` may carry an
  optional `:role_name` (`apps/ezagent_domain_session/lib/ezagent/behavior/
  session/members.ex`, `put_member_facets/2`). The member URI may be a **user**
  (`entity://<ws>/user/<name>`) or an **agent** (`entity://<ws>/agent/<flavor>_<name>`)
  — `role_name` is assigned identically to both; there is no type-guarding.
  (team-routing-unification §3.1 §8 decision #2: "`role_name` … stable human alias …
  decoupled from URI … survives respawn".)
- **Routing by role.** A routing rule's receiver can be `{:role, role_name}`
  (`apps/ezagent_core/lib/ezagent/routing/receiver.ex`); the resolver expands it
  via a `role_resolver` function
  (`apps/ezagent_core/lib/ezagent/routing/resolver.ex` `expand_receiver/…`),
  wired in `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` (≈L498)
  to `RouteProvisioner.resolve_role/4`. Approvals/confirmations *are* messages, so
  routing-by-role is exactly the delivery primitive the scenario needs.

**Two hard limits of B1** (load-bearing — they are why the scenario is new state):

1. **Single-holder.** `role_name` is **UNIQUE PER SESSION** —
   `Members.role_name_conflict/3` rejects a second member claiming a held
   `role_name`. The lead's scenario has **two `reviewer`s** (a human + an agent)
   *disagreeing*. That configuration **cannot exist** under B1.
2. **Single-resolve.** `{:role, name}` expands to **exactly one URI**
   (`%URI{} -> [uri]`; `nil -> []`). Routing-by-role today is single-target, not
   "fan-out to all holders of role X".

So B1 is a *per-session, single-holder, single-resolve routing alias*. Useful,
cross-principal — but not the lead's multi-holder/quorum machine.

### 1.3 Why one name over both (A+B) is forced, not clean

The lead's proposed unifier was: *"role = a named cap-bundle a principal holds,
where agent-roles additionally carry a recipe and user-roles carry
approval-authority."* The lure is "both involve caps." But the caps are at
**different lifecycle phases**:

| | A (recipe) | B2 (responsibility) |
|---|---|---|
| caps are… | **requested**, consumed at *mint*, granter = caller, **build-time** | **standing held** caps in the principal's identity slice, **runtime** |
| held by… | nobody (the recipe is a template) | the principal (user or agent) |
| describes… | how to *manufacture* an agent sandbox | what a *live principal* is responsible/authorized for |

The "named cap-bundle a principal holds" unifier **fits B2** — and indeed already
half-exists: **every Entity Kind (User AND Agent) carries an `:identity` slice
holding `caps :: MapSet.t(Capability.t())`** (`Ezagent.Behavior.Identity`,
Decision #24). But that same unifier **mis-describes A**, whose `requested_caps`
are not held by anyone. A and B differ by *lifecycle phase* (build template vs
runtime attribute), which is precisely why forcing one `role` concept (and one
`domain.role`) over both is a forced fit. **Name them apart; do not unify the
storage.**

---

## 2. Does the current (recipe) shape fit a human? — explicit answer to Q1

**No.** Q1 asked whether the agent-recipe role shape fits a human user. It does
not: a human has no prompt/skills/behaviors/script/`config_dir`, and the recipe
is *defined* as the sandbox contents of an agent. A "user-role" in the lead's
sense is a **different shape**: a *responsibility name + approval authority +
assignment*, i.e. B2. **agent-role and user-role are a shared WORD, not a shared
concept.** The right move is two names, not one generalized struct.

---

## 3. The approval / confirmation / arbitration routing — design sketch (Q3)

The scenario decomposes into four needs. Three are already-available primitives;
one (assignment) needs new state; one (quorum/arbiter) needs a new Behavior.

### 3.1 "Find the principal(s) holding role X in this workspace/session"

- **Today (B1):** single holder, per session, via membership `role_name` +
  `role_resolver`. Sufficient for "the one reviewer of this session".
- **Needed (B2):** *many* holders, workspace-scoped. **New state: a
  principal→responsibility assignment** that is (a) **many-to-many** (a
  responsibility has N holders; a principal holds M responsibilities) and (b)
  **workspace-scoped** (so "find THE reviewers" spans sessions in the workspace,
  not one session). Note the existing analog for the recipe side:
  `AgentRoleResolver.list_by_role/2` already does a workspace-scoped *list by
  role* — but over agent **recipe**-role snapshots, not principal assignments; it
  is a model to mirror, not reuse.

### 3.2 "Route a confirmation to them, collect verdicts"

- **Route — NOT a simple fan-out tweak (codex HIGH, valid).** `{:role, name}`
  would be generalized from single-resolve to **fan-out over all holders** (return
  `[uri]`, not one). But this **crosses a trust boundary** the routing code treats
  as security-critical: the resolver applies a hard membership filter to
  `$session_users`/`$mentions`, whereas `{:role, name}` passes its resolver result
  straight through, and **session delivery mints a narrow `:receive` cap per
  recipient it is handed** (`Delivery`). A naïve workspace-wide fan-out would then
  either (a) be unable to reach holders outside the current session, or (b) hand
  non-session / stale / cross-scope principals to delivery and mint `:receive`
  caps for them — a tenant-isolation hole. So B2 routing **must define its own
  receiver trust boundary**: a same-workspace check + *assignment* validation (the
  recipient genuinely holds the responsibility **now**) before delivery, with
  session-local vs cross-session delivery decided explicitly, plus tests proving
  delivery cannot mint `:receive` caps for unassigned/out-of-scope principals.
  This is **new gated machinery**, not a one-line `expand_receiver` change.
- **Collect verdicts:** **NEW** — there is no primitive that gathers N replies and
  evaluates a quorum. This is an **approval Behavior** (a workflow) holding
  request state `{cr/subject, required_role, holders, verdicts, policy}` and a
  reply-context binding so a holder's verdict maps back to the request. Because it
  needs **session message replies + session membership/routing context**, it
  belongs on the **Session Kind** (`domain_session`) — NOT the Workspace Kind; the
  dep-DAG forces this (§4.2). Not a new domain or Kind.

### 3.3 "Approval authority"

This is **caps**, not new machinery — but with two refinements codex correctly
flagged.

- **The accountable-granter guarantee comes from the GRANT PATH, not the runtime
  predicate (codex MED, corrected).** `Capability.granted_by_entity?/1` is a
  **narrow no-`system://` backstop** (`capability.ex:319-320`: it rejects only
  `granted_by: %URI{scheme: "system"}` and returns `true` for everything else). The
  real "every cap traces to a real entity" invariant (#154) is enforced at the
  **grant chokepoint** `Ezagent.Identity.Grant.prepare/4`, which overwrites
  `granted_by` and validates it is `%URI{scheme: "entity"}`, else
  `{:error, {:granter_not_entity, …}}`. So B2's approval caps are accountable
  **iff they are minted through `Identity.Grant`** — that is the invariant B2 must
  use, not the runtime predicate alone.
- **Caps are NOT bundled by role today — the assignment↔cap lifecycle is NEW
  (codex MED, valid).** Identity caps are a flat `MapSet` keyed by capability
  identity; grant/revoke dedup by cap identity, **not** by role assignment. So
  assigning `reviewer` does **not** auto-grant an `approve` cap, and *un*assigning
  it does **not** auto-revoke one. B2 must therefore own an explicit
  **assignment↔cap binding** (grant the bundle on assign, revoke on unassign) **or**
  a hard invariant that **verdict acceptance re-checks current assignment AND
  current cap atomically** (so a stale or unauthorized holder's verdict is
  rejected). "Approval authority needs no new concept" was too strong: the *cap
  primitive* is reused (held in the identity slice, cross-principal), but the
  **role→cap lifecycle** is new state B2 must specify.

### 3.4 "Escalate to an arbiter role on conflict"

- The conflict detector lives in the approval Behavior (§3.2): when collected
  verdicts disagree (or quorum fails), it **opens a follow-on approval request
  targeting the `arbiter` responsibility** — the *same* routing-by-role +
  collect-verdict machinery, one level up. Escalation is recursion over the same
  primitive, not a special path.

### 3.5 Mapping against existing primitives (Q3 explicit)

| Need | Existing primitive | Gap |
|---|---|---|
| principals in sessions/workspaces | session/workspace **Membership** (`{URI, meta}`, user+agent) | none for membership; B2 wants a *workspace-scoped, many-holder* assignment table — **new** |
| name a responsibility on a principal | membership `:role_name` facet (B1) | unique-per-session, single-holder — **must relax for B2** |
| approval authority | **CapBAC** held caps in identity slice (user+agent), accountable via `Identity.Grant` | cap primitive reused; **role→cap lifecycle binding is new** (caps are flat, not role-bundled) |
| route an approval to role-holders | routing `{:role, name}` + `role_resolver` (B1) | single-resolve **and bypasses the membership trust boundary** — fan-out needs a NEW gated receiver boundary (§3.2) |
| collect verdicts / quorum / arbiter | — | **new approval Behavior** on the Session Kind (workflow + reply-context) |
| transport to a holder | agent↔session call / user delivery render | none (reused) |

**Is "role" partly already a cap-bundle on Membership?** *Partly yes for B2:* a
member already (a) is a principal in a session/workspace, (b) can hold caps in its
identity slice, and (c) can carry a `role_name`. But B2 is **more** than
cap-bundles-on-Membership: it adds (i) a **many-holder, workspace-scoped
assignment** (today's caps/`role_name` don't model "N principals share
responsibility R"), (ii) an **assignment↔cap lifecycle** (caps are flat, not
auto-bundled per role — §3.3), (iii) a **gated fan-out receiver boundary**
(§3.2), and (iv) a **quorum/arbiter Behavior** with verdict state. So B2 is NOT
"just cap-bundles on Membership", but it also does NOT need a new app — the new
state is an assignment binding + a Behavior, hosted in existing apps (§4).

---

## 4. `domain.role` vs `domain.agent` — the home (Q4)

### 4.1 Dep-DAG of each concept

- **A (recipe):** depends on identity (ConfigStore subject), the Agent Kind, plugin
  `roles/0`. It is *about manufacturing an agent*. Home = **`domain.agent`** (the
  in-flight relocation) → dissolving into ConfigStore per role-as-data. ✔
- **B2 (responsibility):** depends on **identity** (the principal + its caps),
  **membership** (who is in the workspace/session), **caps/#154** (approval
  authority + accountable granter), **routing** (deliver by role). It explicitly
  does **NOT** depend on the agent recipe. So **B2 must not live in
  `domain.agent`** — that would (a) wrongly couple a cross-principal concept to the
  agent app and (b) re-entangle the very thing the de-core move is separating.

### 4.2 The home: SPLIT across existing apps (corrected per codex HIGH on the dep-DAG)

> **Correction (codex HIGH, verified):** the actual umbrella deps run
> **`ezagent_domain_session` → `ezagent_domain_workspace`** (session's `mix.exs`
> lists `ezagent_domain_workspace`; workspace's `mix.exs` lists only `core`,
> `domain_agent`, `domain_identity` — it does **NOT** depend on session). So the
> draft's "put the approval/quorum Behavior in `domain_workspace`" would create a
> **cycle**: the quorum workflow needs session replies + session
> membership/routing, which only `domain_session` has. The home must be **split**.

- **Durable principal→responsibility assignment → `domain_workspace`** (Workspace
  Kind). It is workspace-scoped governance of *who holds responsibility R in this
  workspace*, a sibling to the role-authoring caps the role-as-data spec already
  puts there (`:author_role`, next to the shipped `:add_template`/
  `:remove_template`). A new **`:assign_role`** workspace cap gates assignment.
  Workspace already deps on identity (#154 caps) — no new edge.
- **Session-scoped approval/quorum/arbiter Behavior → `domain_session`** (Session
  Kind). It needs message replies, membership, routing context, and verdict state
  — all of which live in or below `domain_session`, which **already** deps on
  `domain_workspace` + `domain_identity` + `core` routing. So it READS the
  workspace assignment (allowed by the existing session→workspace edge) and uses
  session routing/delivery. No new edge, no cycle.
- **Fan-out receiver boundary → `ezagent_core` routing** (the `{:role, name}`
  expansion), but gated by the assignment validation described in §3.2.
- **No new `ezagent_domain_role` app.** A new app would need deps on identity +
  membership + caps + routing and would pull the recipe-role too (forcing the
  homonym back together). The split across the two existing Kinds (workspace owns
  the assignment, session owns the workflow) respects the real dep direction and
  buys nothing less than a new app would, with no extra surface.

**When `domain.role` WOULD earn existence (revisit trigger):** if
principal→responsibility assignment grows a real lifecycle of its own —
cross-workspace responsibilities, responsibilities as first-class addressable
objects with their own governance, or assigning responsibilities to principals
that are not workspace members. Until then, it is YAGNI; the workspace-assignment
+ session-workflow split is the honest model.

### 4.3 Dep-DAG implication summary (corrected)

```
ACTUAL umbrella edges (verified): domain_session ──> domain_workspace ──> domain_identity, core
                                  domain_workspace ──> domain_agent

domain.agent      : recipe-role A (ConfigStore subject, Agent Kind)            [in-flight]
domain_workspace  : B2 durable assignment + :assign_role cap   (reads domain_identity caps)
domain_session    : B2 approval/quorum/arbiter Behavior        (reads workspace assignment,
                                                                 uses session routing/delivery)
core/routing      : {:role, name} fan-out + assignment-gated receiver boundary
```

The split places the assignment where workspace already owns role caps and the
workflow where session already owns replies/membership — **no new edge, no
cycle, no new app**; recipe (A) and responsibility (B2) stay in separate apps,
matching their separate concepts.

---

## 5. Migration path (Q5)

**The in-flight `domain.agent` relocation is a clean stepping-stone, NOT a wasted
step**, because B2 never touches the recipe registry.

1. **Finish the recipe relocation as planned** (`RoleRegistry` →
   `ezagent_domain_agent` / `Ezagent.Agent.RoleRegistry`; in the in-flight branch
   it also gains a ConfigStore read-through per the role-as-data CR spec). This is
   *concept A* and is correct on its own merits (registry next to the Agent Kind
   that consumes it; de-core).
2. **Do NOT rename or re-home anything for B2 yet.** B2 is additive: a
   workspace-scoped assignment (`domain_workspace`) + a session-scoped approval
   Behavior (`domain_session`) + an assignment-gated routing fan-out
   (`core/routing`). It reuses identity caps and membership unchanged.
3. **Disambiguate the vocabulary** (cheap, high-value): in docs and any new code,
   call A the **agent recipe / role-recipe** and reserve the bare word **role**
   (or "responsibility") for B. The two `role`s under one word is the root of the
   lead's question; naming them apart prevents the next person re-asking it.
4. **Sequencing if B2 is built:** (a) relax `role_name` from unique-per-session OR
   add the workspace-scoped many-holder assignment alongside it; (b) generalize
   `{:role, name}` expansion to fan-out; (c) add the approval/quorum Behavior with
   reply-context; (d) arbiter escalation as recursion over (b)+(c). Each step is
   independently shippable and gated by existing caps.

**Nothing in the relocation needs to be undone for B2.** If a `domain.role` were
ever warranted (§4.2 trigger), what lifts out is B2's assignment (from
`domain_workspace`) + workflow (from `domain_session`) — never anything from
`domain.agent`. So even the pessimistic future does not make the agent move
wasted.

---

## 6. Direct answers to the five investigation questions

1. **Does the agent-recipe role shape fit a human user?** No — recipe = agent
   sandbox contents; a human has none. agent-role and user-role are a homonym, not
   one concept (§1, §2).
2. **Is there a clean unifying abstraction?** Not over A+B. The "named cap-bundle
   a principal holds" unifier fits B2 (and half-exists as the identity-slice caps)
   but mis-describes A's build-time `requested_caps`. Keep them separate (§1.3).
3. **Approval/confirmation/arbitration routing:** route via `{:role, name}`
   fan-out — but **behind a new assignment-gated receiver trust boundary** (a
   naïve fan-out would mint `:receive` caps for out-of-scope principals, §3.2);
   approval authority = caps held in the identity slice, accountable **iff minted
   through `Identity.Grant`**, plus a **new role→cap assignment lifecycle** (caps
   are flat, not auto-bundled, §3.3); verdict-collection + arbiter escalation = a
   new approval/quorum Behavior on the Session Kind (recursion for escalation).
   New state = the workspace assignment + the role→cap binding + the Behavior's
   verdict state (§3).
4. **`domain.role` vs `domain.agent`:** recipe-role (A) stays in `domain.agent`.
   Responsibility (B2) **splits across existing apps** (codex-corrected): durable
   assignment → `domain_workspace` (where role caps live); the approval/quorum
   workflow → `domain_session` (the only app with replies/membership, and which
   already deps on workspace — putting it in workspace would CYCLE). **No new app.**
   `domain.role` is YAGNI until B2 outgrows a workspace facet (§4).
5. **Migration:** the relocation is a clean stepping-stone; B2 is additive and
   never touches the recipe registry; disambiguate the vocabulary now (§5).

---

## 7. Relationship to in-flight work

- **role-as-data CR governance** (`docs/together/2026-06-27/specs/
  role-as-data-cr-governance.md`, branch `docs/role-as-data-cr-spec`) governs
  *concept A* — turning the recipe into a `config://<ws>/role/<name>` ConfigObject
  under CR. **This research does not contest it.** It clarifies that that work is
  entirely A-side, and that B2 (the lead's approval scenario) is a *separate*
  concept that should not be folded into the recipe-config model. (That spec
  itself supersedes an earlier `roles-as-runtime-data.md` note on the recipe
  store; both are A-side.)
- **#154 no-unowned-caps** is the spine of B2's approval authority — it is already
  cross-principal and accountable, so B2 needs no new authority model, only named
  caps + assignment.

---

## 8. Open questions for the lead

- **OQ-1 — Is B2 actually wanted now, or is B1 enough?** The single-holder
  per-session `role_name` already routes "the reviewer of this session". The
  multi-holder/quorum/arbiter machine (B2) is real work; confirm the disagreeing-
  reviewers + arbiter scenario is a near-term need before building the assignment
  table + quorum Behavior.
- **OQ-2 — `role_name` uniqueness.** B2 needs ≥2 holders of `reviewer`.
  Relax `role_name_conflict/3` to allow many holders of the *same* responsibility
  (and keep uniqueness only for the *addressing-one-member* alias use), or add a
  separate many-holder assignment alongside the unique alias? (Recommend: keep B1's
  unique alias for "address this one member" and add a distinct many-holder
  **responsibility** assignment for B2 — two facets, not one overloaded field.)
- **OQ-3 — assignment scope.** Workspace-scoped assignment (recommended — matches
  where role caps live) vs session-scoped vs both (workspace default, session
  override)?
- **OQ-4 — quorum policy.** What verdict policy (unanimous / majority / any-one /
  N-of-M), and is the arbiter a *tiebreaker* (decides on conflict) or a *required
  final approver*? This shapes the Behavior's state machine.
- **OQ-5 — vocabulary.** Adopt "agent recipe" for A and reserve "role"/
  "responsibility" for B in code + docs, to retire the homonym? (Recommend yes.)

---

## 9. Codex adversarial-review record (2026-06-27, static-only, gpt-5.x)

> **Verdict: needs-attention.** Codex AFFIRMED the load-bearing conclusions — the
> A/B (recipe vs responsibility-label) split is correct, and it did not contest
> "no `domain.role`" or "recipe stays in `domain.agent`". It found the *B2 design
> overclaimed* in four places (two factual, two under-specified). All four are
> **applied in this rev** (they sharpen B2's design and the home; they do not flip
> the verdict).

| # | Codex finding | Verdict | Resolution in this rev |
|---|---|---|---|
| 1 | **Role fan-out skips the delivery trust boundary** — `{:role,name}` bypasses the membership filter that `$session_users`/`$mentions` get, and delivery mints a `:receive` cap per recipient; a workspace-wide fan-out could mint receive caps for out-of-scope/stale principals (tenant-isolation hole). | HIGH, valid | §3.2 rewritten: B2 routing must define an **assignment-gated receiver trust boundary** (same-ws + current-assignment check, session-local vs cross-session decided explicitly, tests proving no receive-cap leak). No longer called a "simple fan-out tweak". |
| 2 | **Workspace home conflicts with the actual dep direction** — `domain_session → domain_workspace` (verified in both `mix.exs`). A quorum/arbiter Behavior needs session replies/membership, so hosting it in `domain_workspace` would **cycle**. | HIGH, valid (verified) | §4.2/§4.3 corrected to a **split**: durable assignment → `domain_workspace`; the approval/quorum workflow → `domain_session` (already deps on workspace). DAG redrawn against real edges; "no cycle" now holds. Still **no new app**. |
| 3 | **Approval authority under-modeled as standalone caps** — identity caps are a flat `MapSet` keyed by cap identity; un-assigning a role would not revoke the cap, assigning would not grant it; verdicts could route to stale/absent authority. | MED, valid | §3.3 + §3.5 add the **assignment↔cap lifecycle** as new state (grant-on-assign/revoke-on-unassign, or atomic re-check of assignment+cap at verdict time). "Needs no new concept" softened. |
| 4 | **#154 `granted_by` claim too strong** — `granted_by_entity?/1` only rejects `system://` (verified `capability.ex:319-320`); the entity-granter invariant is enforced at `Identity.Grant.prepare/4`, not the runtime predicate. | MED, valid (verified) | §3.3 corrected: accountability comes from the **`Identity.Grant` path**; the runtime predicate is a narrow no-`system://` backstop. B2 approval caps must be minted via that path. |

**Net:** the thesis (two concepts under one word; recipe ≠ responsibility; no
`domain.role`; relocation is a clean stepping-stone) survived review intact. The
fixes were (a) two verified factual corrections (the dep-DAG direction and the
`granted_by_entity?` scope) and (b) two B2-design tightenings (the fan-out trust
boundary and the role→cap lifecycle) — making B2 a more honest "new
assignment-binding + gated routing + session workflow", still assembled from
existing primitives in existing apps.
