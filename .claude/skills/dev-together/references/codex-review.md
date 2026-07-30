# Codex review via `omp` (supersedes `codex-rescue` / `codex-cc-plugin`)

**Status (2026-07-30, Allen's directive):** the `codex@openai-codex` Claude Code
plugin — the `codex-rescue` subagent, `codex-companion.mjs`, and its background
app-server-broker process — is **deprecated** as the way dev-together dispatches a
Codex review. It shells out to a long-lived codex app-server process that
accumulates zombie processes across old worktrees and periodically fails with
"stream disconnected" (see `docs/agent-orchestration.md`'s former codex-down
fallback note). Use the `omp` CLI directly instead: it talks to the same
GPT-5.x-codex-family models over its own authenticated session, with no
background broker process to manage or leak.

**Do not delete the `codex-cc-plugin` yet.** `/codex:adversarial-review` and
`/codex:review` still produce a *structured* JSON verdict (schema at
`~/.claude/plugins/marketplaces/openai-codex/plugins/codex/schemas/review-output.schema.json`:
`verdict` = `approve`|`needs-attention`, `findings[]` with
`file`/`line_start`/`line_end`/`confidence`/`recommendation`). The `omp` path below
is free-form text ending in a `VERDICT:` line — a correct drop-in for
dev-together's `codex-rescue` static pass (which was *also* free-form text,
forwarded verbatim from `codex-companion.mjs task` — see the plugin's
`codex-cli-runtime` skill), but it does **not** replicate the structured-JSON
`/codex:adversarial-review` contract. If some other caller depends on that exact
schema, keep using the plugin for that call site.

## Invocation

```bash
omp -p --model openai-codex/gpt-5.6-sol \
  --tools=read,grep,glob,bash,lsp \
  --auto-approve --no-session \
  --cwd <repo-root> \
  "@<path-to-prompt-file>"      # or pass the prompt as a plain inline string
```

- `-p` / `--print` — non-interactive: process the prompt and exit (no TUI, no
  approval loop to babysit).
- `--model openai-codex/gpt-5.6-sol` — the GPT-5.6 "sol" codex-family model. This
  is the same model a prior omp session already used for a task literally named
  `CodexSpecReview`, and the one verified end-to-end below. `omp models` lists the
  full `openai-codex` provider family: `gpt-5.3-codex-spark`, `gpt-5.4`,
  `gpt-5.4-mini`, `gpt-5.5`, `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`. For the
  fast/cheap variant (what `codex-rescue`'s `spark` mapping used), pass
  `--model openai-codex/gpt-5.3-codex-spark` instead.
- `--tools=read,grep,glob,bash,lsp` — **omits `edit`/`write`**. This is
  prompt-adjacent read-only enforcement, not a real sandbox: `bash` can still
  mutate the filesystem if the model chooses to. omp has no equivalent of
  `codex exec --sandbox read-only`. "Static-only, no mix" is enforced by
  instructing the model in the prompt (template below) — the same trust model
  `codex-rescue` already relied on for its "static-only" reviews.
- `--auto-approve` — required in non-interactive mode; no human is present to
  approve tool calls turn-by-turn.
- `--no-session` — ephemeral run. Drop it (and add `--session-dir <dir>`) to
  persist a resumable transcript; `--resume`/`-r` picks it back up later.
- `--cwd <repo-root>` — run from the target repo so omp's own `read`/`grep`/`bash`
  tools resolve paths against the real files. `@<promptfile>` inlines a file's
  contents into the message; a plain string argument works too for short prompts.

## Prompt template (static-only, VERDICT-terminated)

```
STATIC-ONLY REVIEW TASK. Do not run `mix`, do not run tests, do not run any
build/compile command, do not edit or write any files. Read-only investigation only.

<the actual review / spec / question, with concrete file paths and a clear ask>

End your entire response with exactly one line in this exact format (always
include it, even if you could not complete the task):
VERDICT: <PASS|FAIL|CONCERNS> — <one clause reason>
```

Adapt the adversarial framing from the plugin's own
`prompts/adversarial-review.md` (skepticism-first, attack the design not the
style, name a concrete file:line for every finding) when the ask is a real
adversarial review rather than a static Q&A smoke test.

## Auth / prerequisites

- `omp` binary at `~/.local/bin/omp` (v17.2.0 as of 2026-07-30).
- The `openai-codex` provider is authenticated through omp's **own** auth-broker
  (ChatGPT Pro OAuth) — **not** the real `codex` CLI's `CODEX_HOME` /
  `~/.codex/auth.json`. Check with `omp token openai-codex` (prints a live JWT on
  success; empty output or an error means the omp-side login needs to be redone —
  see `omp auth-broker --help` for `login`/`status`/`list`).
- No extra proxy or env var was required in testing beyond `omp` being installed
  and already logged in.

## Verified 2026-07-30

Ran a real static review against `apps/ezagent_core` in this repo
(`--model openai-codex/gpt-5.6-sol`, `--tools=read,grep,glob,bash,lsp`, ~75s wall
clock). It returned 3 file line-counts that matched `wc -l` exactly
(`data_case.ex` 500, `application.ex` 320, `ets_owner.ex` 210) and cited a real,
checkable code detail — `EzagentCore.DataCase.setup_sandbox/1` calling
`start_owner_stable!/1`, then registering `on_exit(stop_owner)` and
`on_exit(&drain_to_quiescence/0)` in that order, relying on ExUnit's LIFO
teardown — that checks out against the file (function names and behavior exact;
the cited line range `:97-103` drifted a few lines from the actual `:106-110`).
It ended with the required `VERDICT:` line. This confirms the path reaches a real
model that reads the actual repo, not a stub or a hallucinated summary.

Known gaps to account for in real reviews:
- **Line-number citations can drift by a few lines.** Verify before treating a
  finding's `file:line` as exact, especially for anything line-anchored (see
  `reference_ezagent_static_gate_topology` conventions elsewhere in this repo).
- **No enforced read-only sandbox** (see the `--tools` note above). Don't hand
  this an auto-approved run against a repo you care about without reviewing what
  it actually did afterward.
- **Response language follows the model's own judgment**, not the prompt's
  language — an English prompt produced a Chinese answer in testing. State the
  desired language explicitly if it matters for the consumer.
