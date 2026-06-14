# PR-9a — extract `ezagent_domain_agent` + land the acyclic gate (execution plan)

**Status:** PLAN (codex, 2026-06-14). Execution gated on PR-A (#768) landing on main for a clean base.
**Parent:** `2026-06-14-pr9-physical-domain-split-brief.md` (D1–D4), `2026-06-12-im-session-agent-decomposition-design.md` (§2), `2026-06-14-pr9-A1-agent-session-decoupling-audit.md`.
**Branch:** `feat/pr-9a-domain-agent` (stacked on PR-A).

## Goal
New umbrella leaf app `ezagent_domain_agent` holding the Agent Kind + its transport seam, deps `ezagent_core` + `ezagent_domain_agent_bridge`. Land the `im → session → agent` acyclic arch-fitness gate ALLOWLISTED (brief D4 — gate-first), shrinking the allowlist toward 0 by 9c.

## Module set to relocate (module names FROZEN — D1a)
From `apps/ezagent_domain_instance_message/lib/ezagent/`:
- `entity/agent.ex`, `entity/agent_template.ex`
- `entity/agent/spawn_obligations.ex`, `entity/agent/template_spawn.ex`, `entity/agent/template_spawn/cascade.ex`
- `behavior/agent/receive.ex`, `behavior/agent/delivery.ex`

## Boot machinery that is ENTANGLED (the hard part — split carefully)
`instance_message/application.ex`:
1. **Supervisor child specs** (lines ~84–96): `AgentSupervisor` + `AgentTemplateSupervisor` are in the SAME `children` list as `SessionSupervisor` + `SessionTemplateSupervisor`. Move ONLY the two Agent ones to `EzagentDomainAgent.Application`, keeping the FROZEN name atoms `EzagentDomainInstanceMessage.{AgentSupervisor,AgentTemplateSupervisor}` (Entity.Agent.supervisor/0:161 + AgentTemplate.supervisor/0:179 return these — do NOT rename). Name-clash hazard: a supervisor name atom can be claimed by only ONE process — the spec must move, not be duplicated.
2. **`register_spawn_fns/0`** (line 629): the `"entity"` spawn fn (650) spawns BOTH User and Agent; the `"template"` spawn fn (740) spawns BOTH AgentTemplate and SessionTemplate. These shared closures must be SPLIT so the agent-Kind spawn registration moves to `EzagentDomainAgent.Application` while user/session stay. A wrong split breaks spawning for every Kind — high blast radius.
3. **`CapabilityRegistry.register(Agent, :receive, Behavior.Agent.Receive)`** (line 800) moves to the new app's boot.

## Cross-edges created by the move (→ the acyclic-gate ALLOWLIST, shrink later)
- `behavior/agent/delivery.ex` references `EzagentDomainInstanceMessage.UriQueryResolvers` (flavor resolution). After the move that is `domain_agent → instance_message` — a REVERSE edge. Allowlist it in 9a; resolve by relocating the agent-flavor resolver parts to `domain_agent`/core (9a-tail or 9c).
- `Entity.Agent.base_behaviors/0` names `Behavior.{Identity,ApiKeys,CredentialGrant,ConfigEvolve}` (ezagent_domain_identity) + `Behavior.CurlAgent` (curl plugin) as **bare atoms**. Atoms are NOT compile deps, so a **compile-dependency-based** acyclic gate (mix xref `--label compile`, NOT raw symbol grep) does not flag them. Keep `domain_agent` mix deps = core + agent_bridge; identity/curl behaviors resolve at runtime via umbrella app loading (same pattern as today: identity already references `Entity.Agent` with no mix dep on instance_message).
- `Behavior.CurlAgent` reparent (brief §3): physically moving it from the curl plugin into `domain_agent` is a tier-cleanliness step (domain naming a plugin module as an atom). NOT required for compile-acyclicity. RECOMMEND: defer the physical curl-behavior move to a 9a-tail sub-step or 9c (allowlist the atom ref meanwhile) to bound 9a's blast radius — confirm with Allen since the brief lists it under 9a.

## mix.exs + gate-path updates (same change)
- New `apps/ezagent_domain_agent/mix.exs` (deps core + agent_bridge), `application.ex`.
- `instance_message/mix.exs`: add `{:ezagent_domain_agent, in_umbrella: true}` (session code still references `Entity.Agent` — e.g. routing/session_creator).
- Root `mix.exs` `releases()`: add `ezagent_domain_agent: :permanent` (boot order: before instance_message? Agent Kind registration vs session use — registrations are into shared ETS registries, order-tolerant; verify).
- **Hardcoded path allowlists** (the stale-allowlist class that reddened main twice): `ezagent.arch.scan.ex` `@spawn_registry_sanctioned_files` (agent.ex path) + `@spawn_fresh_sanctioned` (agent.ex anchors — path changes app dir!) + any `apps/ezagent_domain_instance_message/.../entity/agent*` literal; `ezagent.check_invariants.ex` exclusions. Update to the new `apps/ezagent_domain_agent/...` paths in the SAME commit; `mix compile --force` before re-running the gates (they run the compiled task).

## Acyclic arch-fitness gate (brief §6, land in 9a allowlisted)
New ExUnit test (in ezagent_core/test or a dedicated app) asserting, via `mix xref`/app-dep graph (compile-label):
(a) im-layer (feishu plugin) has no agent-Kind / `agent.receive` symbol;
(b) session (instance_message) has no `McpChannel` / `orchestrator_bridge` symbol;
(c) the `im → session → agent` app dep graph is acyclic;
with an explicit ALLOWLIST of the cross-edges still present (the `delivery.ex → UriQueryResolvers` reverse edge, etc.). 9a keeps it green with the allowlist; 9b/9c shrink it to 0 (9c = empty allowlist = completion invariant).

## Sub-step sequence (keep build green at each)
1. Create `ezagent_domain_agent` skeleton (app + empty supervisors with frozen names) — but supervisors can't co-exist with the originals, so step 1+2 are atomic.
2. `git mv` the 7 module files; move the 2 supervisor specs + split the shared spawn fns + move `{Agent,:receive}`; wire `EzagentDomainAgent.Application`.
3. mix.exs deps + releases() + gate path allowlists.
4. Add the acyclic gate (allowlisted).
5. Gates EVERY: `mix compile --force`; arch.scan (re-force-compile, it's edited); check_invariants + .lifecycle; doc.scan; full per-app `mix test` (real exit codes, not `| grep`). Cold-restart respawn round-trip byte-identical (no snapshot drift — module names frozen ⇒ should hold).

## Open item for Allen (non-blocking for compile-acyclicity)
Curl-state `Behavior.CurlAgent` physical relocation (curl plugin → domain_agent): keep in 9a per brief, or defer to 9c with the atom ref allowlisted? Recommend defer to bound 9a blast radius.
