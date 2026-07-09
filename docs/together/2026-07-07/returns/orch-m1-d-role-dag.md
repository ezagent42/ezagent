# orch-m1-d role-DAG conformance return

Status: implemented.

Scope:
- Added `Ezagent.Socialware.Conformance.check_with_warnings/2`.
- Added `:routing_role_dag` assertion.
- Unpredicated role cycles reject installation.
- Predicated cycles, double delivery, and dead roles return warnings.
- Existing unknown receiver rejection remains fail-closed.

Evidence:
- `mix test apps/ezagent_domain_session/test/ezagent/socialware/conformance_test.exs`
- Included in combined targeted run on 2026-07-07: 10 selected domain_session tests, 0 failures.
