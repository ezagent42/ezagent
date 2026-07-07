# orch-m1-b hop budget return

Status: implemented.

Scope:
- Added persisted `Ezagent.Message.hops` with default budget `8`.
- Added SQLite and Postgres migrations for `messages.hops`.
- `Session.send` drops messages with `hops <= 0` before routing and records a trace.
- Routed re-emission decrements hop count before delivery.

Evidence:
- `mix test apps/ezagent_core/test/ezagent/message_store_chat_visible_recent_test.exs`
- `mix test apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs:283`
- Included in combined targeted run on 2026-07-07: 43 core tests and 10 domain_session selected tests, 0 failures.
