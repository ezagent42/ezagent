# orch-m1-c routing trace return

Status: implemented.

Scope:
- Added persisted `Ezagent.Routing.Trace` records with `message_id`, `workspace_uri`, `rule_id`, `receivers`, `hop`, and `drop_reason`.
- Added SQLite and Postgres migrations for `routing_traces`.
- `Session.send` records matched-rule traces, `no_match`, and hop-exhausted drops.
- Operator/debug query entrypoint is `Ezagent.Routing.Trace.journey(message_id)`.

Evidence:
- `mix test apps/ezagent_core/test/ezagent/routing/trace_test.exs`
- `mix test apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs:283`
- Included in combined targeted run on 2026-07-07: 43 core tests and 10 domain_session selected tests, 0 failures.
