# World UI IM Refactor Audit

Date: 2026-06-30
Branch: `feat/world-ui-im-refactor-0630`
Worktree: `/home/lenovo/workspace/ezagent/.worktrees/world-ui-im-refactor-0630`

## Browser Coverage

The browser audit used `harness.html`, which imports the built production assets from `apps/ezagent_web/priv/static/assets/world/`. Database-backed verification later ran against the host PostgreSQL service; no Docker database was started.

Screenshots captured with `agent-browser`:

- `22-chat-default.png` - Chat default `/sessions`, IM-style three-column layout.
- `23-workspace-menu.png` - workspace switcher menu with `system` and `customer-demo`.
- `24-account-menu.png` - account menu with Profile, My capabilities, Dark mode, Sign out.
- `25-conversation.png` - existing session detail conversation layout.
- `26-agents.png` - Agents directory with directory rail, detail tabs, Extensions link coverage.
- `27-agent-new.png` - Create agent form with flavor dropdown and dynamic config fields.
- `28-plugins.png` - Manage > Plugins with clickable plugin config cards and route gap state.
- `29-admin.png` - Manage > Admin with admin subnavigation.
- `30-mobile-chat.png` - mobile Chat layout; topbar no longer overlaps the page title.
- `31-mobile-agents.png` - mobile Agents layout; topbar no longer overlaps the page title.

Key browser assertions observed:

- Chat default: `data-world-chat-default=true`, `data-world-component=sessions_table`, no `layout_editor`.
- Top action: `New chat` and `New agent` render with SVG plus icons instead of fullwidth glyphs.
- Account menu: Profile and My capabilities are in the user dropdown, not Settings.
- Agent create form: flavor options include `cc`, `cc-headless`, `codex`, `codex-remote`, `py`, `curl`, `native`.
- Agent create form: dynamic fields include `model`, `effort`, `permission_mode`, `tools`, Requested caps, and With PTY.
- Agents tabs: Overview, Config, Keys, Caps, Extensions, Terminal.
- Plugins: Manage frame present, 5 plugin cards present, route gap state shown for Knowledge Base, config-surface table present.
- Admin: Manage frame present, admin subnav includes Dashboard, Observability, Registry, Snapshots, Templates, Capabilities, Authz Audit, Settings, Routing.
- Mobile: measured `overlap=false` for Chat and Agents page title vs. topbar.

## Verification

Passed:

- `mix format apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex apps/ezagent_plugin_world/lib/ezagent/world/routes.ex apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs`
- `git diff --check`
- `mix compile`
- `npm run build` from `apps/ezagent_plugin_world/assets`
- `node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs`
- `node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`
- `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_core/test/e2e`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix test apps/ezagent_core/test/integration/home_migration_test.exs`
- `mix format apps/ezagent_domain_workspace/lib/ezagent/workspace.ex apps/ezagent_plugin_py/test/np_role_test.exs`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix test apps/ezagent_plugin_py/test/np_role_test.exs apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix precommit`

Host database notes:

- Windows host service `postgresql-x64-17` is running on port `5432`; WSL can connect to `127.0.0.1:5432`.
- The earlier failure was caused by the project test default `POSTGRES_PORT=55432`, which is closed on this machine.
- Docker was not used.
- WSL does not have native `pg_dump` / `pg_restore`; temporary wrappers in `/tmp/ezagent-pgtools` forwarded those calls to `/mnt/d/PostgreSQL/bin/pg_dump.exe` and `/mnt/d/PostgreSQL/bin/pg_restore.exe` so the migration tests and full precommit could run.
