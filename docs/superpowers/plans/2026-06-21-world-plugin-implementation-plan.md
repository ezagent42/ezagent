# `world` plugin — Implementation Plan (DRAFT for codex self-driven execution)

> **For codex (self-driving):** Implement PR-by-PR on the **`world` branch**. Each PR is independently shippable, ends with its gate green + an agent-browser screenshot, and is committed/merged to `world`. Do NOT wait for human confirmation between PRs (Allen's gate #6). REQUIRED READING before any code: the SPEC `docs/superpowers/specs/2026-06-21-world-plugin-react-shadcn-spec.md` (this plan assumes its decisions D1–D11 and §-references).

**Goal:** A new plugin `world` = the React/shadcn ezagent app at `world.ezagent.chat`, mounted in a LiveView SSR/comms shell (no prod Node tier), with build-time React components + runtime user-arrangeable layout (EZAGENT_HOME, cap-gated), at parity with `ezagent_plugin_liveview`.

**Architecture:** LV per route renders a `phx-hook="WorldRenderer" phx-update="ignore"` mount point + SSR shell; React (shadcn) renders all visible UI client-side from server-pushed `world:state`; actions go `pushEventTo → handle_event → %Invocation{} → Invocation.dispatch/1` (CapBAC at step 5.5). Layout = JSON in `$EZAGENT_HOME/<profile>/world/layouts/`, edited via the `:manage` cap.

**Tech stack:** Elixir/Phoenix LiveView (shell) · Vite + React + TypeScript + shadcn/ui + Tailwind (components, dev HMR) · existing CapBAC/Router/Invocation · agent-browser (verification).

## Global Constraints (from SPEC — every task implicitly includes these)

- **No prod Node tier** (D3): SSR off; prod serves pre-built static assets in `priv/static`. Dev Vite (Node) for HMR is fine.
- **Dispatch** (D10): `%Ezagent.Invocation{}` + `Invocation.dispatch/1`, `ctx: %{caller, caps, reply}`; caps from the `:current_caps` assign. NOT `%Cmd{}`.
- **#154**: any cap grant's `granted_by` = a real entity, never a `system://` principal. The `:manage` cap + grant must pass the cap-elimination gates (`system_principal_elimination`/`no_unowned`/`no_admin`/`no_wildcard`).
- **Don't touch `ezagent_plugin_liveview`** in place — `world` is parallel until parity.
- **Per-PR gates**: relevant umbrella tests green + `check_invariants` + `arch.scan` + `doc.scan` + cap-elimination gates + an **agent-browser screenshot** of the new/changed screen at `world.ezagent.chat` (via `--host-resolver-rules="MAP world.ezagent.chat <tailnet-ip>"`).
- **Layout schema** validated server-side, fail-closed on unknown component-types.

## Human-assist prerequisites (flag, do NOT block PR-0 dev on these)

- **DNS + Cloudflare tunnel** for `world.ezagent.chat` (prod) — Allen provisions. Dev uses the Host-resolver override, so PR-0..N proceed without it.
- **B1 grantee decision** — default in SPEC §4.2 (grant `:manage` to the workspace admin entity / `entity://system/user/admin` for system workspace). Proceed on the default unless Allen overrides.

---

## PR-0 — Scaffold + subdomain + React/shadcn/Vite + the phx-hook bridge skeleton

**Deliverable:** `world.ezagent.chat` (dev: Host-override → Tailnet IP) serves a LiveView page that mounts a shadcn-styled React "hello world" via `WorldRenderer`; Vite HMR works in dev.

- Create umbrella app `apps/ezagent_plugin_world` (`app: :ezagent_plugin_world`, `mod: {EzagentPluginWorld.Application, []}`, deps on the domains it will dispatch into + `ezagent_core`).
- Vite project under `apps/ezagent_plugin_world/assets/` — React + TS + Tailwind (shadcn token preset) + shadcn/ui init (`components.json`, `cn` util, Radix deps). Dev: Vite dev server; prod build → static path served by the endpoint.
- `WorldRenderer` JS hook: `mounted()` → `createRoot` → render `<App seedLayout={dataset.layout}/>`; wire `handleEvent("world:state", ...)` + a `pushEventTo` wrapper.
- Router: `scope "/", EzagentPluginWorld, host: "world." do live "/", WorldLive end`. `WorldLive.render/1` = the SSR shell + `<div id="world-root" phx-hook="WorldRenderer" phx-update="ignore" data-layout={...}>`.
- Config edits: session cookie `domain: ".ezagent.chat"` (`endpoint.ex`); add `https://world.ezagent.chat` to `check_origin`.
- **Gate:** agent-browser screenshot of a shadcn React page at `world.ezagent.chat`; HMR edits a component and reflects without full reload; umbrella compiles; arch/doc gates green.

## PR-1 — The comms contract end-to-end on one real screen (`sessions_table`)

**Deliverable:** `/` (or `/sessions`) in `world` renders the real session list from server data via React/shadcn; an action (open/select a session) dispatches through `handle_event → Invocation.dispatch`, CapBAC-enforced; parity with `ezagent_plugin_liveview`'s AdminLive sessions list.

- `WorldLive` (or a `SessionsLive`) `mount`: resolve caller+`:current_caps` (reuse `live_auth.ex`), load sessions, `push_event("world:state", %{component: "sessions_table", data: ...})`.
- React `sessions_table` shadcn component (Table) renders the data; row action → `pushEventTo("world:dispatch", %{action, args})`.
- `handle_event("world:dispatch", ...)` → `%Invocation{}` → `Invocation.dispatch/1`.
- **Gate:** screenshot parity with `/sessions`; a dispatch works; an unauthorized caller is denied (CapBAC); tests green.

## PR-2 — Layout layer: `:manage` cap + LayoutManager + editor

**Deliverable:** the workspace admin can rearrange the layout in-app; it persists to `$EZAGENT_HOME/<profile>/world/layouts/<scope>.json`; reload shows the new arrangement; a non-authorized caller is denied.

- `Ezagent.World.Behavior.Layout` with `action(:manage, ...)`, attached to the Workspace Kind; `data_owner/1 -> :any` (workspace convention); cap shape per SPEC §4.2.
- Grant `:manage` to the workspace admin entity at the authorized chokepoint (SPEC B1 default), `granted_by` real entity; passes #154 gates.
- `Ezagent.World.LayoutManager`: read/write layout JSON (`Home.path("world/layouts/<scope>.json")`, lazy `mkdir_p!`), validate against the registered component-type set (fail-closed).
- React layout editor (drag/arrange registered components) → `:manage` dispatch → persist → `push_event("world:state", %{layout})` → re-render.
- **Gate:** owner rearranges + persists + reload reflects; non-owner denied; cap-elimination gates green; screenshot of before/after layout.

## PR-3..N — Port the complete component set (SPEC §7), PR per cohesive group

Order suggestion (each its own PR, each with screenshot + tests):
- PR-3 identities group: `users_table`, `agents_table`, `identities`, `entity_caps`, `agent_detail`, `agent_new_form`, `agent_api_keys`, `agent_extensions`.
- PR-4 admin group: `dashboard`, `observability`, `entity_registry`, `snapshots`, `templates`, `caps_admin`, `authz_audit`, `settings`, `routing`, `external_mirror`.
- PR-5 workspaces + plugins + misc: `workspaces_list`, `workspace_detail`, `plugins`, `profile`, `auto_derive`, `feishu_bindings`.
- PR-6 PTY bespoke island: `pty_terminal` reusing the existing xterm hook pattern (SPEC D7).
- Verify against ALL `EzagentPluginLiveview.*` modules (25 files) — don't work only from the §7 table.

## PR-final — Primitive parity + polish + full verification

- Ensure the shadcn primitive set covers the `ezagent_domain_ui` atom layer.
- agent-browser screenshots of all key screens (gate #5).
- Full umbrella green; all arch/doc/cap gates green; `world` landing page works.

## Self-review (codex runs before declaring done)

- Every SPEC §2 gate criterion (1–7) demonstrably met (point to the PR + screenshot for each).
- No `system://` principal introduced (cap-elimination gates).
- `ezagent_plugin_liveview` untouched; `world` at component parity (§7 cross-check).
- Each live table uses the v1 full-payload push (no over-built diffing).

## Execution handoff

After all PRs merge to `world`: Claude checks out `world` and reviews against the 7 gate criteria (SPEC §2, §10).
