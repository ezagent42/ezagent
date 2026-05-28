# Scenario 18: PTY first-run theme dialog handling

**Category**: 7 — PTY interaction
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-26 (PR #385 + PR #390 phase state-machine merged)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- `claude` CLI installed (NOT yet authenticated — this scenario reproduces a fresh-install run)
- A fresh `claude_config_dir` (e.g. `/tmp/fresh-cc-dir-$(date +%s)`) — NOT seeded
- Admin logged in

## Actors

- **Caller**: admin
- **Target**: cc agent on a fresh config_dir
- **External system**: `claude` TUI (first-run theme picker)

## Steps

1. Create a cc.agent template with `claude_config_dir = /tmp/fresh-cc-dir-XXX`.
2. Spawn the cc agent.
3. Open `/admin/agents/<url-encoded-agent-uri>/terminal`.
4. The PTY shows the `claude` first-run theme picker: a TUI menu listing themes.
5. PR #390 state machine: agent transitions `boot → first-run`.
6. The PTY handler types `<Enter>` blindly to accept the default theme.
7. Agent transitions `first-run → ready`.
8. LV terminal shows the post-theme `claude` REPL prompt.

## Expected outcomes

- The first-run phase completes WITHOUT operator intervention.
- The agent reaches `:ready` state within ~10s (faster on warm cache).
- A telemetry event `[:ezagent, :pty, :first_run_dismissed]` is emitted.
- The `kind_snapshots` row updates to reflect `:ready` phase.
- Subsequent spawns of the SAME agent (same config_dir) skip the first-run because the theme is now persisted in `claude_config_dir/themes.json`.

## Failure modes to test

- `claude_config_dir` is read-only: `claude` fails to write theme; the dialog re-appears every spawn (no progress). PR #390 detects this as a stuck `:first-run` after timeout + transitions to `:degraded`.
- Non-default first-run prompt (e.g. consent screen on a new `claude` version): the blind `<Enter>` may NOT dismiss. PR #390 logs telemetry on persistent first-run > 30s.

## Cross-references

- Related PRs:
  - PR #385 — feat(cc,np): fix orphan-on-restart via post_init hook
  - PR #388 — refactor(pty): pid-file discovery replaces `ps`-walk
  - PR #390 — feat(pty,python,sandbox,np,lv): PTY/Python phase state-machine + LV visibility
  - PR #425 — refactor(domain_agent): detect PTY lifecycle by behavior (PR-F)
- Related SPECs:
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
- Tests:
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — covers full chain incl. first-run
  - `apps/ezagent_plugin_cc/test/integration/real_claude_hotfixes_test.exs`

## Notes

- Per `feedback_open_terminal_first_when_debugging`, the LV PTY mirror is the FIRST debug step for any cc/np/codex issue.
- The fragility of blind `<Enter>` is a known cliff — Anthropic could change the first-run flow at any version. Mitigation: PR #390's timeout + telemetry.
