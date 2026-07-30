# Agent Orchestration Workflow (cc + codex + kimi)

The standing division of labor for driving a task from idea → merged, using the
three agent backends available to the coordinator. Allen set this on 2026-07-19.

## Roles

| Stage | Who | What |
|---|---|---|
| **Plan** | **Claude Code (cc)** — the coordinator | Brainstorm → spec → PR-split plan. Owns architecture, sequencing, and the acceptance criteria. |
| **Implement** | **Kimi (K3, 1M ctx)** | Executes the actual PR development (writes the code + tests) from cc's plan, per-PR. |
| **Adversarial review + pre-merge checks** | **Codex** | Reviews each PR adversarially and runs the pre-merge checks before it lands. |
| **Final check + merge** | **Claude Code (cc)** | Does the overall pass, verifies acceptance empirically, and plans/executes the merge. |

**Codex-down fallback:** if codex's backend is unavailable (stream-disconnect), the
coordinator dispatches a **subagent** (opus) to perform the adversarial review +
pre-merge checks in codex's place — the review gate is never skipped.

## Kimi (K3) — the implementer

- **CLI:** `~/.local/bin/kimi` (install: `curl -L code.kimi.com/install.sh | bash` → `uv tool install kimi-cli`). Auth = **`kimi login`** (device-code OAuth, login-based, NOT an API key).
- **Model:** `kimi-code/k3` — **1,048,576 (1M) context**, display name "K3". (Alternatives: `kimi-code/kimi-for-coding` = K2.7, 256K, default; `-highspeed`.)
- **Headless dispatch (the codex-equivalent):**
  ```
  kimi -w <repo> --print --afk --yolo -m kimi-code/k3 --final-message-only -p "<task>"
  ```
  - `--print`/`--afk`/`--yolo` → non-interactive, auto-approve tool calls (read/write/run).
  - `--final-message-only` → clean output. Session is resumable: `kimi -r <session-id>`.
  - Reads the real codebase (and falls back to git history for files not in the working tree).
- **MCP:** `kimi-code` (npm `kimi-mcp-server`) exposes delegation tools (`kimi_query`,
  `kimi_verify`, `kimi_analyze`, `kimi_resume`, `kimi_status`) for token-saving
  codebase delegation. Config lives in a project `.mcp.json` (gitignored/per-dev;
  see setup note below).

## Codex — the reviewer

**Updated 2026-07-30 (Allen's directive):** dispatch through **`omp`** now, not the
`codex:codex-rescue` agent / `codex-cc-plugin`. Full invocation contract, prompt
template, auth, and a verified test transcript live in
[dev-together's references/codex-review.md](../.claude/skills/dev-together/references/codex-review.md)
(`.claude/skills/dev-together/references/codex-review.md` from repo root). Short
version:

```bash
omp -p --model openai-codex/gpt-5.6-sol \
  --tools=read,grep,glob,bash,lsp --auto-approve --no-session \
  --cwd <repo-root> "@<prompt-file>"
```

Static-only (no `mix`/tests/edits), prompt ends with a required `VERDICT:` line.
Auth is via omp's own auth-broker (ChatGPT Pro OAuth) — check with
`omp token openai-codex` — not the real `codex` CLI's `CODEX_HOME`. This talks
directly to the `openai-codex` model family (`omp models`) with no background
broker process, which sidesteps the zombie-process failure mode below.

- **Superseded, not deleted:** the `codex:codex-rescue` agent / `codex-cc-plugin`
  (`/codex:adversarial-review`, `/codex:review`, etc.) still exists and still
  produces a *structured* JSON verdict schema that the `omp` free-form path does
  not replicate — see the reference doc for when that distinction matters. Do not
  remove the plugin; just don't reach for it as the default review dispatch.
- **Zombie-process caveat (legacy, `codex-cc-plugin` only):** accumulated stale
  `codex app-server`/broker/code-mode-host processes across old worktrees exhaust
  the account and cause `stream disconnected` failures that look like a backend
  outage. If a `codex-cc-plugin` call starts failing:
  `pkill -f "app-server-broker.mjs"; pkill -f "codex app-server"; pkill -f codex-code-mode-host; pkill -x codex`
  (they respawn clean on next use). Diagnosed 2026-07-19 (34 zombies → 1 fixed it).

## Claude Code (cc) — the coordinator

Plans, verifies acceptance empirically (fail-before/pass-after), and gates the merge.
Never merges a security-sensitive PR on self-review alone: the named review gate
(codex, or the subagent fallback) is a precondition.

## Setup note — `.mcp.json` is per-dev

`.mcp.json` is `.gitignore`d (it carries machine-specific absolute paths, e.g. the
`esr-bridge` build path). To share the `kimi-code` MCP team-wide, add the block below
to your **local** project `.mcp.json` (do not commit machine paths); this doc is the
shared source of truth for what the block should contain:

```json
"kimi-code": { "command": "npx", "args": ["-y", "kimi-mcp-server"] }
```
