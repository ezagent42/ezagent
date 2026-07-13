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

## Original finding (2026-07-08)

The browser-authenticated run did not reach a green uninstall-click screenshot yet. The DB and backend read helper show the setup session has `install:socialware`, but the rendered DOM still reports:

- `[data-world-socialware-uninstall-panel]`: `0`
- `[data-world-socialware-uninstall-button]`: `0`

So the PR now has real screenshot evidence and a concrete follow-up: make the installed-socialware row appear in the members panel for the browser path, then click uninstall and capture the final cleared state.

## C2 follow-up (2026-07-10) - GREEN

The carried C2 DoD is complete. The full browser path now works:

1. Create a session with application `socialware`.
2. Open the members panel and verify the installed-socialware row.
3. Click uninstall and confirm the browser dialog.
4. Reopen the same session in a fresh authenticated browser session.
5. Verify that the installed-socialware row and uninstall button are gone.

### Evidence

- Installed state: `docs/e2e/2026-07-10/socialware-uninstall-c2/01-installed-socialware-panel.png`
- Cleared state: `docs/e2e/2026-07-10/socialware-uninstall-c2/02-uninstalled-cleared-panel.png`
- Browser run notes: `docs/e2e/2026-07-10/socialware-uninstall-c2/README.md`

### Data verification

- `install:socialware` resolves to `{"ref":"socialware","removed":true}`.
- Session-created routing rules remaining after uninstall: `0`.
- A fresh authenticated browser session showed no uninstall row or button, ruling out stale client-only state.

### Environment and verification

- C2 baseline: local `main` at `bf5e717b29ef270982b402d46005e17c0b3655e7`.
- C2 browser runner: `agent-browser 0.27.0` against `http://world.localhost:10042`.
- C2 used an isolated PostgreSQL verification cluster on `127.0.0.1:55432`; the normal project PostgreSQL port remains `5432`.
- Target regression: `MIX_ENV=test mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:641` -> `41 tests, 0 failures, 40 excluded`.
- `mix precommit` compiled successfully and entered the full suite, but remained blocked by unrelated existing failures: two HomeMigration tests require a WSL `pg_dump`, and the hello-manifest test at `world_conversation_test.exs:1374` fails role materialization when run alone.

### Agent-browser note

`agent-browser 0.27.0` detected the native confirm dialog but could not accept it reliably across separate CLI calls. The run captured the real confirm text, replayed the same UI click with `window.confirm` returning true, and verified the cleared state in a third clean authenticated browser session.

## Allen

For Allen: the #1245 C2 browser follow-up is now GREEN. The installed-socialware row renders, the uninstall action completes, the tombstone and zero-routing-rule state are verified, and a fresh authenticated browser session confirms the row stays cleared. Evidence is under `docs/e2e/2026-07-10/socialware-uninstall-c2/`.
