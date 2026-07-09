# Socialware uninstall UI agent-browser return

- PR: #1245
- Branch: `work/sw-uninstall-ui`
- Baseline commit before this return: `6f1786e1 Add socialware uninstall UI`
- Environment: local Phoenix on `http://world.localhost:10042`, PostgreSQL on `5432`, dev DB seeded with `scripts/world_e2e_seed.exs`

## What is done

- `agent-browser auth save` and `agent-browser auth login` were used for the local admin login.
- Authenticated screenshot captured at `docs/e2e/evidence/world-scenario-06-socialware-uninstall/world-s06-step01-authenticated-sessions.png`.
- Socialware setup session was created through the backend install/create primitives after the browser hello flow hit local py-agent startup timeout.
- Members panel screenshot captured at `docs/e2e/evidence/world-scenario-06-socialware-uninstall/world-s06-step02-installed-socialware-panel.png`.
- Target LV test passed locally:
  - `POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`
  - Result: `41 tests, 0 failures`

## Current finding

The browser-authenticated run did not reach a green uninstall-click screenshot yet. The DB and backend read helper show the setup session has `install:socialware`, but the rendered DOM still reports:

- `[data-world-socialware-uninstall-panel]`: `0`
- `[data-world-socialware-uninstall-button]`: `0`

So the PR now has real screenshot evidence and a concrete follow-up: make the installed-socialware row appear in the members panel for the browser path, then click uninstall and capture the final cleared state.

## Allen

For Allen: PR #1245 now has member-remove confirmation and socialware uninstall UI wired with LV coverage plus authenticated agent-browser screenshots; the final browser uninstall screenshot is still blocked because the installed-socialware panel is not rendering in the live DOM yet.