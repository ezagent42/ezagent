# Local Assets Performance Return

Date: 2026-07-07
Returned at: 2026-07-07T09:37:08Z
E2E updated at: 2026-07-07T10:02:00Z
Branch: `fix/local-assets-performance`
Base: `origin/main` at `1a5f0e93f`
Implementation commit: `8b846c27b`
PR: https://github.com/ezagent42/ezagent/pull/1222

## Summary

Implemented the critical-path UI asset localization:

- Removed Google Fonts links from the LiveView root shell, auth boundary shell, 404/500 pages, workspace-denied page, and socialware viewer shells.
- Added local `Inter` and `Space Mono` OFL font assets under `apps/ezagent_web/assets/static/fonts/`, with `assets/css/local_fonts.css` copied into `priv/static/assets/css/` during `assets.build` and `assets.deploy`.
- Kept CJK families in the CSS font stack but let them resolve to OS fonts instead of bundling large Noto CJK webfont shards into first paint.
- Removed jsdelivr xterm CSS/JS from `root.html.heex`.
- Added `xterm@5.3.0` and `xterm-addon-fit@0.8.0` to the local `ezagent_web/assets` bundle and changed `PtyTerminal` to import `Terminal`/`FitAddon` directly.
- Added `EzagentWeb.CriticalAssetTest` to prevent reintroducing Google Fonts/jsdelivr on critical shells and to assert tracked font assets exist.

## Deploy Boundary

This is code-side asset-pipeline work, not deploy-repo work. The deploy path only needs to keep running the existing Phoenix asset aliases; `assets.build` and `assets.deploy` now generate the runtime font CSS/files before Tailwind/esbuild/digest.

## Verification

Passed locally in the isolated worktree:

- `MIX_ENV=test mix test test/ezagent_web/critical_asset_test.exs` PASS (`2 tests, 0 failures`)
- `MIX_ENV=prod mix assets.deploy` PASS after `MIX_ENV=prod mix compile` generated the Phoenix colocated hook stub in a fresh prod build
- `agent-browser` network probe against `http://localhost:4010/__local_asset_probe__` PASS:
  - loaded `/assets/css/local_fonts.css`, `/assets/css/app.css`, `/assets/js/app.js`, and local `.woff2` font files from `localhost`
  - no Google Fonts or jsdelivr requests observed
- `mix test --failed` follow-up:
  - `ezagent_core` failed test from precommit reran PASS
  - `ezagent_domain_session` failed test from precommit reran PASS
- Docker deployment E2E in a fresh temporary stack PASS:
  - Built `ezagent-local-assets-e2e:latest` from this worktree with `docker/Dockerfile.dev`.
  - The image build ran `cd apps/ezagent_web && mix assets.setup && mix assets.build`; `app.js` and the world bundle were produced successfully.
  - Started an isolated compose project `ezagent-local-assets-e2e` on host port `10444`, with an internal disposable Postgres service and fresh Docker volumes. Existing dev/stable/beta/nightly containers were not touched.
  - Created `session://system/default/local-assets-e2e` through the sanctioned CLI path:
    `mix ezagent.workspace.create_session system local-assets-e2e --template default`.
  - Used `agent-browser` against `http://world.localhost:10444` to log in as the temporary admin, enter the session deep link, and send:
    `E2E local asset verification message from agent-browser`.
  - Confirmed the sent message rendered in the session UI.
- Docker E2E network/static asset evidence:
  - `agent-browser network requests` during login/session/message flow showed local requests for `/assets/css/local_fonts.css`, `/assets/css/app.css`, `/assets/js/app.js`, and `/assets/fonts/*.woff2`.
  - No `fonts.googleapis.com`, `fonts.gstatic.com`, or `cdn.jsdelivr.net` requests were observed.
  - The dev-mode Docker stack also served world React modules from the local Vite server at `localhost:5173`; these are local development requests, not third-party CDN/font requests.
  - Inside the running container, `grep -R "cdn.jsdelivr\|fonts.googleapis\|fonts.gstatic" apps/ezagent_web/priv/static/assets` produced no matches.
  - Inside the running container, `apps/ezagent_web/priv/static/assets/js/app.js` contains bundled xterm code, including `node_modules/xterm/lib/xterm.js`.
  - Font files were present under `apps/ezagent_web/priv/static/assets/fonts/`.

## Gate Status

`mix precommit` was run and did not pass end-to-end. Failures were outside this web asset change:

- `ezagent_core`: 1 timeout in `apps/ezagent_core/test/invariants/predicate_a_root_check_test.exs`; passed on `mix test --failed`.
- `ezagent_domain_session`: 1 unexpected notification in `apps/ezagent_domain_session/test/ezagent/behavior/chat_mention_failed_test.exs`; passed on `mix test --failed`.
- `ezagent_plugin_cc`: 32 persistent failures on `mix test --failed`, concentrated around:
  - `{:role_seed_collision, "orchestrator"}` in orchestrator recipe tests
  - host-login state expectation in `socialware_cc_credential_inherit_test.exs`

These failures have no file overlap with this branch's implementation.

## Notes for Lead

- PR is open for review only; do not self-merge.
- Main performance effect is removing render-blocking third-party DNS/TLS/CSS for Google Fonts and jsdelivr xterm.
- Exact Noto SC webfont bundling was intentionally skipped to avoid moving large CJK font payloads into the critical path; Chinese text still uses the existing system-font fallback chain.
