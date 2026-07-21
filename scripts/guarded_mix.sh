#!/usr/bin/env bash
set -euo pipefail

timeout_seconds=900
lock_wait_seconds=60
partition="${MIX_TEST_PARTITION:-guarded_$(id -u)_$$}"
lock_path="${EZAGENT_MIX_LOCK_PATH:-/tmp/ezagent-mix.lock}"

usage() {
  echo "usage: $0 [--timeout SECONDS] [--partition NAME] [--lock-wait SECONDS] <mix args...>" >&2
}

require_positive_integer() {
  case "$2" in
    ''|*[!0-9]*|0) echo "$1 must be a positive integer" >&2; exit 64 ;;
  esac
}

while (($#)); do
  case "$1" in
    --timeout|--partition|--lock-wait)
      option="$1"
      (($# >= 2)) || { usage; exit 64; }
      value="$2"
      shift 2
      case "$option" in
        --timeout) require_positive_integer "$option" "$value"; timeout_seconds="$value" ;;
        --partition) [[ -n "$value" ]] || { echo "--partition must not be empty" >&2; exit 64; }; partition="$value" ;;
        --lock-wait) require_positive_integer "$option" "$value"; lock_wait_seconds="$value" ;;
      esac
      ;;
    --) shift; break ;;
    --*) usage; exit 64 ;;
    *) break ;;
  esac
done

(($#)) || { usage; exit 64; }
mix_args=("$@")

for required_command in flock systemd-run timeout mix; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "missing required command: $required_command" >&2
    exit 69
  fi
done

if [[ ! -x /usr/bin/time ]]; then
  echo "missing required executable: /usr/bin/time" >&2
  exit 69
fi

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
bus_address="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}"
time_file="$(mktemp)"
trap 'rm -f "$time_file"' EXIT

exec 9>"$lock_path"
if ! flock -w "$lock_wait_seconds" 9; then
  echo "classification=lock_timeout exit_code=75" >&2
  exit 75
fi

set +e
env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus_address" \
  systemd-run --user --scope \
    -p MemoryHigh=4G -p MemoryMax=5G -p MemorySwapMax=0 \
    -p MemoryAccounting=yes -p OOMPolicy=kill \
  /usr/bin/time -v -o "$time_file" \
  timeout --signal=TERM --kill-after=15 "$timeout_seconds" \
  env SHELL=/bin/bash ERL_FLAGS='+S 4:4' MIX_ENV=test \
    MIX_TEST_PARTITION="$partition" \
  mix "${mix_args[@]}"
status=$?
set -e

if [[ -s "$time_file" ]]; then
  echo "gnu_time_evidence_begin" >&2
  cat "$time_file" >&2
  echo "gnu_time_evidence_end" >&2
else
  echo "gnu_time_evidence=unavailable" >&2
fi

case "$status" in
  0) classification=success ;;
  124) classification=timeout ;;
  137) classification=killed_or_possible_oom ;;
  *) classification=command_failure ;;
esac
echo "classification=$classification exit_code=$status" >&2

if command -v pgrep >/dev/null 2>&1; then
  echo "host_matching_process_snapshot_scope=host_wide_not_invocation_owned" >&2
  echo "host_matching_process_snapshot_begin" >&2
  pgrep -af '(^|/)(mix|beam.smp)( |$)' >&2 || true
  echo "host_matching_process_snapshot_end" >&2
else
  echo "host_matching_process_snapshot=pgrep_unavailable" >&2
fi

exit "$status"
