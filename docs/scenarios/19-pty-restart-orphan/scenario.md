# Scenario 19: PTY restart preserves cwd + orphan reap

**Category**: 7 — PTY interaction
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-26 (PR #385 + PR #388 verified by Allen)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- A running cc agent at `entity://agent/system/my_cc` with `cwd = /tmp/my-cc-cwd`
- Admin logged in

## Actors

- **Caller**: admin (restart trigger)
- **Target**: cc agent + its PTY-spawned `claude` process

## Steps

### Capture state

1. From iex: `pid = Process.whereis(...)` for the agent supervisor.
2. From shell: `cat $(claude_config_dir)/pids/claude.pid` — note the OS PID of the `claude` process.
3. From `/admin/agents/<uri>/terminal`, type something in `claude` to confirm cwd is `/tmp/my-cc-cwd`.

### Restart

4. From iex: `Ezagent.Kind.Runtime.dispatch(<cc_agent_uri>, :restart, %{})`.
5. The agent supervisor calls `terminate/2`; the PTY handler:
   - Sends SIGTERM to the `claude` PID (from pid-file)
   - Waits up to 5s for graceful exit
   - On timeout, sends SIGKILL
6. The supervisor relaunches the agent; the new PTY spawns a new `claude` with same `CLAUDE_CONFIG_DIR` and same `cwd`.

### Verify

7. Confirm the old OS PID (step 2) no longer exists (`ps -p <old_pid>` returns empty).
8. Confirm a new OS PID is in the pid-file.
9. Confirm the new `claude` PTY shows the same `cwd`.
10. The agent transitions `boot → ready` (skipping `first-run` because theme is persisted).

### Orphan reap

11. Deliberately leak: kill the agent supervisor without graceful terminate (`Process.exit(pid, :kill)`).
12. The orphan reaper (PR #385 + PR #388) sweeps `<claude_config_dir>/pids/*.pid` on supervisor restart + kills lingering `claude` processes via pid-file lookup (no `ps`-walk).

## Expected outcomes

- Restart preserves `cwd` + `claude_config_dir` (no theme dialog second time).
- Old OS PIDs are reaped (no zombie `claude` processes).
- Pid-files are atomic: written via `:open + write + close + rename` (no half-written pid).

## Failure modes to test

- Pid-file written but `claude` died before recording (race): orphan reaper sweeps a stale pid-file that points to a dead OS PID. PR #388 detects + cleans.
- Restart while a Feishu outbound is mid-flight: the outbound dispatch hangs on the dead PTY; should fail gracefully when the new PTY is ready.

## Cross-references

- Related PRs:
  - PR #385 — feat(cc,np): fix orphan-on-restart via post_init hook + orphan reapers
  - PR #388 — refactor(pty): pid-file discovery replaces `ps`-walk
  - PR #390 — PTY/Python phase state machine
  - PR #425 — refactor(domain_agent): detect PTY lifecycle by behavior
- Related SPECs:
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
- Tests:
  - `apps/ezagent_core/test/integration/sandbox_destroy_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — restart path

## Notes

- PR #388 replaced a fragile `ps -ef | grep claude`-based orphan walk with deterministic pid-file lookup. The lesson: process discovery via stable artifacts > string-parsing.
- The orphan reap is intentional: cc agents are long-lived, restart is common, and any leaked `claude` consumes API quota.
