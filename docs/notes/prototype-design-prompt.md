# ezagent Web Admin — Static HTML Prototype Brief

This document is a one-shot briefing for the UI designer who will produce a static HTML/CSS prototype of the **ezagent** web admin. After you ship the prototype, an engineer will translate it back into Phoenix LiveView (HEEx). This brief tells you everything you need to design accurately **without reading any source code** — every `.ex`, `.css`, or `.js` file path mentioned below is for the engineer's later reference, not yours. The vocabulary, page surfaces, component lists, and constraints in this document are exhaustive for design purposes; if a component name or primitive is described inline, that's the full list — you don't need to look it up.

Treat this document as the contract. Iterate on visuals and microcopy however you like, but please honour the page inventory in §2, the component split in §3, and the LiveView constraints in §4 — those determine whether the engineer can re-host your HTML cleanly. If anything is unclear, ask Allen directly rather than trying to dig into the repo.

---

## 1. Usage logic — what ezagent IS

ezagent is a **multi-agent orchestration platform**. Four things matter:

1. **Entity-type-agnostic.** Whether the participant is a human or an agent, they reach the system through the same surfaces — humans via the browser, agents via automation tools like agent-browser — and through the same API and the same CLI. There is no surface that is reserved for humans only or for agents only.
2. **Humans talk to agents.** A person opens the admin, types into a chat, and an LLM-backed (or scripted) agent replies.
3. **Agents talk to other agents.** An agent can `@mention` another agent in a chat room; the platform routes the message accordingly.
4. **Everything is mediated by Sessions.** A `Session` is a chat room. Anyone — human or agent — who is a member of the Session sees its messages.

Today (v1, just reached this evening) the system is a multi-user, multi-agent IM platform with PTY-in-browser support and a remote API for non-PTY agents. ezagent is the integration of all of it: an **Entity** (a person or agent that signs in with a `user://` or `agent://` URI) configures Workspaces, opens chats, observes routing, and pokes at other Entities directly when needed.

### Vocabulary every Entity sees everywhere

| Term | What it is | Example URI |
|---|---|---|
| **Entity** | Any first-class participant — human or agent — that can hold caps, join Sessions, and dispatch | `user://allen`, `agent://cc/cc-architect` |
| **User** | An Entity sub-type whose principal is a human (logs in with password) | `user://allen` |
| **Agent** | An Entity sub-type that is non-human (LLM, script, bridge). URI is typed: `agent://<type>/<name>` per PR #131 | `agent://cc/cc-architect`, `agent://curl/deepseek-coder` |
| **Session** | A chat room — has members + messages + routing. Members are URIs, regardless of Entity sub-type | `session://review-room` |
| **DM** | An implicit 1:1 Session between two Entities | `session://allen-cc-architect-dm` |
| **Workspace** | A persisted cluster config: members + session_templates + routing_rules | `workspace://research` |
| **Kind** | The type identifier for any Live thing (User, Session, Agent, Workspace) | — |
| **Behavior** | A capability surface an instance implements (e.g. `chat.send`) | — |
| **Capability (cap)** | A signed grant letting an Entity invoke `kind.behavior` on an instance | `chat.send@session://oncall` |
| **RoutingRegistry** | Global table of rules: matcher → receivers | — |
| **Template Class** | A spawnable Kind blueprint registered by a plugin (e.g. `cc.agent`) | — |

### Agent flavors today

Every Entity should be recognisable at a glance — give each Kind / agent type a distinct icon/colour:

| Template Class | Behaviour | Notes for the designer |
|---|---|---|
| `cc.agent` (`mode: local-pty`) | Spawns a real **Claude Code TUI** inside a PTY on the server | The local-pty mode is the **only one with an xterm.js view** — Entities of any sub-type love seeing the TUI |
| `cc.agent` (`mode: remote-channel`) | Token-mints a bridge for an external Claude Code process to join via `/cc_socket` | Replaces the old `cc.channel_instance` split; surface it as another mode of the same `cc.agent` Template (PR-D2, 2026-05-19). Rarely the focal row; usually surfaced as a child of a local-pty row when both exist for one agent |
| `curl.agent` | Posts messages to a remote HTTP completion API (DeepSeek, OpenAI, etc.) | Needs an API key from the caller Entity's KeyVault. URI shape: `agent://curl/<name>` |
| `feishu.chat_binding` | Binds a Feishu (Lark) group/DM to a local Session | Bidirectional bridge; both sides see all messages |
| `echo` | Test fixture that echoes back | Use to teach a new Entity the system without spending tokens |

### Two modes the main interaction window must support

This is the key visual differentiator from a generic Slack-clone:

- **Chat mode** — the Slack/Discord/Lark experience: scrolling message stream, compose box, member roster on the right. Works for every agent flavour.
- **PTY mode** — when the agent is a `cc.agent` in `local-pty` mode, the viewer can drop directly into an **xterm.js view of the live Claude Code TUI**. They see the same TUI the CC process draws to its terminal — full colours, cursor blinking, scroll back. Keystrokes flow back to the PTY.

The design must let any viewer **toggle** between Chat and PTY for the same agent, or place them **side-by-side**. A tab strip inside the main pane, a split-pane toggle in the header, or a slide-over drawer are all fine — pick what reads cleanly. The split-pane option is particularly nice because a human can drive the TUI directly with the keyboard while watching the room-facing chat conversation simultaneously.

### How a session actually unfolds (a day in the life)

The viewer below is `user://allen`, but the flow is identical when the actor is an agent driving the same surfaces via agent-browser plus the `/api/v1` endpoint.

1. Lands on `/login`, signs in as `user://allen` (or, for an agent: POSTs `/login` with `agent://curl/myself` + secret).
2. Arrives at `/admin`. Left sidebar shows the Entity's Sessions (rooms it is a member of) and a few "Floating agents" (agents spun up but not yet assigned to any room).
3. Picks `session://review-room`. Main pane shows the chat stream; right pane shows members (any mix of humans and agents — they live in the same `members` map).
4. Types `@agent://cc/cc-architect please look at PR #42`. Send. The mention routes to that agent via the RoutingRegistry, the `cc.agent` reads the message, posts a reply back into the Session. The exact same path fires when an agent in the room `@mentions` another agent — Routing has no human/agent special case.
5. Allen notices the reply is sluggish, opens the agent's DM directly, toggles to PTY mode, sees the live TUI mid-reply. Watches it work, sends a clarifying keystroke directly into the TUI.
6. Goes to `/admin/workspaces/research`, adds a new `curl.agent` Template using the auto-derived form, then bounces back to chat where the new agent has joined.
7. Drops by `/admin/routing` to add a `from` rule that copies everything `user://billing` says into `session://oncall`. The same rule could equally read `agent://feishu/customer-bot` as its `from` argument — Routing matchers compare URI to URI without caring which scheme is on which side.

The prototype should make every step of that flow feel inevitable for both human and agent actors.

---

## 2. Page routing — endpoints + transitions

The Phoenix router lives at `apps/ezagent_web/lib/ezagent_web/router.ex`. Here is the full route inventory the prototype must mirror, with one-line summaries of what happens on each page.

### Auth (controller-rendered, no LiveView)

| Route | Method | What happens |
|---|---|---|
| `/` | GET | `HomeLive` — small landing page; redirect logged-in users to `/admin` |
| `/login` | GET | Login form (URI + password) |
| `/login` | POST | Authenticate + redirect to `/admin` |
| `/logout` | DELETE / POST | Clear session, back to `/login` |

### Admin core (all live behind `:require_user`)

| Route | LiveView | Purpose |
|---|---|---|
| `/admin` | `AdminLive` | **Main hub**: per-session chat — sessions sidebar, chat window, member panel, debug panel |
| `/admin/workspaces` | `WorkspacesLive` | List + create Workspaces |
| `/admin/workspaces/:name` | `WorkspaceDetailLive` | Edit a Workspace: members, session templates (with Template Class picker + auto-derived form), routing rules (read-only here) |
| `/admin/routing` | `RoutingLive` | Global RoutingRegistry editor — tabs for MentionRouting / SessionRouting tables, Form-mode and JSON-mode rule editors |
| `/admin/users` | `UsersLive` | List + create users, set passwords |
| `/admin/users/:uri/caps` | `UserCapsLive` | Per-user capability grants |
| `/admin/users/:uri/api-keys` | `UserApiKeysLive` | Per-user API key vault (for curl-agent and friends) |
| `/admin/snapshots` | `SnapshotsLive` | Observe persisted `kind_snapshots` rows — list, dump-to-JSON modal, per-row clear |
| `/admin/agents` | `AgentsLive` | List live PTY-managed agents (currently only `cc.pty`) |
| `/admin/agents/:uri` | `AgentDetailLive` | Per-agent status: os_pid, cwd, recent PTY output, restart button |
| `/admin/agents/:uri/terminal` | `PtyTerminalLive` | xterm.js terminal for that PTY agent |
| `/admin/auto/:kind` | `AutoDeriveLive` | **Auto-generated list** for any registered Kind |
| `/admin/auto/:kind/:uri` | `AutoDeriveLive` | **Auto-generated detail** for any registered Kind instance |
| `/admin/feishu/bindings` | `FeishuBindingsLive` | Manage Feishu open_id ↔ local user bindings |

### API / Dev (not designer-facing)

| Route | Purpose |
|---|---|
| `/_health` | JSON liveness probe |
| `/api/cc-events` | POST endpoint for CC hook error reports |
| `/api/feishu/webhook` | Feishu webhook receiver |
| `/api/v1`, `/api/v1/:kind/:action` | Auto-derived REST API — the entity-agnostic dispatch surface; any caller (LV-driven human, agent-browser-driven agent, CLI) can invoke any `kind.behavior.action` with a bearer token |
| `/dev/dashboard` | LiveDashboard (dev only) |

You do not need to design the API or dev routes. The prototype only needs HTML for the rows in the **Auth** and **Admin core** tables.

### Transitions to design for

- **Login → `/admin`** on successful auth.
- **`/admin` ⇄ every other admin page** via left sidebar.
- **Sessions sidebar → switch active Session** inside `/admin` (no navigation; LV swaps the message stream + members).
- **Agent row → `/admin/agents/:uri`** (status) → **`/admin/agents/:uri/terminal`** (xterm).
- **Workspaces list → Workspace detail → add session template → return to `/admin` and see the spawned Session appear in the sidebar.**

### Navigation model — please replace the current top-nav

The current LV ships a thin top-nav of 5 horizontal anchor links above the AdminLive layout. That worked for v1 but does not scale. Please design a proper **left sidebar shell**:

- **Logo + product wordmark** at the top.
- **Logged-in Entity pill** (avatar, current URI — `user://allen` or `agent://curl/myself`, sign-out) at the top right or bottom-of-sidebar. The pill must accept either Entity sub-type — agents that drive the admin via agent-browser see the same affordance.
- **Primary nav sections** (collapsible groups):
  - **Chat** — list of the user's Sessions + DMs (this is the "live" working surface).
  - **Workspaces** — link to list, expand to show recent workspaces.
  - **Agents** — link to list, expand to show running agents (with status dot).
  - **Users** — admin only.
  - **Routing** — admin only.
  - **Observability** — Snapshots, Audit log, CC Bridges.
  - **Integrations** — Feishu Bindings, future channels.
- The main pane swaps to whichever route is active; the sidebar stays mounted.

This means most LV pages will render *into* the same shell. The shell itself should be a static HTML partial the engineer can lift into a Phoenix layout.

---

## 3. Component inventory

The current LiveView modules live in `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/`. Below is every visual surface, what it currently is, and what to call it in the prototype.

### Top-level LiveView pages

| Current LV file | Current purpose | Prototype component name | Reusable? |
|---|---|---|---|
| `admin_live.ex` | 3-column layout: sessions sidebar + chat window + member panel + debug panel below | `<ChatHubPage>` — composes `<SessionList>`, `<ChatStream>`, `<MemberRoster>`, `<DebugDrawer>` | Page-specific |
| `workspaces_live.ex` | List Workspaces + create form | `<WorkspacesPage>` | Page-specific |
| `workspace_detail_live.ex` | Members table + session-templates table + Template Class picker + auto-form + read-only routing rules | `<WorkspaceDetailPage>` — composes `<MemberTable>`, `<TemplateTable>`, `<TemplateClassPicker>`, `<AutoForm>`, `<RuleViewer>` | Page-specific |
| `routing_live.ex` | Tab strip (MentionRouting / SessionRouting) + rule table + add-rule form with form-mode/JSON-mode toggle | `<RoutingPage>` — composes `<TableTabs>`, `<RuleTable>`, `<RuleEditor>` (with Form/JSON toggle) | Page-specific |
| `users_live.ex` | Users table with inline password setter + create-user form | `<UsersPage>` | Page-specific |
| `user_caps_live.ex` | List + grant + revoke capabilities for a user | `<UserCapsPage>` | Page-specific |
| `user_api_keys_live.ex` | API key vault for a user (provider + masked key + put/delete) | `<UserApiKeysPage>` — uses `<KeyVault>` | Page-specific |
| `snapshots_live.ex` | List `kind_snapshots` rows + dump modal + clear | `<SnapshotsPage>` | Page-specific |
| `agents_live.ex` | Table of live PTY agents | `<AgentsPage>` | Page-specific |
| `agent_detail_live.ex` | Per-agent status table + recent PTY output + restart | `<AgentDetailPage>` — uses `<StatusGrid>`, `<TerminalOutputBlock>` | Page-specific |
| `pty_terminal_live.ex` | Full-page xterm.js host | `<PtyTerminalPage>` — wraps `<PtyViewer>` | Page-specific |
| `auto_derive_live.ex` | Generic list/detail for any Kind | `<AutoDerivePage>` — uses `<KindInstanceTable>`, `<KindDetailCard>` | Page-specific |
| `feishu_bindings_live.ex` | List bindings + bind form + unbind | `<FeishuBindingsPage>` | Page-specific |

### Sub-components inside `admin/`

| Current LV file | Purpose | Prototype component name |
|---|---|---|
| `admin/sessions_sidebar.ex` | Sessions list + "New session" form + Floating agents | `<SessionList>` (this is part of the app shell — see below) |
| `admin/chat_window.ex` | Session header + message stream + compose form | `<ChatStream>` + `<MessageComposer>` |
| `admin/member_panel.ex` | Right-pane member table (uri / online / last_seen) | `<MemberRoster>` |
| `admin/debug_panel.ex` | CC Events table + CC Bridges table + collapsible Debug area (Echo, Manual Dispatch, Audit Log) | `<DebugDrawer>` (a collapsible panel) — internally uses `<EventTable>`, `<BridgeTable>`, `<ManualDispatchForm>`, `<AuditLogStream>` |

### Shared primitives (Allen already built some in `ezagent_domain_ui/`)

The codebase already has a small shadcn-inspired library in `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex` — currently it exposes `<.button>`, `<.card>`, `<.badge>`, `<.page_header>`, `<.stat>`. Please **extend that vocabulary** in the prototype; do not invent a parallel system. Use these names and add as needed:

| Primitive | Variants the prototype must show |
|---|---|
| `<Button>` | `default`, `primary`, `success`, `danger`, `ghost`, `outline`; sizes `sm`/`md`/`lg`; loading state (`phx-disable-with` equivalent — a spinner + dim) |
| `<Card>` | Plain; with header slot; with footer slot |
| `<Badge>` | `default`, `primary`, `success`, `warning`, `danger`, `info` |
| `<PageHeader>` | Title + subtitle + actions slot (right-aligned buttons) |
| `<Stat>` | Label + value; numeric tabular alignment; variants for success/warning/danger |
| `<StatusDot>` | Tiny circle: green=online, grey=offline, amber=connecting, red=error — used in sidebar nav and member roster |
| `<Avatar>` | For users: monogram from URI; for agents: small icon by Kind |
| `<Tabs>` | Horizontal tab strip — used in RoutingPage and the main-pane Chat/PTY toggle |
| `<Modal>` | Centered overlay with header/body/footer — Snapshot dump uses this |
| `<Toast>` | Flash messages (success / error) — bottom-right, dismiss-on-click |
| `<Table>` | Header row + body rows + optional sort affordance on column headers; zebra optional |
| `<EmptyState>` | Icon + headline + one-liner + CTA button — for empty Sessions list, empty Members, no Snapshots, etc. |
| `<FormField>` | Label + input + help text + error slot. Input types: `text`, `password` (masked, toggle reveal), `uri` (monospace + scheme validation hint), `json` (textarea, monospace), `select`, `textarea` |
| `<UriChip>` | A monospace pill rendering a URI with a copy button on hover |

### Domain-specific reusable components

These are the heart of the design system; please make them feel polished and consistent.

| Component | Where it appears | What it must do |
|---|---|---|
| `<SessionList>` | App shell left sidebar | Group by section: "Direct messages" (DMs) and "Channels" (multi-party Sessions). DMs render as `<Avatar> @other-party`; Channels render as `# session-short-name`. Selected item is highlighted. Inline "+ New" affordance at section bottom. |
| `<FloatingAgentList>` | App shell left sidebar (bottom) | Shows agents that exist in the registry but are not members of any Session yet. Click a row to add the agent to a Session via a small dropdown. |
| `<ChatStream>` | ChatHubPage main pane | Reverse-chronological message bubbles, with sender badge, timestamp, "Load older" button at top. Auto-scroll on new messages. Distinguish bubble background by sender Kind (user vs agent vs system). |
| `<MessageComposer>` | Below `<ChatStream>` | Mention dropdown — should list **every member URI of the current Session**, regardless of Entity sub-type (`user://`, `agent://`). The current LV restricts the dropdown to `agent://` URIs only; the prototype should treat that as a v1 bug and design the dropdown to also let an Entity `@mention` a human. Text input, send button. Disable + show hint when the current Session has no other members to mention. |
| `<MemberRoster>` | ChatHubPage right pane | Table of members with `<StatusDot>`, URI, last-seen. Visually distinguish Entity sub-types (human / agent / system) via avatar/icon, but the row treatment, sort order, and actions are uniform — the roster does not care about sub-type. |
| `<TemplateClassPicker>` | WorkspaceDetailPage | Horizontal button row of registered Template Classes (`cc.agent`, `curl.agent`, `feishu.chat_binding`, `echo`, …) plus a "JSON (custom)" escape hatch. Click a class → the form below adapts. For `cc.agent`, the form includes a `mode` field (`local-pty` vs `remote-channel`) — PR-D2 collapsed the previous `cc.pty` / `cc.channel_instance` split into one Template with a mode toggle. |
| `<AutoForm>` | WorkspaceDetailPage, UserCapsPage, etc. | Renders a form from a schema descriptor — field types: `text`, `path`, `uri`, `select`. This is critical: see §3a below for the JSON shape it consumes. |
| `<RuleTable>` | RoutingPage | Rows: ID + Source badge + Matcher (monospace) + Receivers (monospace, joined) + Delete/Disable/Enable button. Greyed-out row for disabled rules. |
| `<RuleEditor>` | RoutingPage | Form-mode (matcher_type dropdown + arg input + receivers field) vs JSON-mode (full matcher JSON textarea + receivers). Tab toggle between modes. Also design a **wizard mode** (see UX polish §below) that walks the operator through {matcher} → {receivers} → {preview}. |
| `<KeyVault>` | UserApiKeysPage | Provider name + masked key (`sk-...XXXX`) + "Reveal" toggle + put/delete. Add-key form with provider dropdown and masked input. |
| `<PtyViewer>` | PtyTerminalPage and as a tab inside ChatHubPage when the active agent is `cc.pty` | A black box that the engineer will mount xterm.js into via a JS hook. Size to fill its container. Show a "Connecting…" state while the WebSocket establishes. |
| `<BridgeTable>` | DebugDrawer | Lists CC bridges connected to `/cc_socket`: agent_uri, status (green dot), connected_at, client info. |
| `<EventTable>` | DebugDrawer | Hook-reported CC errors: level pill, bridge_id, type, text, timestamp. |
| `<AuditLogStream>` | DebugDrawer | Append-only table of dispatches: target, action, authz result, result, duration_us, at. Stream-update; new rows fade in at the top. |
| `<KindInstanceTable>` | AutoDerivePage list view | URI + slice-key badges + "detail →". |
| `<KindDetailCard>` | AutoDerivePage detail view | Header URI; sections for "Kind module", "Behaviors" (with action lists), and "Slices" (one collapsible block per slice, JSON pretty-printed). |
| `<SnapshotTable>` | SnapshotsPage | URI + kind_type + bytes + version + updated_at + "Dump" + "Clear" buttons. |

### 3a. `<AutoForm>` schema — the engineer's killer abstraction

This is the most important reusable component in the system. Plugin authors declare a Template Class and self-describe its form fields via the `Ezagent.UI.Form` behaviour. The UI consumes a list of field descriptors and renders them generically. The descriptor shape:

```json
[
  {
    "name": "agent_uri",
    "type": "uri",
    "label": "Agent URI",
    "required": true,
    "placeholder": "agent://cc-architect"
  },
  {
    "name": "model",
    "type": "select",
    "label": "Model",
    "required": true,
    "options": ["claude-sonnet-4-7", "claude-opus-4-7", "claude-haiku-4-7"]
  },
  {
    "name": "cwd",
    "type": "path",
    "label": "Working directory",
    "required": false,
    "placeholder": "/var/lib/ezagent/projects/research"
  },
  {
    "name": "system_prompt",
    "type": "text",
    "label": "System prompt",
    "required": false
  }
]
```

Field types are frozen at **four** (v1): `text`, `path`, `uri`, `select`. Suggested visual treatment:

- `text` — plain input.
- `path` — monospace input, slightly different border colour or a leading folder icon.
- `uri` — monospace input + a small `<UriChip>` preview as the user types, plus inline scheme validation (`agent://…`, `user://…`, etc.).
- `select` — dropdown using the `options` array.

Render each field as `<FormField label="..." required={true}>` containing the appropriate input. Required fields get an asterisk and a red focus ring on validation failure.

The same `<AutoForm>` is reused for: Workspace template-add, User cap-grant, Feishu bind, and any future Kind that registers via `ezagent_domain_ui`'s auto-derive system.

---

## 4. LiveView technical constraints the designer must know

You may come from a React/Next.js background. Phoenix LiveView is structurally different. The prototype is yours to build in whatever stack you prefer, but to ensure the engineer can re-host it cleanly, please respect the constraints below.

### 4.1 What LiveView is

- LiveView renders **HTML on the server**, then streams a stateful **WebSocket diff** to the browser. The browser holds DOM; the server holds state.
- There is no client-side router. Page navigation is either a full HTTP request *or* a `live_redirect` within a `live_session` (which keeps the WS open). All admin routes in §2 live inside one `live_session :require_user` — navigation between them is fast but each is its own LiveView module.
- The HEEx template language is LV's JSX equivalent: server-rendered HTML with `{@assigns}` interpolation, plus `:if`, `:for`, `:let`, and component composition via `<.component_name>`.

You do not need to write any HEEx — but please **avoid bake-in patterns that LV cannot replicate without heroics**:

| OK in the prototype | Problematic in LV |
|---|---|
| Plain HTML forms with named inputs (`name="user[uri]"`) | Forms that manage their own React state across re-renders |
| Buttons that fire an `onClick` handler | Buttons that mutate a client store and re-render via that |
| Tabs implemented via `?tab=routing` URL or a server-driven `aria-selected` | Tabs whose state lives only in client JS and survives navigation magically |
| Streamed-in list rows (one element appended to a `<ul>`) | Virtualized 100k-row tables — possible but expensive |
| Modals shown by a server-driven `show?` boolean | Modals stacked from a global client context |
| Animations on enter / exit driven by CSS classes that toggle on server-rendered attribute changes | Complex enter/exit animations that require knowing about both pre- and post-state in JS |

### 4.2 Components in LV

LV components come in three flavours; this maps to how the engineer will reuse your prototype components:

- **Function components** (`def my_component(assigns)`) — stateless, just templates that take attrs. Most of your `<Card>`, `<Badge>`, `<Button>` etc. will be these. Cheap and free to nest deeply.
- **Stateful child LVs** (mounted with `live_render`) — like an iframe of server state. Heavier; use sparingly. The `<PtyViewer>` may end up being one, because its lifecycle is independent of the page.
- **JS hooks** (`phx-hook="MyHook"`) — a DOM node + a JS module that mounts on connect, handles client-side behaviour, and pushes events back to the LV process. **xterm.js, code editors, charting libs, drag-and-drop, anything with rich client state** uses this.

### 4.3 Where React / Vue / Svelte fit (and where they don't)

React/Vue/Svelte components **can be embedded** — but only by wrapping them in a `phx-hook` that mounts the framework on connect. This is heavy machinery and adds a build dependency.

**Recommendation**: prefer pure HTML/CSS + light vanilla JS for everything in the prototype. Reserve a framework only for irreducibly rich widgets:

- **xterm.js** — already in use for `<PtyViewer>`. Hook lives in `apps/ezagent_web/assets/js/app.js` as `PtyTerminal`. The DOM contract is one `<div phx-hook="PtyTerminal" phx-update="ignore">`; the hook mounts the terminal, wires `term.onData(...) → pushEvent("pty_input", ...)`, and listens for `handleEvent("pty_chunk", ...)`. Mirror this pattern in your prototype: render a black `<div>` placeholder with the right sizing and label it "wired via JS hook on integration".
- **Monaco / CodeMirror** — if you want a rich JSON editor for the RoutingPage JSON-mode textarea, that's fine; flag it.
- **Anything else** — please use plain HTML.

Do **NOT** build the prototype as a SPA with client-side routing (Next.js App Router, React Router, etc.). The URL transitions must map 1:1 to the routes in §2 — each route gets its own HTML file. The engineer will rehost each as a LiveView module.

### 4.4 CSS

Use **Tailwind CSS v4**. The app's `apps/ezagent_web/assets/css/app.css` already includes `@source` directives that pull from the plugin LiveView paths *and* from `ezagent_domain_ui`, so any Tailwind class you use in the prototype HTML will be picked up automatically when the engineer translates the HTML back into HEEx in those locations.

- Use Tailwind utility classes (`px-4 py-2 text-sm`), not custom CSS, where possible.
- daisyUI is also configured (`@plugin "../vendor/daisyui"`) — feel free to use daisyUI components if they fit, but the existing primitives in `ezagent_domain_ui` are plain Tailwind, so prefer that for new components.
- The palette in the existing primitives is **zinc-neutral** (slate-grey backgrounds, soft borders, rounded-md, shadow-sm), with semantic accents (`emerald` for success, `red` for danger, `sky` for info, `amber` for warning). You can deviate, but the engineer needs to swap the palette across the whole prototype, not bolt your scheme on top of the existing one — so coordinate via the design system rather than ad-hoc styling.
- Dark mode is enabled via `data-theme="dark"`. Please design both light and dark variants of your primitives.

### 4.5 Forms

LV form contract:

- Wrapped in `<.form for={@form} phx-submit="event_name">`.
- Inputs named `name="formname[field_name]"` — that's how server-side params arrive (`%{"formname" => %{"field_name" => "value"}}`).
- `phx-change="event_name"` fires on every keystroke if you want live validation.
- Submit happens via WebSocket, not browser navigation. No `action=` attribute needed in the design (controller-rendered `/login` is the exception — that one is a real HTML form).

**For the designer**: mark form elements clearly (`<form data-lv-submit="add_rule">` or via a `<!-- LV: phx-submit="add_rule" -->` comment) so the engineer knows which events to wire. Pick stable, descriptive `name` attributes on inputs — those become the server-side params keys verbatim.

### 4.6 Live data flow

Two patterns the designer should mark in the HTML:

- **Streams (`phx-update="stream"`)** — append-only or revise-only lists where rows arrive over time. Use for: chat message stream, audit log, CC events table. Mark these with a comment so the engineer wires them as LV streams (otherwise they default to full-list re-render on every update).
- **Live child islands (`<.live_component>` / `live_render`)** — stateful sub-areas that manage their own server state. The `<PtyViewer>` will be one. The `<DebugDrawer>` could be one.

### 4.7 No client-side form state

This is liberating: you do **not** need to design Redux/Zustand/Pinia state machines for form input. What the user types lives in the LV process; on every keystroke (`phx-change`) the LV sees the new value and can render anything. The prototype's forms should just look like plain HTML forms.

### 4.8 What the prototype delivers

You can use any tech stack to *build* the prototype, but the **deliverable** must be a folder of HTML files + CSS (Tailwind preferred) + minimal vanilla JS. One HTML file per route in §2 is the simplest contract. If you want to build with a tool (Astro, Eleventy, raw HTML, even Storybook), great — just ship the rendered static output.

---

## 5. Architectural layering + component split

The backend is layered. Mirror that layering in the prototype's directory structure so the engineer's translation is mechanical.

### Backend layering (read-only context — do not propose changes)

| Layer | Apps | What lives here |
|---|---|---|
| `ezagent_core` | `apps/ezagent_core/` | Domain-agnostic infra: `Kind`, `Behavior`, `Capability`, `Routing`, `KindRegistry`, `BehaviorRegistry`, `RoutingRegistry`, `SpawnRegistry`, `Ezagent.UI.Form` (auto-form behaviour) |
| `ezagent_domain_*` | `apps/ezagent_domain_instance_message`, `_identity`, `_workspace`, `_ui`, `_python` | Bounded contexts. `_ui` is where the shadcn-like HEEx primitives (`<.button>`, `<.card>`, …) live |
| `ezagent_plugin_*` | `apps/ezagent_plugin_cc`, `_cc_channel`, `_curl_agent`, `_feishu`, `_echo`, `_liveview` | Drop-in agent integrations. Each plugin self-registers its Kind, Template Class, and (via `Ezagent.UI.Form`) its form fields. `ezagent_plugin_liveview` is itself a plugin — it owns every Live* page |
| `ezagent_web` | `apps/ezagent_web/` | Phoenix endpoint, router, auth controllers, JS hooks, CSS pipeline |

The north star (per Allen's design lineage) is **plugin isolation**: future devs add a new agent flavour by writing one plugin app, without touching `ezagent_web` or `ezagent_plugin_liveview`. The auto-derived form + auto-derived list/detail (`/admin/auto/:kind`) are the mechanisms that make this work.

### Suggested prototype directory layout

```
prototype/
├── components/
│   ├── shell/
│   │   ├── sidebar.html               (left nav with sections)
│   │   ├── top-bar.html               (page title, logged-in user, sign-out)
│   │   ├── page-frame.html            (shell wrapper that hosts a page)
│   │   └── floating-agents.html       (bottom-of-sidebar overflow list)
│   ├── chat/
│   │   ├── chat-stream.html
│   │   ├── message-bubble.html
│   │   ├── message-composer.html
│   │   ├── mention-picker.html
│   │   ├── member-roster.html
│   │   └── session-list.html
│   ├── forms/
│   │   ├── auto-form.html             (consumes the field-descriptor JSON in §3a)
│   │   ├── form-field-text.html
│   │   ├── form-field-uri.html
│   │   ├── form-field-path.html
│   │   ├── form-field-select.html
│   │   ├── form-field-password.html
│   │   └── form-field-json.html
│   ├── agent/
│   │   ├── agent-card.html
│   │   ├── status-badge.html
│   │   ├── status-dot.html
│   │   └── pty-viewer.html            (xterm.js host placeholder)
│   ├── workspace/
│   │   ├── template-class-picker.html
│   │   ├── template-card.html
│   │   └── member-table.html
│   ├── routing/
│   │   ├── rule-table.html
│   │   ├── matcher-builder.html       (form mode)
│   │   ├── matcher-json.html          (JSON mode)
│   │   └── rule-wizard.html           (proposed walk-through; see UX polish)
│   ├── primitives/
│   │   ├── button.html
│   │   ├── card.html
│   │   ├── badge.html
│   │   ├── modal.html
│   │   ├── toast.html
│   │   ├── tabs.html
│   │   ├── table.html
│   │   ├── empty-state.html
│   │   └── uri-chip.html
│   └── observability/
│       ├── audit-log-stream.html
│       ├── bridge-table.html
│       └── event-table.html
└── pages/
    ├── login.html
    ├── admin-chat.html                (the main hub, with a Session selected)
    ├── admin-chat-pty-toggle.html     (same hub, PTY mode active for current agent)
    ├── workspaces.html
    ├── workspace-detail.html
    ├── routing.html
    ├── users.html
    ├── user-caps.html
    ├── user-api-keys.html
    ├── snapshots.html
    ├── agents.html
    ├── agent-detail.html
    ├── agent-terminal.html            (full-page xterm)
    ├── auto-derive-list.html
    ├── auto-derive-detail.html
    └── feishu-bindings.html
```

When the engineer translates each `pages/*.html` back to a LiveView, the component imports map 1:1: `components/chat/chat-stream.html` becomes `EzagentPluginLiveview.Admin.ChatWindow.chat_stream/1`, etc.

---

## UX polish list — fold these in as concrete examples

Allen has explicitly called out the following:

### Login

The current `/login` form asks for a full `user://username` URI. **Fix it**:

- Accept a plain identifier (`allen`) — the server builds `user://allen` by default. The full-URI field is the advanced fallback for other Entity sub-types (e.g. `agent://curl/myself` when an automated agent signs itself in via the same endpoint).
- A toggle / advanced section that exposes the full-URI field for non-default URI schemes.
- Consider a "Continue as guest" or one-click **dev-mode admin sign-in** button — gated by a banner that says "Dev mode only; disable in production".
- After successful login, redirect to `/admin` and open the Entity's most-recent Session (or a friendly empty state if none).

### Main chat — chat vs PTY toggle

When any Entity (human or agent — both reach this view via the same `/admin` LV) opens an agent's DM (`session://allen-cc-architect-dm`), the main pane should let them choose:

- **Chat with this agent** — the implicit Session chat stream (default).
- **Open the PTY TUI directly** — full xterm view of the underlying `cc.agent` running in `local-pty` mode.

A **tab strip at the top of the main pane** ("Chat" / "Terminal") is the simplest design. A **split-pane toggle** ("Show side-by-side") is more powerful — chat on the left half, terminal on the right. Designer picks; either is acceptable.

Make this **only show up when the agent in the DM is a `cc.agent` whose `mode` is `local-pty`** — for `cc.agent[remote-channel]`, `curl.agent`, or `echo` agents, hide the terminal option.

### Sessions vs DMs visual distinction

In `<SessionList>`, group these clearly:

- **Direct messages** — header label, then rows showing the *other party's* avatar + name (not the DM's URI).
- **Channels** (multi-party Sessions) — header label, then rows showing `# session-short-name` with a member count.

The current LV shows the full session URI in monospace; replace that with friendlier rendering. Tooltip on hover shows the URI.

### Routing rule wizard

The current `/admin/routing` is a flat table + a one-shot add-rule form. New Entities get confused. Design a **rule wizard** in addition to the current form:

1. **Step 1 — When?** Pick a matcher: `mention` (any Entity URI is @-mentioned — works for both `user://` and `agent://` targets), `from` (a specific sender, again any Entity URI), `text_contains`, `text_matches`, `always`. Show a short explanation per option.
2. **Step 2 — What's it about?** Fill in the matcher's argument (the URI for `mention` / `from`, the substring for `text_contains`, the regex for `text_matches`). Inline preview of which sessions/messages would match.
3. **Step 3 — Who receives it?** Multi-select of URIs from the registry (mixing user/agent URIs freely), plus the magic token `$session_members` (rendered as "(dynamic) all members of the current session" in the UI).
4. **Step 4 — Preview & save.** Show the rule in its final form (JSON below for power users), button to save.

Keep the existing flat-form mode as a "quick add" toggle for power users.

### Capability grant UI

The current `/admin/users/:uri/caps` is a list + a free-text grant input. Design it as: pick a Kind → pick a Behavior → optionally pick an instance URI → confirm. Render granted caps as `<Badge>` chips that can be revoked by clicking the × on the chip.

### API key vault

Mask everything by default. Use the eye-icon "reveal" pattern. On "Put", show a one-time confirmation that the key has been stored, and never re-show it.

### Empty states

Every list has an empty state; please design them:

- No Sessions → "Create your first Session" CTA opens the new-session inline form.
- No Workspaces → "Create a Workspace" → workspaces page.
- No Agents → explain that agents appear when a `cc.agent` Template (or any other agent Template Class) is added to a Workspace; link to Workspaces.
- No CC Bridges → explain bridges connect when a `cc.agent` running in `remote-channel` mode (or the Python sidecar of a `local-pty` agent) joins `/cc_socket`.

### Toasts / flash messages

Currently the LV renders inline `<p style="color: red">` per page. Replace with a toast pattern (bottom-right, slide-in, auto-dismiss after 4s, dismiss on click). The engineer will wire `Phoenix.LiveView.put_flash/3` to render through your toast component.

### Sign-out

Always reachable from the shell — bottom of sidebar with the user pill.

---

## What you should NOT do

- Do **not** enumerate exhaustive HEEx examples. You don't write HEEx — the engineer does.
- Do **not** propose changes to the backend architecture. The layering in §5 is fixed; the prototype must fit it.
- Do **not** pick the colour scheme up front — show options. The existing zinc/emerald/sky/amber/red palette is a baseline, but the designer's call carries.
- Do **not** write Elixir or HEEx in the deliverable.
- Do **not** design a SPA with client-side routing — page transitions must map to the route table in §2.
- Do **not** try to brainstorm with Allen via the markdown — iterate with him separately. This file is one-shot context.

---

## Reference files the designer can ignore (engineer's notes)

The following are pointers for the LV engineer's reverse-engineering pass; the designer does not need to open them:

- Router: `apps/ezagent_web/lib/ezagent_web/router.ex`
- LiveView modules: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*.ex`
- Admin sub-components: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/*.ex`
- Auto-form behaviour: `apps/ezagent_core/lib/ezagent/ui/form.ex`
- shadcn-style primitives: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex`
- Tailwind setup: `apps/ezagent_web/assets/css/app.css`
- xterm.js hook: `apps/ezagent_web/assets/js/app.js` (search `PtyTerminal`)
- Login controller (the one non-LV page): `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`

---

## Definition of done — what the designer ships

A `prototype/` directory matching the layout in §5, with:

1. **One HTML file per route** in §2 (Auth + Admin core).
2. **A component library** in `prototype/components/` with the primitives and domain components in §3, each as a standalone HTML snippet the engineer can copy into a HEEx function component.
3. **A Tailwind config** that compiles cleanly under Tailwind v4 (or vanilla CSS the engineer can port).
4. **Both light and dark variants** demonstrated on at least the shell + the main chat page.
5. **A short index.html** listing every page + every component for visual review.

That's it. Ship that and the engineer takes over from there.
