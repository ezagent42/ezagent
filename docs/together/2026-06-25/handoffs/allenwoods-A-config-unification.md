# Handoff — A: agent flavor + config unification (allenwoods)

> Complete handoff. Brainstorm + spec + plan + **two** codex adversarial reviews done. Ready to implement after lead sets `/goal`.

## What & why
Finish the flavor-plugin contract so **adding an agent flavor = adding a plugin, ZERO core edits**, locked by an arch gate. Today flavor logic has leaked into `ezagent_core` (generic `Kind.Template` + `Plugin.publish` know about flavors) and `Entity.Agent.behaviors/0` is hardcoded. North star: plugin isolation, machine-enforced.

## Read order (authoritative)
1. SPEC — `docs/together/2026-06-25/specs/A-agent-flavor-config-unification.md` (decisions D1–D6, /goal §6)
2. PLAN (rev 2) — `docs/together/2026-06-25/specs/A-plan.md` (PR-A1..A6, exact files/idioms/risks)
3. Spec review — `docs/together/2026-06-25/specs/A-codex-adversarial-review.md`
4. Backend现状 — `docs/together/2026-06-25/handoffs/agent-runtime-situation.md` (gaga)

## Skills (load first)
`Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`. (If dispatched to codex: it has no Skill tool → `cat .claude/skills/ezagent-developer/SKILL.md` + `.../elixir-phoenix-helper/SKILL.md` first.)

## Branch / worktree
Branch `feat/agent-flavor-config-unification` off current `main`. **Work in a DEDICATED `git worktree`, never the shared `/Users/h2oslabs/Workspace/esr-ng` checkout** (it drifts onto other agents' branches — caused two corrupted reviews + a clobber this cycle).

## PR sequence (detail in PLAN)
- **A1** invert `Kind.Template` flavor coupling via a `ReadyGate.register_external_gate`-style registered hook (persistent_term + function_exported? + no-op default).
- **A2** (a) invert `Plugin.publish`'s registry write via a 2nd ReadyGate-style hook *(the crux — keeps core flavor-blind, no core→agent edge)*; (b) add a domain.agent EtsOwner (started first); (c) move registry+resolver+attributes core→domain.agent + fix readers; (d) add arch gate `no_flavor_refs_in_core`=0.
- **A3** `behaviors/0` registry-derived behind a **sealed-registry boot barrier** (else cold-restart bug class #110/#113/#114 — cc `after_boot` `load_all` spawns before all flavors register).
- **A4** `config_schema` in `agent_flavor_decl`.
- **A5** replace `Ezagent.AgentConfig` with a domain.agent config API; migrate the real callers — `world/agent_actions.ex:196/219/242`, `world/identity_data.ex:184`, `domain_identity/config_evolve.ex` (+ add `domain_agent→domain_identity` dep). **Coordinate gaga** (console wires this contract).
- **A6** drop the `AgentKind` alias.
Order: A1→A2(a→d)→A3; A4/A5/A6 independent after A2. A2/A3 are high-blast-radius.

## DoD (the /goal, spec §6 — verbatim acceptance)
1. core has zero flavor refs (gate `no_flavor_refs_in_core`=0; cluster in domain.agent; Kind.Template + Plugin.publish via hooks).
2. `behaviors/0` registry-derived + boot-order guarantee + cold-restart regression test.
3. `AgentConfig` replaced by domain.agent config API (cap-gated); real callers migrated; `config_schema` in decl.
4. cc/codex/curl all `kind: Entity.Agent` (no AgentKind alias).
Gates: full `mix test` 0 failures + CI green; `no_flavor_refs_in_core` green; "add flavor = plugin, zero core edit" invariant test passes; gaga console reads/writes via domain.agent API.

## Out of scope (sequenced follow-up, own spec)
- **echo → py-agent → delete echo** (SPEC §8): build a `python` program-agent flavor (folded onto Entity.Agent, shared `:receive`, runs py) → swap into echo's ~77 test/seed refs → delete echo + `Entity.Echo`. Logged in `docs/futures/todo.md`.

## Process
Per-PR: four-property DoD reconciliation at return, CI green on PR head, rebased on current main, **dedicated worktree**, not self-merged into main unless self-driven by the lead.
