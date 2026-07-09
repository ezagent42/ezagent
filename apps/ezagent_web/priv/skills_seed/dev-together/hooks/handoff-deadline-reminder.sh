#!/usr/bin/env bash
# dev-together — handoff-deadline reminder (Claude Code `Stop` hook).
#
# Fires when the agent finishes a response. As the daily handoff deadline
# approaches (or has passed), it reminds the developer to return outstanding
# handoffs to the lead programmer, and — if a task must be deferred — to cleanly
# split the finished portion out and hand THAT off, so one stuck task never
# blocks the day's overall progress.
#
# Deadline resolution: $DEV_TOGETHER_DEADLINE  >  <conf file `deadline=`>  >  20:00
# Conf file: $DEV_TOGETHER_CONF  (default: $HOME/.claude/dev-together.conf)
# Warn window (minutes before deadline to start reminding): $DEV_TOGETHER_WARN_MIN (default 90)
#
# Non-blocking: always exits 0. Throttled to at most once per hour.
set -euo pipefail

DEADLINE="${DEV_TOGETHER_DEADLINE:-}"
if [ -z "$DEADLINE" ]; then
  CONF="${DEV_TOGETHER_CONF:-$HOME/.claude/dev-together.conf}"
  if [ -f "$CONF" ]; then
    DEADLINE="$(grep -E '^deadline=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
  fi
fi
DEADLINE="${DEADLINE:-20:00}"
WARN_MIN="${DEV_TOGETHER_WARN_MIN:-90}"

# 10# forces base-10 so 08/09 don't trip octal parsing.
now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
dl_h="${DEADLINE%%:*}"; dl_m="${DEADLINE##*:}"
dl_min=$(( 10#${dl_h:-20} * 60 + 10#${dl_m:-00} ))

# Throttle: at most once per hour.
mark="${TMPDIR:-/tmp}/dev-together-reminder.last"
if [ -f "$mark" ]; then
  last="$(cat "$mark" 2>/dev/null || echo -9999)"
  delta=$(( now_min - last ))
  if [ "$delta" -ge 0 ] && [ "$delta" -lt 60 ]; then exit 0; fi
fi

if [ "$now_min" -ge $(( dl_min - WARN_MIN )) ]; then
  echo "$now_min" > "$mark" 2>/dev/null || true
  if [ "$now_min" -ge "$dl_min" ]; then state="PASSED (${DEADLINE})"; else state="approaching (${DEADLINE})"; fi
  cat <<EOF
⏰ dev-together: handoff deadline ${state}.
- Return outstanding handoff prompts to the lead programmer now.
- If a task must be deferred: cleanly split the FINISHED portion onto its own
  branch (gates green), hand that off, and carry the rest as a scoped follow-up —
  don't let one stuck task block the day.
EOF
fi
exit 0
