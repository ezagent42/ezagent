---
name: kimi-dispatch
description: >-
  Use when the coordinator wants to hand a bounded, whole-PR implementation task
  to Kimi (K3, 1M context) via the headless CLI — the implementer lane in the
  cc→kimi→codex→cc orchestration. Trigger on "dispatch to kimi", "give this to
  kimi", "use kimi to implement", "kimi headless", or when splitting an
  implementation chunk out to Kimi. Covers the correct v0.29 CLI invocation,
  auth, the bounded-handoff pattern, isolated-worktree setup, and completion
  polling. Do NOT trigger for interactive kimi use, kimi-mcp read/analyze
  delegation, or non-implementation questions.
---

# kimi-dispatch — hand a whole PR to Kimi (K3) headless

Kimi K3 (`kimi-code/k3`, 1,048,576-token context) is the **implementer** in the
standing `cc → kimi → codex → cc` division of labor: cc plans + writes the
bounded handoff, kimi implements the PR, codex adversarially reviews, cc
final-checks + merges.

## Install + auth (one-time)
- CLI lives at `~/.kimi-code/bin/kimi` (install: `curl -L code.kimi.com/install.sh | bash`).
- Auth is **login-based** device-code OAuth, NOT an API key: `kimi login`.
  Verify with `kimi doctor`. Creds persist under `~/.kimi-code/oauth` + `credentials`.

## The invocation (v0.29 — VERIFIED 2026-07-24)
```bash
cd <target-worktree>            # working dir = cwd; kimi reads/writes here
export PATH="$HOME/.kimi-code/bin:$PATH"
kimi -m kimi-code/k3 -p "<the bounded handoff>" > kimi-run.log 2>&1
```
- `-p "<prompt>"` runs **non-interactively and agentically**: kimi executes tools
  (read/write/run) on its own and prints the final response. VERIFIED: `-p` alone
  runs shell/edit tools without any approval flag.
- `-m kimi-code/k3` selects K3 (1M ctx). Aliases in `~/.kimi-code/config.toml`.
- Resumable: the run ends with `To resume this session: kimi -r <session-id>`.

**STALE FLAGS — do NOT use** (the older orchestration-doc invocation is wrong for
v0.29): `-w <repo>` (removed — use `cd`), `--afk` (gone — `-p` is the headless
mode), `--print` / `--final-message-only` (gone), and `-y`/`--yolo`/`--auto`
(these **cannot combine with `-p`** — `-p` is already non-interactive). Passing
any of them exits with an `unknown option` / `Cannot combine` error.

## Dispatch pattern (whole-PR)
1. **cc writes a precise bounded handoff**: goal + the per-site/file plan + hard
   out-of-scope + the DoD (gates + suites) + "the enforcing gate is your worklist"
   where one exists. Save it to a file and pass via `-p "$(cat handoff.md)"`.
2. **Isolate**: run in a dedicated `git worktree add .worktrees/<task> origin/main`
   (or the intended baseline) so kimi's writes don't collide with other work.
3. **Launch in the background** (Bash `run_in_background`), redirect to a log.
4. **Poll for completion — do NOT kill early.** Whole-PR runs are SLOW and
   read-heavy: budget **~60–90 min**. Kimi typically reads/analyzes for the first
   ~99 steps and writes NOTHING, then writes + commits in a burst near the end.
   Killing at "0 writes so far" produces the FALSE impression it doesn't converge —
   it does. Poll the log for the `To resume this session:` marker (or a
   `KIMI_..._EXIT` sentinel you append), not for early writes.
5. **VERIFY it actually FINISHED — never assume "offline == done."** A COMPLETED
   run exits *naturally*: the log ends with the `To resume this session:` marker /
   your `KIMI_..._EXIT` sentinel + a final report. A run whose process just went away
   (nonzero exit, ENOSPC/disk-full, crash, killed, API stream-disconnect) did **NOT**
   finish — even if it left commits. Its committed diff is INTERMEDIATE, not the DoD:
   it may have unresolved test failures it was still investigating and **uncommitted
   work stashed** (`git stash list` in the worktree). Before treating it as done:
   read the log tail for HOW it ended; inspect the worktree (`git status`,
   `git stash list`, `git log`); and if it did NOT exit cleanly, **resume the session
   (`kimi -r <session-id>`; kimi sessions live under `~/.kimi-code/sessions/wd_*`) and
   let it run to a natural finish + DoD-green** before you review/merge. On any
   coordinator restart, check running/interrupted sessions and RESUME them first.
   (Learned the hard way — a C6 run died on disk-ENOSPC mid-verification with 8
   unresolved failures + stashed fixes; its 3 commits were mistaken for "done.")
6. **cc gates the result**: codex adversarial review + cc final-check + merge — a
   kimi PR merges through the same review gate as any other.

## Completeness for "migrate/gate ALL X" tasks
Dispatch mode (whole-PR vs bounded sub-steps) does NOT decide completeness — an
enforced **enumerator gate** does. For any "migrate/gate ALL X" task, cc builds
the enumerator gate, runs it empty-allowlist to produce the worklist, and enforces
it in CI — regardless of who implements or how the work is chunked. Hand kimi that
gate as its worklist.

## kimi-mcp (separate lane)
The `kimi-code` MCP (`npx kimi-mcp-server`, added to a project `.mcp.json`) exposes
`kimi_query`/`kimi_verify`/`kimi_analyze`/`kimi_resume`/`kimi_status` for
**token-saving read/analysis delegation** — NOT whole-PR implementation. MCP
servers load only at session start, so adding it needs a session restart. For
implementing a PR, use the CLI above.
