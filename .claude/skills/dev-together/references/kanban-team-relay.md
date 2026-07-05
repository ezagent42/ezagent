# kanban-team relay overlay (thin — points to the shared protocol)

> This is a thin, additive overlay for when the dev-together skill runs as the
> `dev-together` member of a kanban-team. It does NOT change the dev-together
> daily cycle (the 8 commands, roles, artifact layout, handoff standard). When
> the kanban-team collaboration protocol moves to a workflow-orchestration module
> (spec §9 Q5), delete this overlay — dev-together reverts to a pure, portable
> capability skill with no kanban-team knowledge.

When running as the `dev-together` member of a kanban-team, follow the shared
collaboration protocol (the single authoritative source):

@../../pm-coordinator/references/kanban-team-collaboration.md

Your only team-specific addition: after a `return` (CI green + rebased + DoD
reconciled in `returns/<task>.md`), send a short completion signal — the
`__done__` header + card id + target stage.

**The `__done__` marker MUST be byte-identical to the kanban-team Definition's
`routing_rules` matcher `arg` (spec §4.2)** — that single line is the only
contract between this protocol and the routing transport. Nothing else about the
dev-together workflow changes.
