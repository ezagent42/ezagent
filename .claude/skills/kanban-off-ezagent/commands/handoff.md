# `kanban-off-ezagent handoff` (node-owner — decentralized relay)

The relay step. **Not** a central lead dispatching the day's work — the owner of a
just-finished stage hands the **next stage** to others. Work moves peer-to-peer
along the 9-stage chain (see SKILL.md §Roles).

**Delegate to:** **superpowers:brainstorming** (settle the next stage's load-bearing
decisions) + **codex-rescue** (static-only adversarial review).

**Do (as the owner of the finished stage N):**
1. **`add_node` on the board** for stage N+1 (or stage N, when the same stage spans
   more work) under the finished node in `docs/board.md`. Set `owner: —` +
   `status: unassigned` so the next node is **claimable** — relay, not assignment.
   The stage must satisfy board-format.md §Validation (parent stage or the next
   stage in the chain — never a skip).
2. **The requirement comes from the node, not a fresh spec.** Read the next stage's
   need off the artifacts already hanging on the board (the parent node's
   `artifact:` / `metric:` lines — requirement docs inline or linked). Do not
   re-author the requirement; derive the handoff from what the board already
   carries.
3. Brainstorm the next stage's design to settle its load-bearing decisions
   (**superpowers:brainstorming**), then an **adversarial review** (Claude
   self-review + a **codex-rescue** static pass — each told to *attack the design*,
   not proofread). The handoff ships only after it survives review.
4. Author the handoff applying [../references/handoff-standard.md](../references/handoff-standard.md)
   (DoD = a demonstrable artifact, here including **the board node advanced + its
   artifact link attached**; discuss-first; defer rules; per-task-branch merge).
   It must cite the **board node id** it relays from.
5. Save to `docs/together/<date>/handoffs/<task>.md` + emit a **paste-ready prompt**
   the owner drops for whoever claims the next node (or hands it to a named peer).

**Output:** a new claimable node on `docs/board.md` + `docs/together/<date>/handoffs/<task>.md`
+ a paste-ready relay prompt.
