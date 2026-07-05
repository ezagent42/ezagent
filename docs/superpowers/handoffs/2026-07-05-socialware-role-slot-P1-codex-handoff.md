# Codex handoff — Socialware role-slot model, P1 (declaration + security core)

**To:** codex (self-driving). **From:** lead (Claude). **Date:** 2026-07-05.

## Goal (one sentence)

Make a socialware `%Definition{}` declare participants by ROLE only (recipe name + flavor, or an open human slot) — never an instance URI — so the credential-theft template-declaration vector is **structurally impossible**, proven by a fail-closed arch gate (Gate A) going green.

## What to read first (in order)

1. `docs/superpowers/specs/2026-07-05-socialware-role-slot-model-design.md` (rev3, codex-SOUND) — the model + the security invariant.
2. `docs/superpowers/plans/2026-07-05-socialware-role-slot-model-plan.md` (rev2, codex-reviewed READY) — **P1 = Tasks 1-9. Execute these.** P2/P3 are outline-only; do NOT start them.
3. Context you'll need: the #161 C admission gate (`apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` `do_join/5` `:73`, the `admission_pending?` predicate) — reuse-bind (Task 7) rides it; `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex` (recipe × flavor → agent).

## Branch & merge protocol

- Work on a target branch `feat/socialware-role-slot-p1` off latest `origin/main`. Commit + push there. **Do NOT open a PR, do NOT merge to main.** When P1 is done + green, push the branch and RETURN it to the lead; the lead validates + merges. [[feedback_codex_handoff_self_merge_target]]
- **Static-only tooling for you (codex-rescue) is NOT this job** — you have the full repo + `mix`. Run tests.

## Required skills / constraints (load before touching apps code)

- `Skill: ezagent-developer` + `elixir-phoenix-helper`. [[feedback_subagent_must_load_project_skills]]
- Elixir edits via editor only — **never `cat >>`** (SyntaxError). [[feedback_no_cat_append_elixir]]
- `mix` for tests (not python). Pre-prod: **delete** the old `members`/`:fixed` surfaces, no back-compat shim. [[feedback_let_it_crash_no_workarounds]]
- The 5 Global Constraints in the plan header apply to every task.

## Per-task gate (the completion contract)

Follow the plan's TDD steps. Each task ends green + committed. The PHASE gates:

- **Gate A (Task 1 → Task 8):** `mix test apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs` — starts RED (the worklist), ends GREEN after Task 8 with its teeth test still tripping on a planted URI. This is the structural-closure proof.
- **P1 acceptance (Task 9):** authoring/publishing a definition that names a foreign agent/user instance URI is rejected at `Definition.new/1` (no field / URI-shape check); a legit recipe+human-slot def passes conformance; a reuse-bind of a foreign agent PENDS (#161 C).
- **Full gate before returning the branch:** `mix ezagent.check_invariants` + `mix ezagent.uri_query.scan` + `mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants` + the 6 flavor plugins (curl/world/hello/codex/py/cc) + `apps/ezagent_domain_session/test` + the migrated P10 E2E — ALL green. [[feedback_run_check_invariants_gate]] Then `/codex:adversarial-review` the branch and address findings.

## The three codex-plan-review must-nots (do not regress these)

1. **Reuse (Task 7) MUST route through the operator-caller `session.join`** (`orchestrator/tools/participants.ex` → `Tools.join_member/5` → `do_join/5` with `ctx.caller = operator`), NEVER through the admin materialization helpers (`DefinitionAgents`/`RouteProvisioner.system_mediated_ctx`) — else a foreign reuse is EXEMPT and the vector reopens. The FRESH path (Task 5) stays system-mediated (own new recipe agent — safe).
2. **`DefinitionAgents.materialize_definition_agents/4` IS the real socialware materializer** (Task 5) — it must consume `roles` with **uuid** agent URIs (not role-derived). Updating only `template_team.ex` is insufficient.
3. **owner=installer must cover ALL sites** (Task 6): the `owner_policy/1` `:fixed` branch, `validate_anon_owner` (`definition.ex:396` — rewrite to require a non-anon installer, NOT a baked URI), the built-in seed (`definition_registry.ex:290`), and the P10 form (`:369`).

## Out of scope for P1

P2 (role de-bake, uuid identity, `AgentRoleAttributes`/kanban/world migration, Gate B) and P3 (human-slot UI, operator materialize wizard). Do NOT touch `planned_agent_uri`'s role-baking beyond what Task 5's uuid materialization needs — the full role-de-bake is P2.

## Return

Push `feat/socialware-role-slot-p1` with Gate A green + P1 acceptance + full gate green + codex-review clean. Report: branch name, the Gate A before/after, the P1 acceptance result, and any deviation from the plan (with evidence, per the deviation discipline).
