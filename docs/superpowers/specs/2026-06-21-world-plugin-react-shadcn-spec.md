# `world` plugin — React/shadcn ezagent app over a LiveView SSR shell — SPEC

> Status: SPEC (for codex self-driven development on the `world` branch).
> Supersedes the islands framing in `2026-06-19-frontend-islands-architecture-design.md`
> and the DRAFT `2026-06-20-frontend-islands-impl-spec-DRAFT.md`. Decisions below were
> 拍板'd with Allen 2026-06-20/06-21 (grill-with-doc).

## 1. Goal

Build a **new plugin `world`** — the next-generation ezagent app — whose **visible UI is 100%
React + shadcn/ui**, mounted into a **LiveView page that acts purely as the SSR/comms shell**
(server-authoritative content + dispatch transport; **no Node runtime tier**). The app's
**layout is runtime-arrangeable data** owned by a layout-manager and gated by a cap; its
**components are build-time React code** that hot-reload in dev.

The current `ezagent_plugin_liveview` (25 HEEx LiveViews) is **NOT modified in place** — `world`
is built fresh and will eventually replace it. All work lands on the **`world` branch**.

## 2. Completion gate (verbatim, Allen 2026-06-21) — the acceptance criteria

1. Produce a new plugin named **`world`** = the new ezagent app, served at **`world.ezagent.chat`**.
2. The new plugin contains a **complete component set matching the current `ezagent_plugin_liveview`**, built on **React + shadcn/ui**.
3. `world` supports **users dynamically arranging layout**; layout is **stored in the ezagent home directory**; layout belongs to a **layout manager**; the default **`world.layout.manage` cap is granted to the workspace owner**.
4. Adding a new component **writes into `world`'s code directory**; in **dev, hot-reload** shows the new component and layout.
5. Use **agent-browser screenshots** to confirm the implementation is complete.
6. codex **fully self-drives** (no waiting on confirmation), **submits a PR per step**, and **merges all output to the `world` branch**.
7. After completion, Claude **switches to the `world` branch** and reviews the implementation.

## 3. Locked architecture decisions (do NOT re-open)

| # | Decision | Rationale |
|---|---|---|
| D1 | **LiveView = SSR shell + comms/dispatch only.** LV renders the page shell + the initial data (layout + Surface tree) into HTML; it does NOT render the app's visible components. | Keeps the server authoritative, agent in the loop, auth-for-free (cookie→cap). |
| D2 | **React (shadcn/ui) owns 100% of visible rendering**, client-side. | socialware/loom (heavy real-time interaction + future collaborative editing) is ezagent's core; React's ecosystem (Yjs/Liveblocks, shadcn/Radix) is where LV is genuinely immature. |
| D3 | **NO Node/Bun runtime tier in the PRODUCTION serving path.** No React-HTML SSR. "SSR" = LV server-rendering the shell + initial data; React hydrates-from-data client-side. **Dev-time Vite (Node) for HMR is expected and required by gate #4**; prod ships pre-built static assets to `priv/static` — no Node in the running prod node. | live_react/live_vue/live_svelte SSR all require a prod Node sidecar (`NodeJS.Supervisor`, 512MiB+); rejected. Bussey-style client-only mount is the model. |
| D4 | **The ezagent app IS a socialware** — a **View over the system workspace** (its members/agents = its organization), runtime-adjustable like a loom page. | Unifies admin + loom under one model; dissolves the build-time/runtime "provenance" split. |
| D5 | **Component = build-time code; Layout = runtime data.** Adding a *component* = a React/shadcn code file (hot-reload). Arranging a *layout* = runtime data (which components, where), persisted + cap-gated + user-editable. | Resolves "runtime-adjustable UI" vs "no runtime JS loading": you don't load components at runtime (code), you arrange layouts at runtime (data). |
| D6 | **Reuse + generalize the socialware substrate**: `Ezagent.Behavior.Surface` (versioned UI tree) + `Ezagent.UI.SessionView` registry, generalized from **session-scoped → any Kind URI** so the app can be a workspace-level View. | Don't invent a parallel surface concept; honor [[project_socialware_view_reuse]]. |
| D7 | **The LV↔React bridge = a `phx-hook` + `phx-update="ignore"`** (the Bussey / existing-PTY pattern). Props/state in via server `push_event`/`handleEvent` (+ initial data attribute); events out via `pushEventTo` → `handle_event` → `Ezagent.Router`/`Invocation.dispatch`. | Already proven in-repo (`pty_terminal.js`); zero Node; React owns its subtree. |
| D8 | **Build = Vite for the `world` plugin** (React + shadcn/ui + HMR), **SSR off** (client-only). Vite is a **build/dev-time** Node dependency (not a prod runtime tier — see D3). The existing esbuild+daisyUI customer pipeline is untouched. | shadcn/ui tooling + hot-reload (gate #4) are Vite-native; isolating it to `world` avoids disturbing the current pipeline. |
| D10 | **Reuse the EXISTING LV dispatch convention** for parity: build `%Ezagent.Invocation{}` and call `Invocation.dispatch/1` with `ctx: %{caller, caps, reply}` (NOT `%Cmd{}`/`Router.dispatch/1` — the `Cmd` migration is incomplete and no current LV uses it). Caps come from the `:current_caps` assign set by `live_auth.ex`. | Every existing LV (`entity_caps_live`, `terminal_live`) uses this; match it so ported screens behave identically. |
| D11 | **v1 layout store is the `world` plugin's OWN `LayoutManager`** (file under EZAGENT_HOME), NOT the session `Ezagent.Behavior.Surface`. The "ezagent app as a socialware View" (reuse/generalize `SessionView`/`Surface`) is the north-star framing but is **descoped from v1** to avoid the session→Kind generalization risk. | Keeps v1 self-drivable; world doesn't need to register in the session View registry to ship. |
| D9 | **LV-per-route stays** as the mount point; **reject SPA client-side routing.** | The cookie→cap auth bridge + per-action `handle_event` parity depend on LV-per-route holding the session (same reason the design rejected `/api/v1`). |

## 4. The two layers (D5) — precise

### 4.1 Component layer (build-time code)
- A **component registry** in the `world` plugin's JS source: a map `component_type (string) → React component`. Each entry is a shadcn-based React component (e.g. `"sessions_table"`, `"cap_grid"`, `"agent_form"`, `"pty_terminal"`).
- **Adding a component** (gate #4) = author a new `.tsx` under `world`'s component dir + register it in the registry. In **dev (Vite HMR)** the new component appears without a full reload.
- The complete set (gate #2) covers every current LV screen — see §7 inventory.

### 4.2 Layout layer (runtime data)
- A **layout** is a JSON document describing an arrangement of registered component-types + their props/data-bindings + grid/placement. (It references component *types* by string; it never ships code.) Server-side validation rejects unknown component-types (fail-closed).
- **Storage**: `$EZAGENT_HOME/<profile>/world/layouts/<scope>.json` via `Ezagent.Home.path("world/layouts/<scope>.json")` (`Home.path/1` already accepts a binary path). The `LayoutManager` `File.mkdir_p!`s `world/layouts` lazily on first write — do NOT rely on the atom `skeleton_dirs` list (it only creates single-segment dirs). One layout per scope (default scope = the workspace the app View is bound to).
- **Layout manager**: a server-side module `Ezagent.World.LayoutManager` (NOT the session `Behavior.Surface` — D11) that reads/writes layout JSON, validated against the registered component-type set.

#### Authorization — the `:manage` layout cap (resolves review B1/B2)
- **Cap shape (B2)**: caps in ezagent are a Behavior + atom action, NOT a dotted string. Declare a Behavior **`Ezagent.World.Behavior.Layout`** with `action(:manage, args: %{...}, returns: ..., caps: [:manage], modes: [:call])`, attached to the **host Kind = the Workspace Kind** (the app View is workspace-scoped). It resolves to `%Ezagent.Capability{kind: :workspace, behavior: Ezagent.World.Behavior.Layout, action: :manage, instance: <workspace URI>, workspace_uri: <workspace URI>}`. Define `data_owner/1` on the Behavior returning `:any` for the workspace (matching the existing workspace convention — workspace caps are class-wide, NOT per-entity-owned; see `behavior/workspace.ex` `data_owner(_) -> :any`).
- **Grantee (B1) — DECISION NEEDED FROM ALLEN, default specified**: the workspace domain has **no per-entity "owner"** (workspace caps are class-wide, admin-granted; only *sessions* have an owner). So "granted to the workspace owner" (gate #3) has no literal referent for `workspace://system`. **Default resolution**: grant `:manage` to the **workspace's admin entity** — for the system workspace that is `entity://system/user/admin` (the #154 genesis admin entity) — at the authorized creation chokepoint, `granted_by` = a real entity (NEVER a `system://` principal; honor #154). For non-system workspaces, grant to the entity that created/admins the workspace. **Flagged to Allen**: if he wants a true per-entity workspace-owner concept, that is a larger workspace-domain change (out of this v1).
- **Edit flow**: editing a layout dispatches `Ezagent.World.Behavior.Layout.:manage` through the chokepoint; CapBAC step 5.5 gates it on the caller's `:manage` cap. The standard cap-elimination gates (#154) must pass.
- **Dynamic arrangement** (gate #3): user edits layout in-app (React editor) → `pushEventTo("#world-root", "world:dispatch", %{action: :manage, args})` → LV `handle_event` builds `%Invocation{}` (caller + `:current_caps`) → `Invocation.dispatch/1` (cap-checked) → `LayoutManager` persists → server `push_event(socket, "world:state", %{layout: ...})` → React re-renders. Loom-like "adjust the page at runtime" over the layout-data layer.

## 5. The comms shell (D1/D3/D7) — the contract

For each `world` route, a thin LiveView:
1. On `mount`, resolves the caller (cookie→`current_entity_uri`→caps, existing `live_auth.ex`), loads the layout (LayoutManager) + initial Surface/data, and renders ONLY:
   `<div id="world-root" phx-hook="WorldRenderer" phx-update="ignore" data-layout={Jason.encode!(layout)} data-caller={...}></div>` plus the SSR shell chrome.
2. The `WorldRenderer` JS hook (`mounted()`): `createRoot(el)` → render the React app, seeding it from `data-layout` + an initial `handleEvent("world:state", ...)` push.
3. **Server → React**: LV pushes `push_event(socket, "world:state", payload)` on any state change; the hook's `handleEvent` updates React props (React diffs, no remount).
4. **React → Server**: React calls a wrapped `pushEventTo("#world-root", "world:dispatch", %{action, args})`; the LV `handle_event("world:dispatch", ...)` builds a **`%Ezagent.Invocation{}`** with `ctx: %{caller: current_entity_uri, caps: current_caps, reply: ...}` (the existing LV convention, D10 — caps from the `:current_caps` assign set by `live_auth.ex`, NOT `%Cmd{}`/`Router.dispatch/1`) and calls **`Invocation.dispatch/1`** (CapBAC at the dispatch chokepoint step 5.5 on `ctx.caps` — unchanged, verified correct).
5. **No Node, no React-HTML SSR.** First paint = LV shell + a skeleton; React hydrates from `data-layout` + the first `world:state` push.

Real-time updates (PubSub → assigns → `push_event`) flow to React the same way LV diffs HEEx today.

## 6. Subdomain routing (gate #1) — `world.ezagent.chat`

- **New infra**: there is NO host/subdomain routing today (all 29 routes path-based, `router.ex`). Add host-based dispatch so `world.ezagent.chat` serves the `world` LV scope. Use Phoenix Router host scoping: `scope "/", EzagentPluginWorld, host: "world." do ... end` (preferred over a custom plug).
- **Concrete config edits (H1)**:
  - **Session cookie domain**: set `domain: ".ezagent.chat"` on the session cookie in `apps/ezagent_web/lib/ezagent_web/endpoint.ex:11` (`@session_options`) so the cookie→cap auth bridge works cross-subdomain. (Without it the cookie scopes to a single host and the `world.` subdomain has no session → no caps.)
  - **check_origin**: add `https://world.ezagent.chat` to the `check_origin` allowlist (`config/runtime.exs` ~line 69, or via the `EZAGENT_EXTRA_CHECK_ORIGINS` env) — the `/live` socket inherits the locked allowlist, so a `world.` WS upgrade 403s otherwise.
- **Cloudflare tunnel + DNS (DOABLE LOCALLY — creds are present)**: `world.ezagent.chat` must resolve. The Cloudflare creds ARE local: `~/.cloudflared/` has `cert.pem` + tunnel credentials, `cloudflared` is in PATH, and `~/.cloudflared/ezagent.yml` already routes `app.ezagent.chat → http://localhost:10042` (tunnel `7339e970-1a2b-4f03-84c9-a1ea50965eba`). To add `world.`: (1) add an ingress rule `world.ezagent.chat → http://localhost:10042` to that tunnel config (world is a host-scoped route on the SAME :10042 endpoint), (2) `cloudflared tunnel route dns 7339e970-1a2b-4f03-84c9-a1ea50965eba world.ezagent.chat`, (3) reload the tunnel. ⚠ This mutates **production DNS** (outward-facing) — **confirm with Allen before running** (per [[feedback_feishu_notify_before_remote_ops]]); not a blocker for dev (the agent-browser Host-resolver override below works without it).
- **Dev access for hot-reload + agent-browser (H2 — resolves the verification-loop blocker)**: remote/dev access is **Tailnet-IP based** (`100.64.0.27`, per `config/dev.exs` + [[feedback_remote_browser_ip]]), but host-scoped routing keys on `conn.host` — a request to `http://100.64.0.27:10042` sends `Host: 100.64.0.27` which a `host: "world."` scope will NOT match. So agent-browser MUST send a `world.` Host. Mechanism (pick + document, test BEFORE port work): launch headless Chrome with a host-resolution override — `--host-resolver-rules="MAP world.ezagent.chat 100.64.0.27"` (+ hit `http://world.ezagent.chat:10042`), or a `--resolve`-equivalent, so the browser sends `Host: world.ezagent.chat` while connecting to the Tailnet IP. Verify this reaches the world scope as the FIRST thing in PR-0 (the verification loop depends on it).

## 7. Complete component set (gate #2) — current LV → `world` React mapping

Every route below (from `apps/ezagent_web/lib/ezagent_web/router.ex`, `EzagentPluginLiveview` scope) gets a React+shadcn equivalent registered in the component registry. PTY stays a bespoke island (D7, like today).

| Current LV route | LiveView | `world` component-type |
|---|---|---|
| `/sessions` | AdminLive | `sessions_table` |
| `/workspaces`, `/workspaces/:name` | WorkspacesLive, WorkspaceDetailLive | `workspaces_list`, `workspace_detail` |
| `/identities`, `/identities/users` | IdentitiesLive, UsersLive | `identities`, `users_table` |
| `/identities/agents` | IdentitiesLive (NOT UsersLive — router.ex:137) | `agents_table` |
| `/identities/{users,agents}/:uri/caps` | EntityCapsLive | `entity_caps` |
| `/identities/agents/:uri/api-keys` | AgentApiKeysLive | `agent_api_keys` |
| `/identities/agents/new` | AgentNewLive | `agent_new_form` |
| `/identities/agents/:uri` | AgentDetailLive | `agent_detail` |
| `/identities/agents/:uri/extensions` | AgentExtensionsLive | `agent_extensions` |
| `/identities/agents/:uri/terminal` | TerminalLive | `pty_terminal` (bespoke island, reuse xterm hook) |
| `/plugins` | PluginsLive | `plugins` |
| `/admin` | AdminDashboardLive | `dashboard` |
| `/admin/logs` | ObservabilityLive | `observability` |
| `/admin/registry` | EntitiesLive | `entity_registry` |
| `/admin/snapshots` | SnapshotsLive | `snapshots` |
| `/admin/templates` | AdminTemplatesLive | `templates` |
| `/admin/caps` | AdminCapsLive | `caps_admin` |
| `/admin/audit/authz` | AdminAuthzAuditLive | `authz_audit` |
| `/admin/settings` | SettingsLive | `settings` |
| `/admin/routing` | RoutingLive | `routing` |
| `/admin/sessions/:id/external_mirror` | (external mirror) | `external_mirror` |
| `/profile` | ProfileLive | `profile` |
| `/plugins/auto/:kind`, `/plugins/auto/:kind/:uri` | AutoDeriveLive | `auto_derive` |
| `/plugins/feishu/bindings` | FeishuBindingsLive | `feishu_bindings` |

> Completeness note (review M2): the §7 set must match ALL `EzagentPluginLiveview.*` LV modules (25 files) — verify against `router.ex` at PR time, do not work only from this table. `/` `HomeLive` is `EzagentWeb` (first-login wizard), **out of gate-2 scope**, but `world` still needs a landing page at `world.ezagent.chat/` — build a `world` dashboard landing, don't silently skip it.

Plus the shared **shadcn primitive set** (port the 13 `ezagent_domain_ui` "shadcn-inspired HEEx" atoms — button, input, form_field, table, tabs, modal/dialog, toast, tooltip, uri_picker, command_palette, app_shell) as real shadcn React components.

## 8. Plugin structure

- New umbrella app **`apps/ezagent_plugin_world`** (`app: :ezagent_plugin_world`, `mod: {EzagentPluginWorld.Application, []}`), depending on the domains it dispatches into (session/identity/workspace/core) like `ezagent_plugin_liveview` does.
- JS source under `apps/ezagent_plugin_world/assets/` with its own **Vite** config (React + shadcn + tailwind w/ shadcn tokens), output bundled into the endpoint's static path. Keep separate from `ezagent_web/assets` (esbuild/daisyUI).
- The `world` LV scope + `host: "world."` subdomain scoping live in the `ezagent_web` router (or a `world`-owned router macro mounted by `ezagent_web`).
- **v1 does NOT generalize `Ezagent.UI.SessionView` / `Ezagent.Behavior.Surface`** (review B3 / D11): that session→Kind generalization is NOT a no-op (the `SessionView` callback contract is session-typed; `Surface.data_owner/1` matches only `session://`), and is descoped. Instead, `world` ships its own `Ezagent.World.LayoutManager` (layout store, §4.2) + its own workspace-scoped LV routes. The "ezagent app as a registered socialware View" remains the north-star but is a later phase. If a future phase reuses `SessionView`/`Surface`, it must specify the new callback signature, the workspace-Kind `data_owner` clause (returns `:any` per workspace convention), and a named session-View regression gate.

### 8.1 Docker packaging (Allen 2026-06-21 — account for this now)
The current `docker/Dockerfile.prod` builder (line 45) builds ONLY `apps/ezagent_web` assets via esbuild/tailwind (`mix assets.setup && mix assets.deploy`). The `world` plugin's **Vite build is a NEW builder step** that must be added:
- Builder stage: `cd apps/ezagent_plugin_world/assets && npm ci && npm run build` (Vite prod build, BEFORE `mix release`), digested into the release's static path so `world.ezagent.chat` serves pre-built assets. (Node is already in BOTH the builder and runtime images — for the feishu WS sidecar — so NO new image infra; only the build step.)
- Runtime config (`config/runtime.exs`, applied in-container): add `https://world.ezagent.chat` to `check_origin`; set session cookie `domain: ".ezagent.chat"`.
- Cloudflare ingress is HOST-side (tunnel runs on the host, not in the container, pointing at the container's published port) — add `world.ezagent.chat → :<port>` ingress + `tunnel route dns` there (§6); config, not a Dockerfile change.
- `docker/Dockerfile.dev` similarly needs the Vite dev-server wiring for HMR (gate #4) under dockerized dev.

## 9. Phasing (PR-per-step, gate #6) — codex self-drive order

Each step is an independently-shippable PR onto `world`. Suggested order (codex may refine):
1. **PR-0 Scaffold**: `apps/ezagent_plugin_world` app + Vite/React/shadcn/tailwind build + a `world.ezagent.chat` subdomain route serving a "hello from world" React page mounted via `WorldRenderer` phx-hook. Gate: subdomain loads a shadcn-styled React page; HMR works in dev.
2. **PR-1 Comms bridge**: the `world:state` / `world:dispatch` contract (§5) end-to-end on ONE real screen (`sessions_table`) — React renders sessions from server data, an action (e.g. open session) dispatches through `handle_event`→Router. Gate: parity with `/sessions`, CapBAC enforced.
3. **PR-2 Layout layer**: `world.layout.manage` cap (granted to workspace owner) + `LayoutManager` + `$EZAGENT_HOME/<profile>/world/layouts/*.json` + a React layout editor (arrange components). Gate: owner rearranges layout, persists, reloads to the new arrangement; non-owner is denied.
4. **PR-3..N Component set**: port the remaining §7 screens as registered components, PR per cohesive group (identities, admin/*, etc.). PTY reuses the xterm hook.
5. **PR-final Primitive parity + polish**: ensure the shadcn primitive set is complete; agent-browser screenshots of key screens (gate #5).

## 10. Verification (gate #5/#7)

- Each PR: the relevant umbrella tests green + the standard arch gates (`check_invariants`, `arch.scan`, `doc.scan`, system-principal/no-unowned/no-admin/no-wildcard) + **agent-browser headless screenshot** of the new/changed screen at `world.ezagent.chat` (per [[feedback_agent_browser_debug]] / [[feedback_open_terminal_first_when_debugging]]).
- `world.layout.manage` cap must satisfy #154 (real `granted_by`, no `system://` principal) — runs the cap-elimination gates.
- Final: Claude checks out `world` and reviews against all 7 gate criteria.

## 11. Open questions / risks for codex (flag, decide, document)

1. **Subdomain auth-cookie domain**: cookie must be `.ezagent.chat`-scoped for the cross-subdomain cookie→cap bridge; verify `check_origin`/CSRF.
2. **Vite ↔ Phoenix integration**: how the Vite bundle is served (dev: Vite dev server proxied; prod: built assets in `priv/static`). Document the chosen wiring.
3. **Layout schema**: define the JSON schema (component-type refs + placement + prop bindings) + server-side validation against the registered type set (reject unknown types — fail-closed).
4. **View/Surface generalization**: confirm session→Kind generalization keeps every existing session View green (regression gate).
5. **Real-time push volume** — **v1 DECISION**: whole-screen React fed by `push_event` pushes the **full dataset per change** for live tables (sessions, observability, authz-audit). Payload diffing / incremental updates is a LATER phase — do NOT over-build it in v1.
6. **shadcn tailwind tokens vs daisyUI**: `world` uses shadcn tokens; keep its tailwind build isolated from the customer daisyUI build.

## 12. Non-goals (v1)

- React-HTML SSR / SEO of component internals (no Node tier).
- Runtime loading of new *components* (code) — only runtime layout (data) arrangement.
- Modifying / migrating the existing `ezagent_plugin_liveview` in place (it stays until `world` reaches parity).
- Collaborative editing (Yjs) — architecture must not preclude it, but it is a later phase.
- Runtime hot-install of UI plugins into a prod node.

## 13. Cross-references

- Design: `docs/superpowers/specs/2026-06-19-frontend-islands-architecture-design.md`
- Membership/anon: `docs/superpowers/specs/2026-06-19-membership-mount-anon-model-design.md`
- Socialware substrate: `docs/superpowers/specs/2026-06-09-socialware-substrate-design.md`
- Memory: [[project_frontend_react_lv_ssr_architecture]], [[project_socialware_view_reuse]]
- Reference impls: live_react (mrdotb/live_react — SSR needs Node, rejected), live_svelte/live_vue, Bussey "React in LiveView" (the client-only phx-hook pattern adopted).
