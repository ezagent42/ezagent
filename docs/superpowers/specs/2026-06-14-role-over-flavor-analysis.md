# Role-over-Flavor — current-state analysis (task #54)

> **This is an ANALYSIS, not a design.** It maps how agent "flavor" works today,
> shows where *role* and *flavor* are entangled, and frames the open design
> questions — the groundwork for a brainstorm, not a committed solution. Code
> citations are point-in-time.
>
> Bilingual mirror: [`2026-06-14-role-over-flavor-analysis.zh_cn.md`](./2026-06-14-role-over-flavor-analysis.zh_cn.md).

## 1. What a "flavor" is today

A flavor is a registered bundle in `Ezagent.AgentFlavorRegistry`
(`apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`), declared by each
agent plugin's `agent_flavors/0` and registered through `Ezagent.Plugin.boot/1`:

```elixir
%{
  flavor: "cc" | "codex" | "curl" | …,   # the entity-name prefix
  kind: module(),                         # Entity.Agent (shared) or a dedicated Kind
  template_class: module(),               # the spawn/template wiring
  instance_behaviors: (-> [module()]) | nil,  # behavior SUBSET when folded onto a shared Kind
  bridge_adapter: module()                # the TRANSPORT adapter
}
```

The three flavors differ almost entirely in **how the agent is wired to its
runtime** (the `bridge_adapter` + kind):

| flavor | runtime / transport (the real difference) |
|--------|-------------------------------------------|
| `cc`    | `claude` CLI in a PTY + an MCP bridge subprocess (`EzagentPluginCc.BridgeAdapter`) |
| `codex` | `codex` binary over a UDS WebSocket bridge with thread continuity (`EzagentPluginCodex.BridgeAdapter`) |
| `curl`  | in-process HTTP call to an LLM endpoint, no bridge subprocess (`EzagentPluginCurlAgent.BridgeAdapter`) |

Plugin isolation here is good: adding a flavor touches only its plugin dir (the
resolver consults the registry, not a hardcoded map). **Flavor = the transport/
runtime substrate. That part is sound.**

## 2. Where role and flavor are entangled

The problem is that **"what the agent is for" (its ROLE) is expressed only as a
flavor-specific template class.** The clearest example is the orchestrator:
`cc_orchestrator_seed.ex` — *"`flavor: "cc"` — the orchestrator is a `claude`
PTY agent."* The role **orchestrator** is hard-bound to flavor **cc**.

Consequences:
- There is no flavor-independent notion of a role. "Orchestrator", "reviewer",
  "customer-service", etc. live (if at all) as bespoke `*-orchestrator`
  template classes per flavor.
- To get "an orchestrator, but codex-flavored" you would author a *separate*
  `codex-orchestrator` template class — roles do not compose across flavors.
- Feature/scenario design leaks the flavor name where it should not: scenario
  04 ("codex external agent") and scenario 06 named codex specifically when the
  concern was generic agent behavior (both were flagged/removed for this reason
  on 2026-06-14).

This entanglement is the opposite of the **North Star (plugin isolation):**
future authors should compose role × flavor without coordinating, and the
user-facing concept should be the ROLE (what it does), not the FLAVOR (how it is
wired).

## 3. The shape of the fix (to brainstorm — NOT decided)

The target is **role as a first-class abstraction above flavor**, so an agent =
`role × flavor`, independently chosen:

- **Flavor** keeps its current job: transport/runtime substrate (PTY+MCP / UDS /
  in-process). No change to the registry's strength.
- **Role** becomes the flavor-independent definition of *what the agent does*:
  its system prompt / persona, its behavior set, its caps, its session-template
  wiring — everything that today is smeared into `*-orchestrator`-style template
  classes.
- An agent is then materialized by **picking a role and a flavor**; the
  orchestrator role works whether realized as cc, codex, or curl.

## 4. Open design questions (for Allen)

1. **Where does a Role live?** A new `Role` registry parallel to
   `AgentFlavorRegistry` (role → {prompt, behaviors, caps, session-template})?
   Or roles as data rows (a `Template` subtype) rather than modules?
2. **Composition point.** Where do role × flavor combine — at template
   materialization, at agent spawn, or as a two-axis template key?
3. **Migration of the orchestrator.** The cc-orchestrator is the load-bearing
   existing "role". Does it become the first `Role`, with cc as just its default
   flavor? What breaks for the team-routing / orchestrator-readiness paths?
4. **Scope vs. 基座化.** Roles touch session-template wiring, which is in the
   `instance_message`→`session` domain codex is mid-renaming (9b). Should #54
   wait until after 9c, or can the Role registry land in `core` independently
   first (the registry is flavor-side, not session-side)?
5. **Is "role" the right axis, or do we also need "capability profile" / "team
   position" as separate axes?** (Avoid re-entangling.)

## 5. Cross-references

- `Ezagent.AgentFlavorRegistry` / `Ezagent.Plugin` (`agent_flavors/0`, `bridge_adapter`).
- `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex` — the role-flavor entanglement example.
- North Star: `feedback_north_star_plugin_isolation`.
- [`../../architecture/communication-overview.md`](../../architecture/communication-overview.md) §5 — the flavor delivery paths.
