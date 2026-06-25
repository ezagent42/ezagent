# Agent orchestration — chat-`@`/route → kanban-manager agent drives the board

This is the on-ezagent **superpower**: because every board mutation is a dispatch
carrying an authenticated `ctx.caller` (see live-board-access.md), the principal
behind a node can be an **agent**, and a lead can hand the whole board to a
**kanban-manager agent** from chat. This file describes the **high-level** model.
The exact routing rule + agent contract (the precise file:line wiring) is a
**grounding placeholder — 待编排 grounding 补全** (another agent is resolving it).

## Why it works at all (grounded)
The Behavior never distinguishes a human caller from an agent caller. Authorization
is purely `ctx.caller == node.owner` or admin:
- ctx is built from the logged-in entity at the world surface —
  `caller: current_entity_uri`, `caps: current_caps`
  (`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:321-327`).
- the per-node check lives in the Kind: `owner_or_admin?(ctx, node)`
  (`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:715`, `:728` →
  `Shared.owner_or_admin?`), `claim_node` sets `owner: caller_str(ctx)`
  (`kanban.ex:480-485`).

So if `ctx.caller` is an **agent entity URI** (`entity://<ws>/agent/<name>`), that
agent can `claim_node`, do the stage's work, `attach_artifact`, and `add_node` for
the next stage — first-class, by the same dispatch path a human uses. Nothing in the
kanban Behavior special-cases humans. **This is grounded and load-bearing.**

## The high-level orchestration loop (the target shape)
1. A lead `@`s / routes a message to a **kanban-manager agent** in a session (e.g.
   "advance the auth feature line", "assign the test stage of n7 to the test-agent",
   "run CI on all pr nodes").
2. The kanban-manager agent interprets the intent and **dispatches the matching
   `kanban.*` actions** against `resource://<ws>/kanban/<name>` with **its own**
   `ctx.caller` (the agent's entity URI) — claiming nodes, relaying stages,
   attaching artifacts, kicking `sync_github`/`sync_prs`, reviewing.
3. For work it delegates, it `add_node`s + leaves nodes claimable (or assigns by
   making a target agent the owner), so other agents/humans pick up the relay.
4. In the limit, the relay chain (`positioning → … → pr`) runs **fully on agents**:
   the kanban-manager assigns each stage to a stage-specialist agent, gates CI,
   merges via the leader path — automated product development on the live board.

This loop is the **on** realization of the same `plan → handoff → dive → return →
push → close → review` cadence — the manager agent simply *is* the actor running the
commands, by dispatch, instead of a human editing a file.

## What is grounded vs. a placeholder
**Grounded now (cite-able):**
- Board mutation = authenticated dispatch with `ctx.caller`
  (`kanban_actions.ex:158-177`, `:321-327`).
- Per-node authz is principal-agnostic (`kanban.ex:715`, `:728`, `:480-485`).
- An agent entity URI is a legal `owner` / `caller` (same code path; the Behavior
  stores whatever `caller_str(ctx)` returns).

**待编排 grounding 补全 (placeholder — another agent is investigating):**
- The **routing rule**: how a chat `@`/message addressed to the board reaches the
  kanban-manager agent (which session-orchestrator / routing-registry path). *No
  `kanban-manager` agent or routing rule exists in the repo yet (grep of
  `.claude/` + `apps/` for `kanban-manager`/`kanban_manager` returns nothing as of
  this writing) — the wiring is unbuilt.*
- The **agent contract**: the kanban-manager agent's definition (its system
  prompt / allowed `kanban.*` caps / how it forms dispatches) — file:line TBD.
- How the agent obtains its `ctx.caps` (the `Ezagent.Capability.cap(:kanban, …)`
  set, `kanban.ex:242-271`) for the actions it's allowed to drive.
- The session-orchestrator handoff: which orchestrator surface turns "lead's chat
  message" into "agent dispatches `kanban.*`".

When the orchestration grounding lands, replace each placeholder bullet above with
the concrete `file:line` (target: the routing rule, the agent definition, and the
cap-grant path), and add a worked example dispatch the kanban-manager agent issues.

## Boundary note
Until the orchestration wiring is grounded, the 8 `commands/` in this skill are
written for a **human or agent contributor invoking them directly** (each command
dispatches the live board). The kanban-manager agent, once wired, runs the **same**
commands as its actor — orchestration adds an automated driver on top of the
existing dispatch surface; it does not change the board contract.
