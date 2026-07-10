# C2 return - #1245 socialware uninstall UI browser path

## Result

**GREEN.** The previously missing browser proof for #1245 is complete on local `main`.

The full user path now works: create a session with application `socialware` -> open members panel -> installed-socialware row appears -> click uninstall and confirm -> reopen the same session -> installed-socialware row is gone.

## Evidence

- Installed state: `docs/e2e/2026-07-10/socialware-uninstall-c2/01-installed-socialware-panel.png`
- Cleared state: `docs/e2e/2026-07-10/socialware-uninstall-c2/02-uninstalled-cleared-panel.png`
- Run notes and assertions: `docs/e2e/2026-07-10/socialware-uninstall-c2/README.md`

## Data verification

- `install:socialware` resolves to `{"ref":"socialware","removed":true}`.
- Session-created routing rules remaining after uninstall: `0`.
- A fresh authenticated agent-browser session showed no uninstall row/button, ruling out a stale React-only update.

## Environment

- Local `main`: `bf5e717b29ef270982b402d46005e17c0b3655e7`
- Phoenix: `http://world.localhost:10042`
- PostgreSQL: isolated local cluster on `127.0.0.1:55432`
- Browser runner: `agent-browser 0.27.0`

## Verification

- Target regression: `MIX_ENV=test mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:641` -> `41 tests, 0 failures, 40 excluded`.
- `mix precommit` completed forced compilation and entered the full suite, but the suite is not green on this checkout:
  - two existing HomeMigration tests require a WSL `pg_dump` executable that is not installed;
  - the existing hello-manifest browser/LV test at `world_conversation_test.exs:1374` fails role materialization and reproduces when run alone.
- These failures do not touch the #1245 uninstall path; this task changes only evidence and documentation.

## Tool note

agent-browser 0.27.0 detected the real confirm dialog but could not accept it reliably across separate CLI calls. The confirm text was captured, then the same UI click was executed with `window.confirm` returning true. Final proof came from a separate clean browser session.
