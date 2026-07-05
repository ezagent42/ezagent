# kanban-team collaboration protocol (extractable module)

> This file is a SELF-CONTAINED, team-specific collaboration protocol. It lives
> in the pm-coordinator skill for now only because the platform has no workflow-
> orchestration module yet. When that module lands (feat/ezagent-scout, spec §9
> Q5), MOVE THIS FILE WHOLESALE into it and the pm skill reverts to pure ability.
> Keep it physically separable — do not weave its details into SKILL.md.
>
> Routing vs protocol (spec §0.1): the Definition's `routing_rules` only
> TRANSPORT the completion signal to the pm role; THIS file is the collaboration
> agreement. The single contract point between them: the completion-marker
> literal below MUST be byte-identical to the kanban-team Definition's
> `routing_rules` matcher `arg` (spec §4.2).

## (a0) The board is NOT a team member — it is created by the world/owner

The kanban board (`kanban-manager`, a `native` **passive** board actor) is a
workspace-level data actor addressed by its own URI
(`entity://<ws>/agent/<id>`), NOT a member of your session. It is created by the
owner in the world **看板 / `/plugins/kanban`** page (the existing "new board"
create path), not by you and not at team install. You never `@`-mention it and
never try to make it join.

You reach the board purely by DISPATCH: you hold a cap for every `kanban.<action>`
(granted to you at materialize), and you dispatch those actions to the board's
URI. So, before driving the board:

- **Ensure a board exists.** If the owner has already created one for this work,
  use its URI. If none exists, ask the owner to create a board on the 看板 /
  `/plugins/kanban` page (one click, "new board") and tell you which one to use —
  then dispatch `kanban.<action>` to that board URI. Do NOT try to create the
  board yourself: board creation is an operator/world-UI action, not one of your
  kanban tools.

## (a) The board — 9-stage product-dev chain

The board (the `kanban-manager` workspace actor, see §a0 — not a member) carries
the 9-stage product-dev chain. Stages, in order:

positioning → metric → pain → anchor → ux → feature → issue → test → pr

- Each card advances one stage at a time; a stage's entry condition is that the
  prior stage's artifact exists.
- `pr` is the CI-gated closing stage — only advance a card into `pr` once CI is
  green on the corresponding return.
- Per-stage discipline (entry / advance):
  - **positioning** — who it's for + the wedge is stated; advance when the target
    user + positioning line exist.
  - **metric** — the success metric is named; advance when it is measurable.
  - **pain** — the concrete user pain is written; advance when it is evidenced.
  - **anchor** — the reference/anchor product or behavior is chosen; advance when
    the anchor is fixed.
  - **ux** — the interaction shape is sketched; advance when the flow is legible.
  - **feature** — the feature is specified enough to hand off; advance when a
    handoff can be written from it.
  - **issue** — the build issue(s) exist; advance when the issue has a DoD.
  - **test** — tests exist and describe the DoD; advance when tests are written.
  - **pr** — the return's PR is CI-green + rebased; advance (close) only then.

## (b) Assigning work — the dev-together git-handoff workflow (NOT a raw @mention)

The real cooperation between you and the dev is the dev-together git-handoff
workflow (git + markdown + CI), NOT ezagent message routing. Routing only carries
the "I'm done" signal back to you.

- The owner tells you what they want; translate it into board moves + a task.
- Assign build work by **writing a markdown handoff** (`handoffs/<task>.md`, with
  a DoD) for the `dev-together` member — the dev-together `handoff` artifact. You
  are NOT computing routing for a worker; you are producing a spec.
- `dev-together` then:
  - `dive`s — task branch off `main`, TDD, PR into the task branch;
  - `return`s — CI green + rebased on `main` + a per-line DoD reconciliation in
    `returns/<task>.md`;
  - sends a **completion signal**.
- **The completion marker is the `__done__` header** (single contract point — it
  MUST match the Definition's `routing_rules` matcher `arg`, spec §4.2). The
  signal message should also carry the card id + the target stage.
- That signal is routed to you by the kanban-team rules — it only tells you the
  return is ready to review. The branch / CI / DoD live in the return + git, NOT
  in the message. Do not read routing as a workflow engine.

## (c) Reviewing + advancing

- On the completion signal: **review the dev's `returns/<task>.md`** — DoD
  reconciled line-by-line, CI green, rebased on `main`.
- THEN advance the card via the kanban tools (`kanban.<action>`: create a card,
  assign it, move its stage).
- `pr` is CI-gated: only advance a card to `pr` once CI is green on the return.
- Summarize the change back to the owner (what card moved, to which stage, why).

## Contract point (protocol ↔ transport)

The completion marker literal `__done__` in (b) MUST equal the kanban-team
Definition's `routing_rules` matcher `arg` (spec §4.2). If they diverge, the
dev's signal is not recognized by routing and never reaches you. Changing either
side requires changing the other. `scripts/relay-signal-check.sh` asserts this
literal is present in this protocol module.
