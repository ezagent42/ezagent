#!/usr/bin/env bash
# sub-step gate — the "B" git-hook backstop (P0-D6 / ARCHITECTURE Decision #80).
#
# Fires as a Claude Code PreToolUse hook on Bash tool calls. If the command is
# a `git commit` or `git tag`, runs the sub-step gate before allowing it:
#
#   Phase 0:  mix format --check-formatted  +  mix test
#   Phase 1:  + mix ezagent.check_invariants
#   2026-07-28: the test step is `mix ci.fast`, and the gate runs in the
#               worktree being committed to — see "What changed" below.
#
# Gate red  → exit 2 (blocks the tool call; stderr is shown to Claude).
# Not git   → exit 0 immediately (no-op for the vast majority of Bash calls).
#
# What changed 2026-07-28, and why
# --------------------------------
# Two of this hook's assumptions (written at 5199f3699, phase 0) no longer
# hold everywhere. Neither was a regression anyone introduced.
#
#   1. "the commit targets the checkout at CLAUDE_PROJECT_DIR". True when you
#      work directly in the project root — still the case for many, and their
#      behaviour is unchanged by this commit. NOT true when you commit from a
#      `git worktree` linked checkout, which some of us use to keep one task
#      per branch: the hook cd'd to CLAUDE_PROJECT_DIR unconditionally, so it
#      gated whatever that checkout happened to be on rather than the branch
#      being committed. It could pass while the commit was broken, or fail for
#      reasons the commit had nothing to do with. #1523 already computed the
#      target worktree in order to SKIP foreign repos, and its own comment
#      says "keeps esr-ng's OWN worktrees gated" — that intent is only
#      actually delivered by running the gate there.
#   2. "the full suite is green and fast". The green half is a team-wide fact
#      today, not a local quirk: #189 tracks `mix test` as a systemic red on
#      `main` itself, rooted in 2 real bugs plus 4 test defects and blocking
#      the release chain; #1599 greened two of them, the rest are open. So the
#      gate currently cannot pass for anyone touching Elixir, on any machine.
#      (The "fast" half varies: on at least one dev machine the suite does not
#      finish at all, but that is a local symptom, not a claim about yours.)
#      A gate nobody can pass teaches people to bypass it, which costs more
#      than a narrower gate that holds. The test step is therefore
#      `mix ci.fast` — the repo's own documented fast deterministic gate, and
#      the exact set CI's `gate` job runs. This is a deliberate NARROWING: the
#      full suite is no longer run pre-commit, and stays the job of CI and of
#      explicit local runs. When #189 closes, whether to widen this back is
#      worth revisiting.
#
# Not changed, but worth knowing: the gate inherits the caller's environment,
# so a machine whose Postgres is not on the default port sets POSTGRES_PORT
# once in the session env and the mix commands below pick it up.
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
# esr-ng's OWN worktrees gated. No target → assume this project → gate as before.
#
# The commit target is `git -C /abs/path` when present (it overrides the process
# cwd for that git invocation, so it wins over any `cd`), else the first
# `cd /abs/path`. Relative/cwd-relative forms (`git -C ../x`, no leading `/`) are
# not resolved here — same absolute-path-only scope as the original — and fall
# back to CLAUDE_PROJECT_DIR, which is safe (gates the project root, not a guess).
abs_common() { ( cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P ); }
_target_dir=$(printf '%s' "$input" | grep -oE 'git[[:space:]]+-C[[:space:]]+/[^ "'\''&;|]+' | head -1 | sed -E 's/^git[[:space:]]+-C[[:space:]]+//')
[ -n "${_target_dir:-}" ] || _target_dir=$(printf '%s' "$input" | grep -oE 'cd[[:space:]]+/[^ "'\''&;|]+' | head -1 | sed -E 's/^cd[[:space:]]+//')
if [ -n "${_target_dir:-}" ] && [ -d "$_target_dir" ]; then
  _tc=$(abs_common "$_target_dir")
  _pc=$(abs_common "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}")
  if [ -n "$_tc" ] && [ -n "$_pc" ] && [ "$_tc" != "$_pc" ]; then
    exit 0
  fi
fi

# Run the gate in the worktree the commit actually targets. `_target_dir` was
# computed above from the command's own `cd`, and the check above already
# established it belongs to this repo (same git-common-dir).
#
# Resolve it to that worktree's ROOT, not the cd'd path itself: `cd
# apps/ezagent_core && git commit` is an ordinary shape, and the mix commands
# below must run at the umbrella root to mean anything. Falling back to
# CLAUDE_PROJECT_DIR keeps the previous behaviour for commands with no `cd`,
# and a `cd` that cannot be resolved falls back too rather than guessing.
_gate_dir=""
if [ -n "${_target_dir:-}" ] && [ -d "$_target_dir" ]; then
  _gate_dir=$( cd "$_target_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null )
fi
[ -n "$_gate_dir" ] && [ -d "$_gate_dir" ] || _gate_dir="${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

cd "$_gate_dir" || {
  echo "[sub-step-gate] cannot cd to gate dir: $_gate_dir" >&2
  exit 2
}

echo "[sub-step-gate] gating: $(pwd -P) ($(git branch --show-current 2>/dev/null || echo 'detached'))" >&2

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

echo "[sub-step-gate] → mix ci.fast" >&2
TEST_OUTPUT=$(mix ci.fast 2>&1)
TEST_EXIT=$?
if [ $TEST_EXIT -ne 0 ]; then
  echo "$TEST_OUTPUT" | tail -30 >&2
  echo "[sub-step-gate] BLOCKED: mix ci.fast failed (exit=$TEST_EXIT, tail above)" >&2
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
