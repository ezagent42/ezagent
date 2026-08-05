# Task 1 Report — Active admission PTY Terminal SessionView

## Status

DONE_WITH_CONCERNS

## Changes

- Added the required admission-bootstrap regression assertions proving the PTY
  session view is available while the provisional candidate is still absent from
  `session.members`.
- Extended `EzagentDomainUi.Pty.TerminalView.applies_to?/1` to accept either a
  joined member with a live PTY or an `:authenticating` / `:materializing`
  admission row whose parsed entity URI has a live PTY.
- Malformed admission rows, non-entity URIs, other statuses, and non-live PTYs
  safely return `false`.

## RED

Command:

```bash
mix test apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
```

Result: failed exactly at the new
`assert EzagentDomainUi.Pty.TerminalView.applies_to?(session_uri)` assertion;
the preceding `Ezagent.Domain.Pty.alive?(agent_uri)` assertion passed.

## GREEN

Commands:

```bash
mix test apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/pty/terminal_view_test.exs
```

Result: passed with zero failures (1 Codex admission test; 7 TerminalView tests).

## Commit

`1472609a8 fix(ui): expose active admission terminals`

## Self-review

- The change keeps existing joined-member behavior intact.
- Only the two explicitly allowed code/test files were committed.
- `git diff --cached --check` passed before commit.
- Touched files were formatted with `mix format`.

## Concerns

- `ezagent_domain_ui` does not declare a direct `:ezagent_domain_session`
  dependency, so compiling the new direct `AgentAdmission.list/1` call emits an
  undefined-module warning. The task explicitly restricted implementation to
  the two committed files and required this alias/call shape, so `mix.exs` was
  intentionally left unchanged. The two specified tests pass under the
  umbrella's running applications.
- Per task instruction, full `mix precommit` was not run.

## Independent Review Follow-up

### Status

DONE

### Changes

- Declared `{:ezagent_domain_session, in_umbrella: true}` in
  `ezagent_domain_ui` so `TerminalView` has an explicit compile-time dependency
  on `AgentAdmission`; the adjacent comment records why the sibling edge is
  acyclic.
- Added public `TerminalView.applies_to?/1` coverage for a live
  `:materializing` candidate and for rejected `:joined`, malformed, bad-URI,
  non-entity, and non-live candidates.

### Test-first record

The new behavior tests were added and run before changing `mix.exs`. They were
green because the preceding Task 1 implementation already contained the
admission-status and URI guards; the follow-up fix addresses the independent
review's missing dependency declaration and adds durable regression coverage.

### Verification

```bash
# from apps/ezagent_domain_ui
mix compile

# from umbrella root
mix test apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/pty/terminal_view_test.exs
```

Results: child app compile no longer reports the
`AgentAdmission.list/1 is undefined` warning. The Codex admission regression
passed (1 test, 0 failures) and TerminalView passed (9 tests, 0 failures).
The compile emitted pre-existing warnings from `ezagent_actor` and
`ezagent_domain_agent`, plus build-artifact mtime resets; none references the
changed files.

### Commit

`130e88e8e fix(ui): declare terminal admission dependency`
