# Adversarial Review — SPEC A (codex + Claude), 2026-06-25

> Review of `A-agent-flavor-config-unification.md`. Run by Claude (static + `codex exec` 0.139.0 static-only). Every finding **re-verified by Claude** against origin/main; corrections to codex noted inline.
> **Verdict: NOT implementable as written — 3 of 6 decisions unsound (two were lead-ratified: D4, D3).**

## BLOCKER — D4 (move AgentFlavorRegistry core→domain_agent) — DROP
Core **reads and owns** the registry, so moving it inverts the dep graph (`core → domain_agent`, illegal):
- `apps/ezagent_core/lib/ezagent/agent_flavor_resolver.ex:87,111` → `AgentFlavorRegistry.list_all()`
- `apps/ezagent_core/lib/ezagent/agent_flavor_attributes.ex:84` → `list_all()`
- `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:68` — core **owns** the ETS table
- `apps/ezagent_core/lib/ezagent/plugin.ex:469` — core registers into it
It is in core BY DESIGN (#53, to keep `im→session→agent` acyclic). **Decision: registry stays in core. D4 dropped.**

## BLOCKER — D2 (fold echo onto Entity.Agent) — needs a receive-routing redesign + persistence override, not a simple fold
- `{Entity.Agent, :receive}` already → `Behavior.Agent.Receive` (`behavior/agent/receive.ex:88`). echo declares `{Entity.Echo, :receive, Behavior.Echo}` (`plugin_echo/application.ex:91`). Re-targeting echo's `:receive` to `Entity.Agent` → `CapabilityRegistry.check_conflict!` **raises at boot**. `receive.ex:160` already flags per-flavor `{Entity.Agent,:receive}` selection as an OPEN problem.
- **Persistence parity**: `Entity.Echo.persistence = :ephemeral` (`echo.ex:35`) vs `Entity.Agent.persistence = {:snapshot, :on_change}` (`agent.ex:165`). Folding makes echo persist → breaks its ~10 test/seed deps. `agent_flavor_decl` has no per-flavor persistence override.
- Also: `agent_module_resolver.ex:119` hardcodes `"echo" → Entity.Echo` (the very `flavor→kind` map §4's gate forbids) — must be rewritten by the fold.
**Decision needed (lead): do the receive-routing redesign now, or defer echo fold to its own spec.**

## HIGH — D3 (remove AgentConfig) — DROP (codex's reasoning corrected)
codex claimed "no caller, just an unwired facade." **Claude verified that's WRONG: world already calls it** — `world/agent_actions.ex`, `world/identity_data.ex` (+ `agent_config_dispatch_test.exs`, `agent_config_state_test.exs`), and it's gaga's contract (`docs/together/2026-06-24/agent-config-backend-contract-plan.md`). Removing it **breaks world's live calls**. **Decision: keep AgentConfig. D3 dropped.**

## MED — D1 (behaviors/0 registry-derived) — sound, needs boot-order guarantee
Not a compile break. But `BehaviorSet.init_set/2` **intersects** requested behaviors with `behaviors_of(kind)` and first spawn **persists** the set into `:kind_base`. If `behaviors/0` is read before all folded-flavor plugins register, the captured `:kind_base` is permanently incomplete → the cold-restart bug class (#110/#113/#114). D1 must specify "all flavor plugins registered before first `:kind_base` capture." D1+D2 are coupled (the intersection means a flavor's `instance_behaviors` only apply if also in the declared union).

## OK — D5 (config_schema in decl), D6 (drop AgentKind alias)
Low-risk / cosmetic. Keep.

## Process note
codex reported gaga's `agent-runtime-situation.md` "missing" — **false alarm** (its local checkout wasn't pulled; the file IS on main).

## Revised A (proposed)
**D1 (with boot-order guarantee) + D5 + D6**; **drop D3, D4**; **defer D2 (echo fold) to its own spec** (receive-routing redesign). Clean, zero-illegal increment that still delivers behaviors-plugin-ization + config-schema convergence. Pending lead re-decision on D2.
