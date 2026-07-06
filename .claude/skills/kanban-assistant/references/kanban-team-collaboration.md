# kanban-team collaboration protocol (extractable module)

> This file is a SELF-CONTAINED, team-specific collaboration protocol. It lives
> in the kanban-assistant skill for now only because the platform has no workflow-
> orchestration module yet. When that module lands (feat/ezagent-scout, spec §9
> Q5), MOVE THIS FILE WHOLESALE into it and the kanban-assistant skill reverts to
> pure ability.
> Keep it physically separable — do not weave its details into SKILL.md.
>
> Routing vs protocol (spec §0.1): the Definition's `routing_rules` only
> TRANSPORT the completion signal to the kanban-assistant role; THIS file is the collaboration
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

## (d) Driving the board with the ezagent CLI (the action-face)

Your action-face is the **ezagent CLI** — you move the board by running `mix
ezagent …` from bash. There is NO new tooling to build and NOTHING to change in
the platform: the CLI executor already exists (`EzagentCli.Exec.exec/2` →
`EzagentCli.Dispatch.run_action/4` → `Ezagent.Router.dispatch/1`;
`apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:21,308`). This is skill-layer
teaching over that existing CLI — do NOT touch esr-bridge / core / the domain
agent infrastructure; the action-face is already wired.

### Who you act as

The CLI refuses to run without an identity (no silent admin fallback —
`exec.ex:44-97`, `dispatch.ex:238-271`). You act as **yourself**, the
kanban-assistant member, with **your own caps**: your recipe was granted a cap
for every kanban action, so you can drive the board directly. Pass your identity
either as flags or via the environment:

```bash
mix ezagent <kind> <action> … --token "$EZAGENT_USER_TOKEN" --uri "<your-entity-uri>"
# or set EZAGENT_USER_TOKEN + EZAGENT_ENTITY_URI in the env and drop the flags
```

### Targeting the board

The board is the workspace-level `kanban-manager` agent (§a0), addressed by its
own full URI `entity://<ws>/agent/<uuid>`. You pass that URI as the instance; the
CLI dispatches the action to it (`dispatch.ex:113-147` takes a full `entity://`
URI as-is and appends `?action=kanban.<action>` — the kanban behavior's slice is
`kanban`). The board is an `Entity.Agent`, so the CLI kind segment is `agent`:

```bash
# kanban 动作是 per-instance 挂载的(K5),不进全局 `mix ezagent agent` 命令树。
# 用本 skill 自带的 dispatch 脚本(同 identity→URI→Router.dispatch 机制,CapBAC 不绕):
scripts/kanban-cli.sh <action> '{"<arg>":"<value>", …}'   # 板 URI 与身份来自 EZAGENT_* env
```

**Find the board URI** (never create it yourself — §a0): ask the owner which
board to use, or enumerate the workspace's boards by recipe provenance —
`Ezagent.AgentRecipeResolver.list_by_recipe("kanban-manager", <ws>)` (the same
read model the world 看板 / `/plugins/kanban` page uses to list boards). A board
is a `kanban-manager` agent, so that lookup returns exactly the boards.

### The full loop (each step is one CLI dispatch to the board URI)

1. **Read the board** — `kanban.get_tree` returns the whole node tree, the stage
   chain, and per-node artifacts. Start every turn here.
   `scripts/kanban-cli.sh get_tree '{}'`
2. **Create a card** — `kanban.add_node --parent_id=<pid|""> --title="…"`
   (`parent_id=""` builds a root card; building a root is admin-gated, adding a
   child needs the parent's owner or admin).
3. **Hand off to the dev** — this is NOT a CLI call. Write the markdown handoff
   (`handoffs/<task>.md`, with a DoD) per §b. The dev `dive`s and `return`s, then
   sends the `__done__` completion signal — routed back to you by the kanban-team
   `routing_rules` (§b, the contract point below).
4. **Review + advance** — on the `__done__` signal, review the dev's
   `returns/<task>.md` (§c: DoD reconciled, CI green, rebased). THEN advance the
   card: `kanban.set_stage --id=<card> --stage=<next>`. `pr` is CI-gated — only
   move a card to `pr` once CI is green on the return.
5. **Pin the produced git references (pure data, NO outbound calls)** — attach the
   return's artifacts to the card:
   - `kanban.register_pr --id=<card> --pr=123` — pins the GitHub PR link.
   - `kanban.attach_code_file --id=<card> --sha=<sha> --path=<file>` — pins a
     permanent GitHub blob link for a commit + path.
   - `kanban.attach_artifact --id=<card> --artifact=…` — any other tool artifact.

   These only RECORD git references as node data — there is no GitHub API call.
   The old active GitHub connectors (`sync_github` / `push_pr` / `sync_prs` /
   `save_github_creds`) were removed; the board never reaches out to GitHub. The
   `repo` used to build a PR/blob link is board config data
   (`kanban.set_board_config --github_repo=owner/name`), not a live credential.

6. **Report back to the owner** — summarize what card moved, to which stage, and
   why (§c).

> Note: the CLI grammar above is `mix ezagent <kind> <action> --<kind>=<instance>
> …` and the dispatch target is `<board-uri>?action=kanban.<action>`. If a given
> build does not surface a specific action as a ready subcommand, the SAME
> dispatch is what the CLI wraps — the mechanism (identity → target URI →
> `Router.dispatch`) is the invariant; you are always just dispatching a
> `kanban.<action>` to the board's URI as yourself.

## Contract point (protocol ↔ transport)

The completion marker literal `__done__` in (b) MUST equal the kanban-team
Definition's `routing_rules` matcher `arg` (spec §4.2). If they diverge, the
dev's signal is not recognized by routing and never reaches you. Changing either
side requires changing the other. `scripts/relay-signal-check.sh` asserts this
literal is present in this protocol module.
