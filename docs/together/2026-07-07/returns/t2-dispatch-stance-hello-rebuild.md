# T2 Dispatch Stance + Hello Rebuild Return

Date: 2026-07-07
Branch: `work/t2-dispatch-stance-hello-rebuild`
Base: `origin/main` at `df43253b21b3`

## Summary

Implemented T2 on top of T1 and M2:

- Recorded the reachability invariant in the native role dispatch stance spec: dispatch reaches any fresh materialized member flavor; chat delivery / `:receive` is adapter-flavor only.
- Locked the native no-receive behavior with a regression that proves a routed native member is matched by routing but dropped at bridge delivery instead of receiving chat.
- Exposed hello builder rebuild as a dispatchable `hello_builder.rebuild` action governed by caller capabilities, while leaving the existing `from_user?` receive gate intact for chat delivery.
- Registered the hello builder recipe with the new `:rebuild` requested cap.
- Added conformance warn-only handling for composite definitions that have human roles but no adapter-backed routing receivers.
- Updated spec §4.3 to record decision A (warn-only), with M2 now present on `origin/main`.

## Tests Added Or Updated

- `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_builder_dispatch_test.exs`
  - allowed caller with `hello_builder.rebuild` cap starts rebuild via dispatch.
  - denied caller does not start rebuild.
  - non-user chat delivery still does not trigger the legacy receive path.
- `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`
  - asserts `:rebuild` is a declared action and recipe requested cap.
- `apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs`
  - asserts native role receiver remains a bridge drop, not a delivered receive.
- `apps/ezagent_domain_session/test/ezagent/socialware/conformance_test.exs`
  - asserts composite no-adapter-receiver definitions warn under `check_with_warnings/2` and are not rejected by `check/2`.

## Verification

Local gates run in the isolated worktree:

- `mix format` PASS
- `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_builder_dispatch_test.exs apps/ezagent_domain_session/test/ezagent/socialware/conformance_test.exs apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs` PASS
  - `ezagent_domain_session`: `51 tests, 0 failures`
  - `ezagent_plugin_hello`: `10 tests, 0 failures`
- `mix precommit` PASS

Notes:

- The first precommit attempt exposed a missing worktree-local `apps/ezagent_web/assets/node_modules/xterm/css/xterm.css`; `npm ci --ignore-scripts` was run in `apps/ezagent_web/assets` to restore ignored lockfile dependencies, then full `mix precommit` passed.
- Conflicts/blockers: none.
