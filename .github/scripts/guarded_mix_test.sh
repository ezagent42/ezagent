#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="${GUARDED_MIX_RUNNER:-$repo_root/scripts/guarded_mix.sh}"
test_root="$(mktemp -d)"
cleanup() {
  local pid
  while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < <(jobs -pr)
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 does not contain: $2"; }
assert_not_contains() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1 unexpectedly contains: $2"; fi; }
assert_line() { grep -Fx -- "$2" "$1" >/dev/null || fail "$1 has no exact line: $2"; }

new_case() {
  case_dir="$test_root/$1"
  mkdir -p "$case_dir/bin"
  export GUARDED_TEST_ARGS="$case_dir/systemd.args"
  export GUARDED_TEST_STDERR=""
  export GUARDED_TEST_STATUS=0
  export EZAGENT_MIX_LOCK_PATH="$case_dir/mix.lock"

  for command_name in flock timeout mix pgrep; do
    ln -s "$(command -v "$command_name")" "$case_dir/bin/$command_name"
  done

  cat >"$case_dir/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$GUARDED_TEST_ARGS"
if [[ -n "${GUARDED_TEST_ENTERED:-}" ]]; then
  printf 'entered\n' >"$GUARDED_TEST_ENTERED"
  read -r _ <"$GUARDED_TEST_RELEASE"
fi
if [[ -n "${GUARDED_TEST_STDERR:-}" ]]; then
  printf '%s\n' "$GUARDED_TEST_STDERR" >&2
fi
exit "${GUARDED_TEST_STATUS:-0}"
STUB
  chmod +x "$case_dir/bin/systemd-run"
  export PATH="$case_dir/bin:$original_path"
}

original_path="$PATH"

echo "case=passes_exact_resource_envelope"
new_case passes_exact_resource_envelope
"$runner" --timeout 41 --partition contract_alpha test >"$case_dir/out" 2>"$case_dir/err"
for arg in --user --scope MemoryHigh=4G MemoryMax=5G MemorySwapMax=0 MemoryAccounting=yes OOMPolicy=kill; do
  assert_line "$GUARDED_TEST_ARGS" "$arg"
done
assert_line "$GUARDED_TEST_ARGS" "ERL_FLAGS=+S 4:4"
assert_line "$GUARDED_TEST_ARGS" "MIX_ENV=test"
assert_line "$GUARDED_TEST_ARGS" "MIX_TEST_PARTITION=contract_alpha"

echo "case=preserves_mix_argv_without_eval"
new_case preserves_mix_argv_without_eval
marker="$case_dir/eval-would-create-this"
literal="touch $marker"
"$runner" --partition argv test --only "$literal" "space value" >/dev/null 2>"$case_dir/err"
assert_line "$GUARDED_TEST_ARGS" "$literal"
assert_line "$GUARDED_TEST_ARGS" "space value"
[[ ! -e "$marker" ]] || fail "Mix argument was evaluated"

echo "case=propagates_child_exit_code"
new_case propagates_child_exit_code
export GUARDED_TEST_STATUS=42
set +e
"$runner" test >"$case_dir/out" 2>"$case_dir/err"
status=$?
set -e
[[ $status -eq 42 ]] || fail "expected exit 42, got $status"
assert_contains "$case_dir/err" "classification=command_failure exit_code=42"

echo "case=classifies_timeout_124"
new_case classifies_timeout_124
export GUARDED_TEST_STATUS=124
set +e
"$runner" test >"$case_dir/out" 2>"$case_dir/err"
status=$?
set -e
[[ $status -eq 124 ]] || fail "expected exit 124, got $status"
assert_contains "$case_dir/err" "classification=timeout exit_code=124"

echo "case=classifies_killed_137_without_claiming_proven_oom"
new_case classifies_killed_137_without_claiming_proven_oom
export GUARDED_TEST_STATUS=137
set +e
"$runner" test >"$case_dir/out" 2>"$case_dir/err"
status=$?
set -e
[[ $status -eq 137 ]] || fail "expected exit 137, got $status"
assert_contains "$case_dir/err" "classification=killed_or_possible_oom exit_code=137"
assert_not_contains "$case_dir/err" "proven_oom"

echo "case=fails_loudly_without_systemd_run"
new_case fails_loudly_without_systemd_run
rm "$case_dir/bin/systemd-run"
set +e
missing_bin="$case_dir/missing-bin"
mkdir "$missing_bin"
for command_name in bash id mktemp rm flock timeout mix pgrep; do
  ln -s "$(command -v "$command_name")" "$missing_bin/$command_name"
done
PATH="$missing_bin" "$runner" test >"$case_dir/out" 2>"$case_dir/err"
status=$?
set -e
[[ $status -eq 69 ]] || fail "expected exit 69, got $status"
assert_contains "$case_dir/err" "missing required command: systemd-run"

echo "case=preserves_stderr"
new_case preserves_stderr
export GUARDED_TEST_STDERR="child stderr sentinel"
"$runner" test >"$case_dir/out" 2>"$case_dir/err"
assert_contains "$case_dir/err" "child stderr sentinel"

echo "case=serializes_two_invocations"
new_case serializes_two_invocations
mkfifo "$case_dir/release"
mkfifo "$case_dir/second-lock-attempt"
exec 7<>"$case_dir/second-lock-attempt"
real_flock="$(readlink -f "$case_dir/bin/flock")"
rm "$case_dir/bin/flock"
cat >"$case_dir/bin/flock" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${GUARDED_TEST_LOCK_ATTEMPT:-}" ]]; then
  printf 'attempted\n' >"\$GUARDED_TEST_LOCK_ATTEMPT"
fi
exec "$real_flock" "\$@"
STUB
chmod +x "$case_dir/bin/flock"
export GUARDED_TEST_ENTERED="$case_dir/entered"
export GUARDED_TEST_RELEASE="$case_dir/release"
"$runner" --lock-wait 5 test >"$case_dir/first.out" 2>"$case_dir/first.err" &
first_pid=$!
for _ in {1..100}; do [[ -e "$case_dir/entered" ]] && break; sleep 0.01; done
[[ -e "$case_dir/entered" ]] || fail "first invocation did not enter"
rm "$case_dir/entered"
GUARDED_TEST_LOCK_ATTEMPT="$case_dir/second-lock-attempt" \
  "$runner" --lock-wait 5 test >"$case_dir/second.out" 2>"$case_dir/second.err" &
second_pid=$!
read -r -t 2 lock_attempt <&7 ||
  fail "second invocation did not attempt the contested lock"
[[ "$lock_attempt" == attempted ]] || fail "unexpected lock-attempt handshake: $lock_attempt"
[[ ! -e "$case_dir/entered" ]] || fail "second invocation entered before release"
printf 'release\n' >"$case_dir/release"
wait "$first_pid"
for _ in {1..100}; do [[ -e "$case_dir/entered" ]] && break; sleep 0.01; done
[[ -e "$case_dir/entered" ]] || fail "second invocation did not enter after release"
printf 'release\n' >"$case_dir/release"
wait "$second_pid"
exec 7>&-
unset GUARDED_TEST_ENTERED GUARDED_TEST_RELEASE

echo "case=reports_lock_timeout_75"
new_case reports_lock_timeout_75
exec 8>"$EZAGENT_MIX_LOCK_PATH"
flock 8
set +e
"$runner" --lock-wait 1 test >"$case_dir/out" 2>"$case_dir/err"
status=$?
set -e
flock -u 8
exec 8>&-
[[ $status -eq 75 ]] || fail "expected exit 75, got $status"
assert_contains "$case_dir/err" "classification=lock_timeout exit_code=75"
[[ ! -e "$GUARDED_TEST_ARGS" ]] || fail "systemd-run executed despite lock timeout"

echo "guarded Mix contract tests OK"
