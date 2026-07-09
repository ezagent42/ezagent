# Return - PR 1276 complete summary

> **Task:** pr-1276-complete-return
> **Branch:** `fix/world-template-ux-1270-1273`
> **PR:** #1276
> **Dev:** codex
> **returned_at:** 2026-07-09 17:40 +0800
> **deadline_status:** updated

## What is done

- World template creation now has a current-workspace New Template entry, `/workspaces/:name/templates/new` route, route matcher, router entries, IA title, slot/manifest coverage, and patch navigation inside the World shell.
- The workspace detail route remains the template list surface, while `/templates/new` is the focused builder.
- The template builder loads installable Socialware definitions from `DefinitionRegistry`, supports selecting multiple Socialware apps, saves each selected app as an install entry with role/entity config, and saves the default `chat` + `orchestrator` installs when nothing is selected.
- Successful template save publishes/updates the `current` template tag and returns from the builder to workspace detail.
- Workspace session creation now preserves caller caps through dispatch, carries an explicit longer deadline, and the World UI shows pending/loading state, blocks duplicate submits, clears the form on success, and maps unsupported Claude dev-channel failures to a clearer operator-facing error.
- cc, Codex, and curl agent config schemas now show model examples/help text, including the cc model example `claude-sonnet-4-6`.
- cc agent startup now probes the installed `claude` binary for `--dangerously-load-development-channels` support and fails fast with `unsupported_claude_dev_channels` instead of timing out through session creation.
- Codex local and remote agents now wait for the app-server socket to become ready, and app-server readiness errors include recent output for diagnosis.
- Session detail/conversation now exposes PTY-capable agents, enables the PTY tab/member PTY entry point, renders `PtyTerminalSurface` inline, forwards PTY input for both dedicated and inline terminal views, and explicitly allows that subcomponent in the renderer mount gate.

## Validation

- Targeted World route, navigation, slot registry, template save, workspace liveness, and conversation action tests were run across the stacked work.
- cc spawn invariant tests cover the Claude dev-channel fail-fast path.
- Codex sidecar/app-server tests cover readiness and recent output behavior.
- Frontend structure/navigation checks and `npm --prefix apps/ezagent_plugin_world/assets run build` were run.
- `mix world.slots.manifest` and `git diff --check` were run.
- Full `mix precommit` remains dependent on the local PostgreSQL/host setup; prior failures were recorded as environment or unrelated broader-suite issues.

## Merge request

This complete return summary covers the cumulative PR #1276 branch `fix/world-template-ux-1270-1273`, including the original template builder work and the later stacked fixes for session creation, agent model UX, cc/Codex startup reliability, and conversation PTY support.
