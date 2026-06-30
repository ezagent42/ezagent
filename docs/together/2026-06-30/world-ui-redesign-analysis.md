# World UI Redesign Analysis

Date: 2026-06-30

Companion prototype: [world-ui-redesign-prototype.html](./world-ui-redesign-prototype.html)

This document records the design discussion and implementation inventory behind the
World UI redesign prototype. The prototype is intentionally static HTML. It does not
change production UI code.

## Background

The current World UI already contains most of the product surface, but the overall
shape does not read as chat software. ezagent's primary operator workflow starts
from a session: read messages, invite or inspect members, route work to agents, and
move between active conversations. The redesign therefore treats Chat as the default
workspace and moves administration, plugin configuration, and identity management
behind clearer secondary destinations.

The session detail page is the strongest existing visual and interaction reference.
The redesign keeps that pattern as the core Chat layout:

- left: session list and filters
- center: main conversation timeline and composer
- right: session drawer with members, invite, routing, tools, and metadata

## Implementation Areas Reviewed

The prototype is based on the current World UI routes and React components rather
than an abstract sitemap. The reviewed surfaces include:

- `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`
- `apps/ezagent_plugin_world/assets/src/main.tsx`
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- `apps/ezagent_plugin_world/assets/src/components/Admin.tsx`
- `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`
- agent creation and identity detail flows under `/identities`
- workspace, plugin, admin, profile, and session routes currently exposed by World

## Proposed Top-Level IA

The redesigned top-level navigation is:

- Chat
- Agents
- Manage

Search or command palette controls were removed from the header in the prototype.
They are not necessary for the first redesign pass and made the app shell feel less
focused.

Workspace switching remains global in the top app shell. It is not a Settings page,
because the active workspace scopes sessions, agents, templates, plugins, routing,
and admin visibility.

The user avatar menu owns personal account surfaces:

- Profile
- theme or appearance controls
- logout or account actions

This keeps Manage focused on shared workspace and system operations instead of
mixing personal account state with admin configuration.

## Chat

Chat is the primary product surface. It should map to the existing session routes:

- `/sessions`
- `/?session=...`
- session detail state inside the existing World UI shell

The main Chat view in the prototype deliberately follows the current session detail
style. The center region is the conversation timeline and composer. The right drawer
keeps the operational session context visible:

- session metadata
- members
- invite entry points
- routing rules
- attached tools
- external mirror status
- terminal or agent-related affordances when available

This solves the original mismatch: the first screen now behaves like a chat product,
while still exposing the multi-agent controls that make ezagent different from a
generic messenger.

## Agents

Agents becomes the place for identities that can participate in sessions. It covers:

- `/identities`
- `/identities/users`
- `/identities/agents`
- `/identities/agents/new`
- `/identities/agents/:uri`
- `/identities/agents/:uri/config`
- `/identities/agents/:uri/api-keys`
- `/identities/agents/:uri/caps`
- `/identities/agents/:uri/extensions`
- `/identities/agents/:uri/terminal`

The Create Agent prototype was adjusted to match the actual current flow. It uses
the existing form shape rather than generic cards:

- Flavor select: `cc`, `cc-headless`, `codex`, `codex-remote`, `py`, `curl`, `native`
- Name input
- Project CWD input for code-oriented flavors
- schema-driven inputs when the selected flavor exposes config schema
- requested caps input
- PTY checkbox when supported
- generated URI preview

Agent detail uses tabs for overview, config, API keys, capabilities, extensions,
and terminal. Plugin flavor config surfaces such as Claude Code, Codex, Curl, Python,
and Native route into filtered agent lists instead of becoming separate settings
pages.

## Manage

Manage is not a generic Settings page. It is the shared operations area for
workspace, plugin, integration, admin, access, and system configuration.

Recommended Manage sections:

- Workspace
- Plugins
- Integrations
- Admin
- Access
- System

Workspace covers:

- `/workspaces`
- `/workspaces/:name`
- workspace members
- session templates
- public socialware template toggle
- routing rules

Session template creation should keep the actual current field model:

- name
- description
- public socialware app checkbox
- save template action
- saved templates table

Workspace switching itself stays in the global header. Manage can link to workspace
management, but should not hide the active-context switcher inside a settings panel.

## Plugins

Plugin configuration should follow the current `config_surface` behavior. A plugin
card is only directly configurable when it exposes a route or flavor target.

Covered plugin surfaces:

| Plugin | Current surface | Prototype handling |
| --- | --- | --- |
| Feishu | `/plugins/feishu/bindings` | binding detail panel with open id, user URI datalist, bind, unbind |
| Kanban | `/plugins/kanban` | connector credentials page for Miro and GitHub |
| Kanban board | `/plugins/kanban/:uri` | board detail with GitHub repo, Miro board, sync actions |
| Auto derive | `/plugins/auto/:kind`, `/plugins/auto/:kind/:uri` | credential cascade and source grant management |
| Claude Code / Codex / Curl / Python / Native | flavor target | navigate to filtered Agents views |
| Email / Protocol API | no config surface | shown as installed but not directly configurable |
| Knowledge Base | declared route target `/plugins/kb` | marked as a route gap |

The key correction from earlier prototypes is that plugin cards should not all open
the same generic settings panel. Some route to detailed configuration, some route to
agent filters, and some have no direct configuration surface.

## Admin

Admin is a section inside Manage, with its own subnav. The prototype covers the
current implemented admin pages:

- `/admin`
- `/admin/logs`
- `/admin/registry`
- `/admin/snapshots`
- `/admin/templates`
- `/admin/caps`
- `/admin/audit/authz`
- `/admin/settings`
- `/admin/routing`
- `/admin/sessions/:id/external_mirror`

Admin Settings should stay narrow. The current implemented settings are SMTP and
test email:

- SMTP host
- port
- username
- password
- from address
- TLS
- save SMTP
- test recipient
- send test

Profile does not belong here because it is personal account state. Workspace
switching also does not belong here because it is global context.

The external mirror route is session-level configuration. It should be reachable from
the Chat session drawer and from Admin Routing, but it should not be presented as a
generic global plugin setting.

## Functional Coverage Checklist

The updated prototype now covers the major World UI functions discussed during the
session:

- chat-first home screen
- session list, message timeline, composer, and session drawer
- invite and member inspection concepts
- global workspace switcher
- user menu with Profile
- Agents list, users list, agent detail, and create agent form
- agent config, API keys, capabilities, extensions, and terminal destinations
- workspace detail, members, session templates, socialware toggle, routing rules
- plugin list and per-plugin click behavior
- Feishu binding form
- Kanban connector config and board detail config
- Auto derive credential cascade
- Admin dashboard and admin subroutes
- SMTP settings
- authz audit and capability catalog
- routing and external mirror configuration

## Known Gaps

The Knowledge Base plugin declares `config_surface: %{kind: :route, path: "/plugins/kb"}`,
but the current World route/navigation implementation does not appear to handle
`/plugins/kb`. The prototype marks this as a product gap instead of inventing a fake
configuration page.

This PR contains design artifacts only. Production implementation still needs a
separate change set for React/Phoenix UI code.

## Verification

Prototype checks already run:

- interactive prototype control and panel reachability check passed:
  `controls: 33`, `panels: 33`, `missing: []`, `unreachable: []`
- HTML tag stack check passed with `depth: 0`, `errors: []`
- stale labels from earlier prototype iterations were checked and absent
- `git diff --cached --check` passed before the initial prototype commit

`mix precommit` was attempted after the prototype work. Compilation completed, but
the command could not finish because the local PostgreSQL service at
`127.0.0.1:55432` refused connections while creating the test database. This is an
environment failure, not a prototype validation failure.
