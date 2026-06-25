# `kanban-on-ezagent handoff` (node-owner — decentralized relay)

The relay step. **Not** a central lead dispatching the day's work — the owner of a
just-finished stage hands the **next stage** to others by **dispatching `add_node`**.
Work moves peer-to-peer along the 9-stage chain (see SKILL.md §Roles).

**Delegate to:** **superpowers:brainstorming** (settle the next stage's load-bearing
decisions) + **codex-rescue** (static-only adversarial review).

**Do (as the owner of the finished stage N):**
1. **Dispatch `add_node`** for stage N+1 (or stage N, when the same stage spans more
   work) under the finished node: `target = with_action(uri, :kanban, :add_node)`,
   `args: %{parent_id: "<finished node id>", title: "<next stage title>"}`,
   `mode: :call` ([../references/live-board-access.md](../references/live-board-access.md)).
   The new node is born `owner: nil, status: :unassigned` (`new_node/4`,
   `kanban.ex:686-697`) so it is **claimable** — relay, not assignment. It inherits
   the parent's stage; if N+1 differs, dispatch `set_stage` — the Kind enforces 相邻棒
   推进 (child = parent stage or next stage, `stage_fits?` `kanban.ex:439-462`), so a
   skip is rejected at dispatch, not by convention.
2. **The requirement comes from the node, not a fresh spec.** Read the next stage's
   need off the artifacts already on the parent node (its `artifacts`/`metrics`, read
   via `get_tree`). Do not re-author the requirement; derive the handoff from what
   the live node already carries.
3. Brainstorm the next stage's design to settle its load-bearing decisions
   (**superpowers:brainstorming**), then an **adversarial review** (Claude
   self-review + a **codex-rescue** static pass — each told to *attack the design*,
   not proofread). The handoff ships only after it survives review.
4. Author the handoff applying [../references/handoff-standard.md](../references/handoff-standard.md)
   (DoD = a demonstrable artifact, here including **the live node advanced (by
   dispatch) + its artifact attached via `attach_artifact`**; discuss-first; defer
   rules; per-task-branch merge). It must cite the **live board node id** it relays
   from.
5. Save to `docs/together/<date>/handoffs/<task>.md` + emit a **paste-ready prompt**
   the owner drops for whoever (human or agent) claims the next node. **On-ezagent
   note:** the claimer may be an **agent** — its dispatch `claim_node` makes the agent
   entity URI the owner, first-class (see [../references/agent-orchestration.md](../references/agent-orchestration.md)).

**Output:** a new claimable node on the live board (created by `add_node` dispatch) +
`docs/together/<date>/handoffs/<task>.md` + a paste-ready relay prompt.
