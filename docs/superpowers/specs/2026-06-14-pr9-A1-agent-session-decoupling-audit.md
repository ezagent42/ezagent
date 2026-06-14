# PR-9 A1 — Agent↔Session decoupling audit (for Allen's 拍板)

> **Audit only — no code changed.** A1 is the crux prerequisite for the PR-9
> physical domain split (`im → session → agent` acyclic). It removes the live
> `agent → session` compile edges so `Entity.Agent` can move to a leaf
> `domain.agent` app. This doc establishes WHAT couples them today, whether each
> edge is vestigial or load-bearing, and the decoupling + migration plan.
> Snapshot-affecting → present before implementing (per the design-then-review
> agreement). Parent: `2026-06-12-im-session-agent-decomposition-design.md`,
> `2026-06-14-pr9-physical-domain-split-brief.md`.

## The agent → session edges (compile dependencies, would cycle on extraction)

Scanned the agent-domain module set (`entity/agent.ex`, `entity/agent_template.ex`,
`behavior/agent/receive.ex`). Real code edges (comments excluded):

| # | Edge | Site | Nature |
|---|---|---|---|
| A1 | `Entity.Agent.base_behaviors/0` composes `Ezagent.Behavior.Session` | `entity/agent.ex:99` | **VESTIGIAL (see below)** |
| A2 | `Entity.AgentTemplate` calls `SessionCreator.TemplateResolver.resolve_template_class/1` | `entity/agent_template.ex:236` | seam needed |
| A3 | `Behavior.Agent.Receive` aliases/uses `Behavior.Session.Delivery` | `behavior/agent/receive.ex:76` | seam needed (spec §3.3: should use AgentBridge) |
| — | `EzagentDomainInstanceMessage.{AgentSupervisor,AgentTemplateSupervisor}` | `agent.ex:162`, `agent_template.ex:179` | NOT an edge to cut — these supervisors MOVE to domain.agent with the agent modules (frozen name per D1a) |

## A1 — `Behavior.Session` on `Entity.Agent` is VESTIGIAL (evidence)

`Behavior.Session` is the SESSION-HOST behavior: its actions are `:send` / `:join`
/ `:leave` / `:set_working_copy` / `:set_legends` / `:set_prompt_templates`, plus
`handle_signal({:DOWN,…})` (member-monitor cleanup), the `:chat` state-slice, and
`reads_siblings([:sandbox])`. An Agent is a session MEMBER, not a host. Evidence
it does not actually use any of this:

1. **Agents receive via the NEW seam, not Session.** `{Agent, :receive}` is
   registered to `Ezagent.Behavior.Agent.Receive`
   (`instance_message/application.ex:800`); session→agent delivery dispatches
   `agent.receive` (`session/delivery.ex:131`), never a Session action on the agent.
2. **No session-host action is dispatched to any `entity://agent` URI** (grep:
   zero `with_action(agent_uri, :chat|:send|:join|:leave|:set_*)` sites).
3. The `Behavior.Session` references across core/domain are all `kind: :session`
   (the Session Kind / its caps), none target an agent.

**Remaining concern — the persisted `:chat` slice.** Composing `Behavior.Session`
gives every Agent snapshot a `:chat` slice (`state_slice :chat`). Removing the
behavior orphans that slice → a snapshot migration must drop it (cold-load must
stay byte-identical-minus-`:chat`). Must also confirm NOTHING reads an agent's
`:chat` slice (grep so far: none found — to be re-verified by the full suite).

### A1 decoupling plan
1. Remove `Ezagent.Behavior.Session` from `Entity.Agent.base_behaviors/0`
   (and therefore `curl_behaviors/0` / `nil_capture_behavior_set/0`).
2. Snapshot migration (TEST DB only): drop the `:chat` slice from existing
   `entity://agent/...` snapshots; cold-restart round-trip byte-identical sans `:chat`.
3. Verify gate: full umbrella suite + all E2E scenarios (cc/codex/curl deliver-and-
   reply, relay scenario_34, chat core) green; cap catalogue has no relied-upon
   `{Agent, Behavior.Session, *}` entry; no agent `:chat` read survives.
4. Risk: HIGH-ish (touches the Agent Kind's behavior composition + agent
   snapshots). Mitigation: it's a REMOVAL of dead composition, proven by the
   suite; reversible (re-add the behavior) within a window if a hidden reader appears.

## A2 — `AgentTemplate → SessionCreator.TemplateResolver`
`resolve_template_class/1` lives in the session domain. Options: (a) move the
resolver to a shared/core location both use, or (b) runtime-dispatch / inject it.
Lower risk than A1 (pure function relocation). Decide with A1.

## A3 — `Behavior.Agent.Receive → Behavior.Session.Delivery`
Per decomposition spec §3.3 the agent receive path should drive
`AgentBridge.deliver`, not the session's `Delivery.deliver_agent_receive/2`. The
delivery helper (or its agent-relevant part) moves into the agent domain /
AgentBridge. Medium risk (delivery path); covered by the deliver-and-reply E2E.

## Sequence (revised PR-9, gate-first per brief D4)
1. **9a-pre (this audit's impl):** A1 + A2 + A3 cuts, landing the acyclic
   arch-fitness gate ALLOWLISTED at the start; each cut shrinks the allowlist.
2. **9a:** create `ezagent_domain_agent`, move the now-leaf agent modules +
   their supervisors (frozen names), gate allowlist shrinks toward 0.
3. **9b:** rename app `ezagent_domain_instance_message → ezagent_domain_session`
   (+ update the hardcoded gate path-allowlists + runtime app atoms; freeze the
   persisted `EzagentDomainInstanceMessage.*` module names — routing_rules).
4. **9c:** allowlist → 0; `im → session → agent` acyclic invariant is the gate.

## Realistic estimate
A1 is the hard, snapshot-affecting bone; A2/A3 are smaller seams. Full clean
split (A1-A3 + 9a-9c) is several careful PRs — A1's snapshot migration + full-E2E
gate is the long pole. **Awaiting Allen 拍板 on the A1 approach (remove + migrate
`:chat`) before implementing.**
