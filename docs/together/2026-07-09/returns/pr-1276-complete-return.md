# Return - PR 1276 complete summary

> **Task:** pr-1276-complete-return
> **Branch:** `fix/world-template-ux-1270-1273`
> **PR:** #1276
> **Dev:** codex
> **returned_at:** 2026-07-09 22:23 +0800
> **deadline_status:** updated

## What is done

- World template creation now has a current-workspace New Template entry, `/workspaces/:name/templates/new` route, route matcher, router entries, IA title, slot/manifest coverage, and patch navigation inside the World shell.
- The workspace detail route remains the template list surface, while `/templates/new` is the focused builder.
- The template builder loads installable Socialware definitions from `DefinitionRegistry`, supports selecting multiple Socialware apps, saves each selected app as an install entry with role/entity config, and saves the default `chat` + `orchestrator` installs when nothing is selected.
- Successful template save publishes/updates the `current` template tag and returns from the builder to workspace detail.
- Workspace session creation keeps the World UI pending/loading state, duplicate-submit guard, success clearing, and clearer operator-facing error mapping; the PR-local caller-caps + longer create-session deadline handoff was intentionally removed from this branch because ownership is assigned to gaga #1247.
- cc, Codex, and curl agent config schemas now show model examples/help text, including the cc model example `claude-sonnet-4-6`.
- cc agent startup no longer trusts `claude --help` text for dev-channel support. It probes actual acceptance of `--dangerously-load-development-channels server:esr-bridge --help`, blocks only on explicit unknown-flag rejection, and warn-not-blocks inconclusive probes so supported Claude builds are not falsely rejected.
- Codex local and remote agents now wait for the app-server socket to become ready, and app-server readiness errors include recent output for diagnosis.
- Session detail/conversation now exposes PTY-capable agents, enables the PTY tab/member PTY entry point, renders `PtyTerminalSurface` inline, forwards PTY input for both dedicated and inline terminal views, and explicitly allows that subcomponent in the renderer mount gate.

## Validation

- Targeted World route, navigation, slot registry, template save, workspace liveness, and conversation action tests were run across the stacked work.
- cc spawn invariant tests now cover both paths: `--help` omits the dev-channel flag but the actual flag is accepted, and explicit unknown-flag rejection remains a clear unsupported error.
- Codex sidecar/app-server tests cover readiness and recent output behavior.
- Frontend structure/navigation checks and `npm --prefix apps/ezagent_plugin_world/assets run build` were run.
- `mix world.slots.manifest` and `git diff --check` were run.
- `MIX_ENV=test mix compile` passed after the review follow-up; `mix test`, `mix test --no-start`, and `mix precommit` were attempted but are blocked locally by PostgreSQL `127.0.0.1:55432` connection refused during test DB creation.

## Merge request

This complete return summary covers the cumulative PR #1276 branch `fix/world-template-ux-1270-1273`, including the original template builder work and the later stacked fixes for session creation, agent model UX, cc/Codex startup reliability, conversation PTY support, and the review follow-up in `f1ee94f3` that removes the gaga-owned caps/deadline overlap while changing cc dev-channel detection to actual flag acceptance.
