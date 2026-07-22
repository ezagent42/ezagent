#!/usr/bin/env bash
# sub-step gate — the "B" git-hook backstop (P0-D6 / ARCHITECTURE Decision #80).
#
# Fires as a Claude Code PreToolUse hook on Bash tool calls. If the command is
# a `git commit` or `git tag`, runs the sub-step gate before allowing it:
#
#   Phase 0:  mix format --check-formatted  +  mix test
#   Phase 1:  + mix ezagent.check_invariants  (this commit)
#
# Gate red  → exit 2 (blocks the tool call; stderr is shown to Claude).
# Not git   → exit 0 immediately (no-op for the vast majority of Bash calls).
#
# This is a *backstop*, not the primary mechanism — the primary mechanism is
# agent discipline (/goal prompt + CLAUDE.md 贯穿条款). Each subsequent phase's
# brainstorm extends this script: Phase 1 adds the invariants check;
# Phase 2+ adds e2e flow checks once those exist.
set -uo pipefail

input=$(cat)

# Only gate `git commit` or `git tag` mutation operations.
# Matches `git commit`, any `git tag` with flags (short or long form,
# e.g. `-a`, `-d`, `-f`, `-s`, `--delete`, `--annotate`, `--force`),
# and `git tag <name>` (non-option arg).
# Also matches queries like `git tag --sort` / `git tag --list` as
# collateral — the gate is intentionally wide; a false-positive merely
# runs the (harmless) gate.
if ! printf '%s' "$input" | grep -qE 'git[[:space:]]+(commit|tag[[:space:]]+(--?[A-Za-z]|[^-]))'; then
  exit 0
fi

# Multi-repo sessions: a `git commit` may target a DIFFERENT repo than this
# project (a sibling repo added to the session, or its worktree). This gate is
# esr-ng-specific (mix format / mix test), so running it on a foreign commit is
# a false gate. Bash commands cd into their target repo first, so if the first
# `cd /abs/path` in the command resolves to a repo whose shared .git dir differs
# from this project's, skip. Comparing git-common-dir (not toplevel) keeps
# esr-ng's OWN worktrees gated. No `cd` → assume this project → gate as before.
abs_common() { ( cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P ); }
_target_dir=$(printf '%s' "$input" | grep -oE 'cd[[:space:]]+/[^ "'\''&;|]+' | head -1 | sed -E 's/^cd[[:space:]]+//')
if [ -n "${_target_dir:-}" ] && [ -d "$_target_dir" ]; then
  _tc=$(abs_common "$_target_dir")
  _pc=$(abs_common "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}")
  if [ -n "$_tc" ] && [ -n "$_pc" ] && [ "$_tc" != "$_pc" ]; then
    exit 0
  fi
fi

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}" || {
  echo "[sub-step-gate] cannot cd to repo root" >&2
  exit 2
}

# Short-circuit: the three gate checks (mix format / mix test /
# mix ezagent.check_invariants) only act on Elixir code. If the
# staged change touches no .ex/.exs/.heex files (pure docs / sh /
# config / excalidraw / etc.), the gate has nothing meaningful to
# verify — skip it. This also unblocks commits on dev machines
# that lack a C toolchain for NIF compilation (mix format triggers
# bcrypt_elixir's NIF build before it can check formatting).
# Tag commits aren't filtered (they're release events, run the gate).
if printf '%s' "$input" | grep -qE 'git[[:space:]]+commit'; then
  staged_elixir=$(git diff --cached --name-only --diff-filter=ACMR \
    2>/dev/null | grep -E '\.(ex|exs|heex)$' || true)
  if [ -z "$staged_elixir" ]; then
    echo "[sub-step-gate] no Elixir files staged — gate skipped" >&2
    exit 0
  fi
fi

echo "[sub-step-gate] git commit/tag detected — running Phase 1 gate" >&2

echo "[sub-step-gate] → mix format --check-formatted" >&2
FMT_OUTPUT=$(mix format --check-formatted 2>&1)
if [ $? -ne 0 ]; then
  echo "$FMT_OUTPUT" | tail -10 >&2
  echo "[sub-step-gate] BLOCKED: code not formatted (run: mix format)" >&2
  exit 2
fi

echo "[sub-step-gate] → mix test" >&2
TEST_OUTPUT=$(mix test 2>&1)
TEST_EXIT=$?
if [ $TEST_EXIT -ne 0 ]; then
  echo "$TEST_OUTPUT" | tail -30 >&2
  echo "[sub-step-gate] BLOCKED: mix test failed (exit=$TEST_EXIT, tail above)" >&2
  exit 2
fi

echo "[sub-step-gate] → mix ezagent.check_invariants" >&2
INV_OUTPUT=$(mix ezagent.check_invariants 2>&1)
if [ $? -ne 0 ]; then
  echo "$INV_OUTPUT" | tail -10 >&2
  echo "[sub-step-gate] BLOCKED: invariant violation (tail above)" >&2
  exit 2
fi

echo "[sub-step-gate] gate green — commit/tag allowed" >&2
exit 0
