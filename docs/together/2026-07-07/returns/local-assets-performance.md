# Local Assets Performance Return

Date: 2026-07-07
Returned at: 2026-07-07T09:37:08Z
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
