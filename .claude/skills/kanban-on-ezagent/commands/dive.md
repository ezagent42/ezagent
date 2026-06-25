# `kanban-on-ezagent dive <node>` (contributor — human OR agent)

Claim a live board node and build that stage's work. Anyone can claim — including
the leader wearing a contributor hat, **and including an agent** (its dispatch
`claim_node` makes the agent entity URI the owner; see SKILL.md §Roles +
[../references/agent-orchestration.md](../references/agent-orchestration.md)).

**Delegate to:** **superpowers:writing-plans** (PR-sized breakdown) →
**superpowers:executing-plans** / **superpowers:subagent-driven-development** (TDD
execution) + the handoff's required project skills (**ezagent-developer**, etc.).

**Do:**
1. **Dispatch `claim_node` on the live board** — `target = with_action(uri, :kanban,
   :claim_node)`, `args: %{id: "<node>"}`, `mode: :call`, ctx carrying your caller
   URI ([../references/live-board-access.md](../references/live-board-access.md)). The
   Kind sets `owner: caller, status: :claimed` (`kanban.ex:469-489`) and rejects if
   already owned (`:already_claimed`). Then **dispatch `set_status`** with
   `%{id, status: "doing"}` (`kanban.ex:496-510`). Per-node `owner_or_admin?` now
   means only you (or admin) can mutate this node (`kanban.ex:715`) — enforced in the
   Kind, not on trust. Read the matching handoff in `docs/together/<date>/handoffs/`
   + every item in its "required reading" (skills + docs, incl.
   `docs/guide/world-coordination.md` if it touches `world`).
2. Create the **task branch off the latest `main`** (the branch named in the handoff
   / `plan.md`).
3. Break it into PR-sized steps; confirm scope against `plan.md` + the conflict map
   before building.
4. Implement TDD; **all PRs merge into the task branch — never `main`**; rebase on
   `main` often. Drive toward the node's **DoD artifact** (the live node advanced by
   dispatch + a demonstrable artifact attached via `attach_artifact`).

**Daily, not per-stage.** A claimed node may stay in its **same stage** for days —
keep `status: doing` and record daily progress on `return` (by dispatch); the stage
only advances when the work completes (dispatched by `close`/`review`).

**Output:** the live node is now `owner: you, status: doing` (by dispatch); work on
the task branch progressing to the node's DoD artifact; ready for `return`.
