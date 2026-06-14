#!/usr/bin/env bash
#
# socialware_substrate_gate.sh — the 基座化 (im → session → agent) milestone gate.
#
# Run this after each codex 基座化 PR (PR-A / PR-9a / PR-9b / PR-9c) merges to
# main, to get a one-command verdict on whether the split is on track.
#
# The gate has TWO halves, because they prove different things:
#
#   (1) STRUCTURAL — proves the split ACTUALLY HAPPENED.
#       A behavioral test passes whether or not the domains are physically
#       separated (the monolith works too), so behavioral tests can NOT be the
#       completion gate. Only the architecture-fitness checks fail when the
#       split is incomplete. Per memory `feedback_completion_requires_invariant_test`.
#         - mix ezagent.arch.scan            (line-coupled allowlists, slice ownership, …)
#         - mix ezagent.check_invariants[.lifecycle]
#         - mix ezagent.doc.scan             (documentation ratchet)
#         - the im→session→agent ACYCLIC arch-fitness invariant test
#           (codex lands this in PR-9a, allowlisted; PR-9c shrinks it to 0).
#           This script auto-detects it and runs it once present; until then it
#           reports ⏳ so you can see the structural gate is not yet complete.
#
#   (2) BEHAVIORAL companion — proves the split DID NOT BREAK transport.
#       The deterministic E2E set that exercises the im→session→agent seams
#       (agent.receive → AgentBridge, session routing/membership, mention-gated
#       routing, sender-locked relay, multi-workspace dispatch, destroy cascade).
#       These must stay green across every split PR.
#
# Definition of done (handoff §8): im→session→agent acyclic with the arch-fitness
# invariant at 0 allowlist, full umbrella suite green. THIS script's STRUCTURAL
# half is that gate; the BEHAVIORAL half is the regression guard around it.
#
# Usage:
#   scripts/socialware_substrate_gate.sh            # full gate
#   scripts/socialware_substrate_gate.sh --structural-only
#   scripts/socialware_substrate_gate.sh --behavioral-only
#
# ALWAYS run from the umbrella root. The script force-compiles first because a
# stale .beam lies (esp. after editing a Mix-task gate). Per the handoff §5.
#
set -uo pipefail

MODE="${1:-full}"
FAILED=0
declare -a RESULTS=()

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; RESULTS+=("PASS  $1"); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; RESULTS+=("FAIL  $1"); FAILED=1; }
skip() { printf '  \033[33m⏳ \033[0m%s\n' "$1"; RESULTS+=("⏳     $1"); }

run() { # run "<label>" <cmd...>
  local label="$1"; shift
  if "$@" >/tmp/substrate_gate_step.log 2>&1; then
    pass "$label"
  else
    fail "$label  (tail of output:)"
    tail -15 /tmp/substrate_gate_step.log | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
# 0. Force-compile (stale .beam lies — handoff §5)
# ---------------------------------------------------------------------------
say "force compile"
run "mix compile --force" mix compile --force

# ---------------------------------------------------------------------------
# 1. STRUCTURAL gates
# ---------------------------------------------------------------------------
if [ "$MODE" != "--behavioral-only" ]; then
  say "STRUCTURAL — architecture fitness"
  run "mix ezagent.arch.scan"                 mix ezagent.arch.scan
  run "mix ezagent.check_invariants"          mix ezagent.check_invariants
  run "mix ezagent.check_invariants.lifecycle" mix ezagent.check_invariants.lifecycle
  run "mix ezagent.doc.scan"                  mix ezagent.doc.scan

  # The im→session→agent acyclic arch-fitness invariant test. codex lands this
  # in PR-9a (allowlisted) and shrinks the allowlist to 0 by PR-9c. Auto-detect
  # by content so we don't hard-code a filename codex hasn't chosen yet.
  ACYCLIC_TEST="$(grep -rl -e 'acyclic' -e 'im → session → agent' -e 'im->session->agent' \
                    apps/*/test 2>/dev/null | grep -iE 'arch|acyclic|domain|substrate|decompos' \
                    | grep -v _build | head -1)"
  if [ -n "${ACYCLIC_TEST}" ]; then
    run "acyclic arch-fitness invariant (${ACYCLIC_TEST})" \
        mix test "${ACYCLIC_TEST}" --include umbrella_only
  else
    skip "acyclic arch-fitness invariant test — NOT FOUND yet (codex lands it in PR-9a; this is the TRUE completion gate, allowlist must reach 0 by PR-9c)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. BEHAVIORAL companion — deterministic im→session→agent transport set
# ---------------------------------------------------------------------------
if [ "$MODE" != "--structural-only" ]; then
  say "BEHAVIORAL — deterministic im→session→agent transport"

  # Each entry is a transport seam the split must preserve.
  BEHAVIORAL_TESTS=(
    "apps/ezagent_domain_instance_message/test/ezagent/behavior/receive_split_test.exs"            # agent.receive → AgentBridge, no slice mutation (A3)
    "apps/ezagent_domain_instance_message/test/e2e/category_10_scenarios_10_11_mention_routing_test.exs" # mention-gated routing + cross-session leak guard
    "apps/ezagent_core/test/e2e/scenario_17_multi_workspace_user_test.exs"                          # multi-workspace dispatch authority
    "apps/ezagent_core/test/e2e/scenario_24_destroy_cascade_test.exs"                               # destroy cascade (saga)
    "apps/ezagent_core/test/e2e/scenario_34_sender_locked_relay_test.exs"                           # sender-locked relay (multi-agent chain through session)
    "apps/ezagent_plugin_cc/test/e2e/scenario_33_full_star_test.exs"                                # orchestrator → session → cc/codex/curl flavors
    "apps/ezagent_core/test/invariants/cross_workspace_isolation_test.exs"                          # workspace isolation at the cap chokepoint
  )

  run "deterministic behavioral E2E set (${#BEHAVIORAL_TESTS[@]} files)" \
      mix test "${BEHAVIORAL_TESTS[@]}" --include umbrella_only
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
say "VERDICT"
printf '%s\n' "${RESULTS[@]}"
if [ "$FAILED" -eq 0 ]; then
  printf '\n\033[32m基座化 GATE: PASS\033[0m  (structural fitness + behavioral transport both green)\n'
  printf 'Note: until the acyclic arch-fitness invariant test exists at allowlist=0 (PR-9c),\n'
  printf '      the split is FUNCTIONALLY intact but not yet STRUCTURALLY complete.\n'
  exit 0
else
  printf '\n\033[31m基座化 GATE: FAIL\033[0m  — see FAIL lines above. Do NOT treat the split as on-track.\n'
  exit 1
fi
