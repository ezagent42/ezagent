# Project conventions (extracted by skill-2-gap-scan)

Generated: 2026-06-11
Inputs scanned: apps/ezagent_core/, apps/ezagent_domain_*, apps/ezagent_plugin_*, mix.exs

## Plugin structure
- Every plugin is an OTP app under apps/ezagent_plugin_<name>/
- mix.exs depends on ezagent_core (in_umbrella: true)
- Plugin contract: `use Ezagent.Plugin` in application.ex
- priv/ directory for vendored assets (read-only, OTP release packaged)

## Behavior authoring (2026-05-29 contract)
- ONLY developer surface: `use Ezagent.Lifecycle`
- State: PERSISTENT (auto-snapshotted) + transients (NEVER persisted)
- Hooks: create/activate/handle_<action>/handle_signal/activated/pre_handle/post_handle/deactivate/destroy
- Effect grammar: :set/:emit/:dispatch/:notify/:effect/:effect_returning/:saga/:terminate/:halt
- NEVER write `use Ezagent.Behavior` or `invoke/4` in plugin code

## URI conventions
- entity://<kind>/<workspace>/<name> for all entities
- session://cs/<workspace>/<name> for customer-service sessions
- session://preview/<tid>/<role>-<timestamp> for admin preview
- workspace://<name> for workspaces

## CapBAC
- 5-dimension: kind/behavior/action/instance/workspace_uri
- :any wildcard for kind/behavior/action/instance
- NEVER use PubSub.broadcast for inbound dispatch (P14)

## Testing
- ExUnit with Ecto.Adapters.SQL.Sandbox for DB tests
- Test helpers in apps/*/test/support/
- Integration tests use mix tasks (ezagent.demo.seed_*)

## ConfigStore
- DB-backed immutable config objects
- ConfigPointer: layer|workspace_uri|subject_uri|key -> config_id
- write_and_point: atomic write + pointer flip
- rollback = repoint to prior config_id
- body is :map (JSON-serializable)

## ExternalAdapter
- socialware P3-2: CustomerFeed as :pull ExternalAdapter
- adapter_id: "customer_feed"
- cursor-based join protocol
- P3-3: SocialwarePublisherRead for scoped read access

## MCP
- KB MCP: Python sidecar (kb_search_mcp.py) via uv
- Auto-injected into agent .mcp.json at provision time
- parameterized by tenant: KB_DB_PATH=<runtime>/kb/kb.db
