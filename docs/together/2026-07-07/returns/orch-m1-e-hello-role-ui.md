# orch-m1-e hello role UI return

Status: implemented.

Scope:
- Default `Ezagent.Socialware.Demo.Hello.manifest_attrs/0` now emits the rev4 declarative `viewer -> responser -> builder` hello shape.
- Added `from_role` matcher option and role receiver manual entry in the session routing form.
- World routing form parses `role:<name>` receivers into tagged `Ezagent.Routing.Receiver.role/1` values.
- Added a session behavior e2e covering `viewer -> responser -> builder`, trace, hop drop, and internal relay exclusion from `chat_visible_recent/2`.

Evidence:
- `mix test apps/ezagent_domain_session/test/ezagent/socialware/demo_hello_test.exs`
- `mix test apps/ezagent_domain_session/test/ezagent/behavior/chat_test.exs:308`
- `mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/routing/routing_view_test.exs`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`
