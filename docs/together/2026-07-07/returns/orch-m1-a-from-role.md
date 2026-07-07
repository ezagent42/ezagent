# orch-m1-a from_role matcher return

Status: implemented.

Scope:
- Added `Ezagent.Routing.Matcher.from_role/1` and JSON round-trip support.
- Added pure `Matcher.match?/3` context input; `from_role` resolves only against the supplied `members` snapshot.
- Threaded `members_snapshot` from `Session.send` into `Resolver.resolve_with_ctx/4`.

Evidence:
- `mix test apps/ezagent_core/test/ezagent/routing/matcher_test.exs apps/ezagent_core/test/ezagent/routing/resolver_test.exs`
- Included in combined targeted run on 2026-07-07: 43 core tests, 0 failures.
