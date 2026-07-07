# gh protocol — GitHub CLI usage on both sides of the kanban-team loop

> Companion module to `kanban-team-collaboration.md`. That file defines the
> collaboration agreement (board stages, handoff/return, `__done__` signal);
> THIS file defines how both sides touch GitHub through the `gh` CLI, and how
> GitHub facts (PR URL, CI status, commit blobs) get pinned onto the board.
> Same extractability rule applies: keep this physically separable, do not
> weave it into SKILL.md.

## (1) Preflight self-check — `gh auth status`

Before ANY step that touches GitHub (push, `gh pr create`, `gh pr view`,
`gh pr checks`), run:

```bash
gh auth status
```

- **Non-zero exit = `gh` is not authenticated.** Report exactly that to the
  owner ("gh 未认证, GitHub 步骤无法执行") and STOP the GitHub-dependent step.
- **Never go silent** about it, and **never pretend a push / PR create
  succeeded** when it did not. A fabricated PR URL on the board is worse than
  a blocked card — it poisons the review step (§3) which trusts the board's
  artifacts.

## (2) dev side — push, PR, pin the REAL URL back onto the node

When the `dev-together` member finishes a `dive` and is preparing to `return`:

1. **Push the task branch** to the remote.
2. **Create the PR and capture the real URL**:

   ```bash
   gh pr create --title "…" --body "…"   # stdout is the PR URL — capture it
   ```

3. **Pin the real URL onto the card's artifacts** via the board's
   putting the URL **in the `__done__` message body**（分工拍板 2026-07-07：
   dev 不做看板操作——register 由助手做）。The URL MUST be the one
   `gh pr create` actually printed — never guessed or constructed.

## (2b) assistant side — register the PR on the card

   On receiving `__done__` with a PR URL, the assistant records it:

   ```bash
   scripts/kanban-cli.sh register_pr '{"id":"<card>","pr":"<PR-URL>"}'
   ```

   `register_pr` only RECORDS the reference as node data (no outbound
   GitHub call, §d step 5).

## (3) assistant side — verify with gh, THEN advance

On reviewing a return (after the `__done__` signal, see §5):

1. **Check the PR state and CI with gh**, using the PR URL from the card's
   artifacts:

   ```bash
   gh pr view <PR-URL> --json state,mergeable,headRefOid
   gh pr checks <PR-URL>
   ```

2. **Only advance the card (`kanban.set_stage`) when checks are green.** This
   is the concrete verification behind the `pr` stage's CI-gate
   (`kanban-team-collaboration.md` §a / §c): green `gh pr checks` output is the
   evidence, not the dev's word.
3. **Pin the reviewed commit** with a permanent blob link:

   ```bash
   scripts/kanban-cli.sh attach_code_file '{"id":"<card>","sha":"<headRefOid>","path":"<file>"}'
   ```

## (4) Failure awareness — never swallow gh errors

Any `gh` invocation can fail (auth expired, network, repo permissions, PR not
found). The agent SEES every non-zero exit code and its stderr:

- **Report the failure verbatim into the chat** — exit code + stderr text —
  so the owner (or the other side) can act on it.
- Do NOT swallow it, do NOT retry silently into a fake success, do NOT
  advance the board on a step whose gh verification failed. A gh failure is a
  visible blocked state, exactly like an unroutable message elsewhere in the
  platform: someone must know.

## (5) Linkage with the `__done__` protocol

- The dev's `__done__` completion signal (contract point,
  `kanban-team-collaboration.md` §b) **should carry the PR URL in the message
  body**, alongside the card id + target stage.
- But the message is a convenience, not the source of truth: **at review time
  the assistant treats the card's artifacts written by `register_pr` (§2) as
  authoritative.** If the message's URL and the registered artifact diverge,
  trust the artifact and flag the divergence in chat.
