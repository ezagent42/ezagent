# Socialware role-slot P3 — human slots + operator materialize UI — codex handoff

**For codex.** Base: `origin/main` (P1 #1180 + P2 #1185 both landed). Branch: `feat/socialware-role-slot-p3`. Self-merge is NOT the model — commit + push the branch, return it, the lead validates (full gates + `agent-browser` e2e) and merges. Skip `mix` availability checks — this repo has it.

## Goal (one sentence)
Finish the role-slot model: let a socialware Definition declare **human** role slots (`fill: :human`), give the **operator** a materialize/install wizard to bind each **agent** slot (pick flavor + Fresh/Reuse) and each **human** slot (assigned at runtime when a person joins), and add the runtime "assign role" control — completing the symmetric human/agent role-on-edge model P1/P2 built.

## What P1 + P2 already did (do NOT redo)
- **P1 (#1180):** `Definition.roles` declares participants by ROLE only (recipe name + flavor, or an open human slot) — never an instance URI. Gate A blocks instance URIs in a declaration. Reuse-of-a-foreign-agent PENDS via the #161 admission gate.
- **P2 (#1185):** agents are role-agnostic fresh-uuid (`entity://<ws>/agent/<uuid>`); `role_name` lives ONLY on the (entity × session) membership edge (`Members` meta facet, per-session uniqueness via `role_name_conflict/3`); routing `{:role, name}` resolves against the session's current edges. Gate B forbids an agent-level session role. Recipe provenance is a stored `recipe` attribute (NOT a session role).

## Read first (this is your spec — it's on your base)
- `docs/superpowers/specs/2026-07-05-socialware-role-slot-model-design.md` — **§4.5 human role slots**, **§6 operator materialize UI**, §5 security invariant, §10 acceptance.
- The **approved UI mockup**: `docs/superpowers/handoffs/assets/2026-07-05-p3-materialize-wizard-mockup.png` (lead + Allen signed off on this layout — match it). Layout summary below so you don't have to guess.
- P1's live socialware materialize path: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex` (how declared agent slots get materialized + joined + recipe-caps granted today). The operator materialize flow extends THIS, it does not replace it.
- The world operator console: React island under `apps/ezagent_plugin_world/assets/` + its data providers in `apps/ezagent_plugin_world/lib/ezagent/world/` (see `identity_data.ex` for the create-agent form pattern at `/identities/agents/new`). The install/materialize surface for a socialware app is where the wizard lives.

## The approved wizard layout (match the mockup)
A single install/materialize page (world operator console, same shadcn/Tailwind aesthetic as the Identities/create-agent surfaces):
- **Header:** "安装 Socialware" + one-line explainer ("this app declares which ROLES it needs; you decide who fills each; it never names a specific agent or person") + an app chip (name · "recipe-declared roles" · version).
- **Agent role slots** (one card each): shows `role_name` + the declared `recipe` (mono, not an instance URI). Controls: a **flavor** `<select>` (default = the slot's declared flavor) and a **Fresh | Reuse** segmented control.
  - **Fresh** → materialize a NEW uuid agent from `recipe` × chosen `flavor` (operator becomes owner).
  - **Reuse** → a `<select>` of the operator's OWN (`manages?`-owned), recipe-matching agents; binding goes through an **operator-caller `session.join`** so the #161 admission gate fires (a foreign agent PENDS for owner approval).
- **Human role slots** (one card each): shows `role_name` + `fill: :human`; an "open slot — assigned when a person joins" note. No control at install.
- **Footer:** "Owner (installer): <operator>" + workspace + Cancel / "Install & create session".

## Scope — DOMAIN
1. **`fill: :human` declaration.** Confirm/extend `Definition.new/1` + conformance so a role `%{role_name, fill: :human}` parses, validates, and passes `ezagent.socialware.check` (no recipe/flavor required for a human slot; still no instance URI). Reject a human slot that carries an agent/user/template URI.
2. **Operator materialize flow.** Given a Definition's role slots + the operator's per-slot choices, on install: for each agent slot Fresh → materialize (the P2 uuid path); Reuse → operator-caller `session.join` of the chosen owned agent. Owner of anything fresh = the installer. Reuse of a not-owned agent must PEND (do NOT bypass #161). Human slots: nothing at install (left open).
3. **Runtime human role-assign.** When a human joins the session, the operator assigns an open human `role_name` to that human's membership edge (`Members` facet — same store P2 uses for agent role edges; `role_name_conflict/3` applies). **Constraints (spec §4.5):** the assign target MUST be an `entity://…/user/…` URI (never an agent/template/recipe — the assign path must not spawn/join an agent); it is a RUNTIME edge write, **never** persisted back into the `%Definition{}`; and it is **cap-gated to the operator** (session owner / a `manages?`-style authority — mirror how P1/P2 gate operator actions; do not invent a new principal).

## Scope — UI (world operator console, React island)
4. **Materialize wizard** — the page above (match the mockup). Per agent slot: flavor select + Fresh/Reuse + (Reuse) the owned-recipe-matching-agent picker sourced from a cap-gated data provider (owner-scoped; do NOT leak other tenants' agents). Per human slot: the open-slot note. Wire "Install & create session" to the domain materialize flow (2).
5. **"Assign role" control** — in the session member view, for a joined human + an open human slot, an operator-gated control that calls the runtime assign (3). Surface the resulting edge role on the member row.
6. Match the existing world aesthetic; reuse existing island/data-provider patterns (don't hand-roll a new data path). This is where the missing "指定 role 的 UI" Allen flagged lives.

## Acceptance (prove these — you have `agent-browser`)
- **Domain E2E:** install a socialware app declaring ≥1 agent slot + ≥1 human slot → Fresh agent materializes (uuid, operator-owned), Reuse of an owned recipe-matching agent joins, a human slot is left open; a human joins → operator assigns its role → the `role_name` lands on THAT human's edge and is never written to the Definition; the P2 two-sessions-different-role property still holds; reuse of a NOT-owned agent PENDS (#161).
- **UI E2E (`agent-browser`, screenshot each):** the install wizard renders the declared slots with the right controls (agent = flavor + Fresh/Reuse + reuse-picker; human = open-slot note); completing it materializes/joins; the member-view "assign role" control assigns a human role and the edge role shows. Log in via the world console (cookie-inject if the login LiveView is flaky — see the lead's agent-browser notes) and capture the wizard + the assigned-role member row.
- **Gates:** full `mix ci.local` (or at minimum: `compile --warnings-as-errors`, `format --check-formatted`, `check_invariants`, `socialware.check`, `mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants`, and the touched-app suites incl. `ezagent_plugin_world`). Gate A + Gate B stay green. `NoBehaviorModuleReferenceTest` stays green — use `Ezagent.ActionSet.*`, never the retired `Ezagent.Behavior.*`.

## Must-nots (learned this cycle)
- **Never persist a runtime human role assignment back into `%Definition{}`** — it's an edge write only (spec §4.5 codex-NEW-HIGH).
- **Reuse binds via operator-caller `session.join`, not an admin helper** — so #161 fires. Fresh/Reuse are the ONLY two agent-slot options; no third "pick any instance" path (that would re-open the vector P1 closed).
- **Human assign target is a user URI, full stop** — never an agent/template/recipe URI.
- **Owner = installer** everywhere (no `owner_policy.fixed`).
- **Verify docs/comments against code** (a retired-module reference in a test string reddened main this cycle — the arch gate catches `Ezagent.Behavior`).
- Run the FULL gate set before hand-back, not just the touched app suites — the arch/invariant gates live in `ezagent_core` and a per-app run skips them.

## Hand-back
Commit (trailer: check a recent `git log` for the `Co-Authored-By` + `Claude-Session` lines), push `feat/socialware-role-slot-p3`, return: the domain change inventory, the UI components added, the acceptance results (+ agent-browser screenshots of the wizard + assigned-role member row), full gate results, and any design fork you hit (STOP + report rather than guess).
