# World UI IM Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the production World UI first screen and shell into the approved IM-like design: Chat / Agents / Manage, global workspace switcher, account-owned profile/theme controls, and a chat workspace with session rail, transcript, composer, and session drawer.

**Architecture:** This slice stays inside `ezagent_plugin_world` and preserves the typed slot registry. Phoenix route resolution provides Chat-facing metadata, while the React island owns shell IA and layout. Existing routes and dispatch action names remain the source of behavior; this work changes presentation and route grouping only.

**Tech Stack:** Phoenix 1.8 / LiveView route container, Elixir ExUnit route tests, React 19 + Vite + Tailwind v4 shadcn tokens, plain Node asset tests.

## Global Constraints

- Base branch is `docs/world-ui-redesign-prototype-0630`; implementation branch is `feat/world-ui-im-refactor-0630`.
- Keep the original root worktree untouched because it has unrelated session-invite changes.
- Do not edit `styles.css` broadly; use existing design tokens from `apps/ezagent_plugin_world/assets/src/styles.css`.
- Preserve typed slot registry dispatch; no unknown renderer fallback.
- Preserve all existing world paths: `/sessions`, `/identities/*`, `/workspaces*`, `/plugins*`, `/admin*`, `/profile`.
- Do not remove `CommandPalette` server support in this slice; remove only the visible header search/CmdK entry.
- Keep workspace switching in the global shell.
- Move Profile and theme controls into the account menu.
- Production code changes require a failing test first where a deterministic test seam exists.

---

## File Structure

- Create `apps/ezagent_plugin_world/assets/js/world_ia.js`: pure shell IA helpers for primary nav items, section roots, active nav grouping, and page titles.
- Create `apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`: Node tests for the new Chat / Agents / Manage grouping.
- Create `apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`: source-level UI structure test for shell/header and conversation rail markers.
- Modify `apps/ezagent_plugin_world/assets/src/main.tsx`: consume `world_ia.js`, remove visible CmdK button, move theme/profile into account menu, update breadcrumb/page title behavior.
- Modify `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`: add a session rail while preserving the current transcript center and right session drawer behavior.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`: make `/`, `/sessions`, and unknown world paths resolve with Chat titles instead of Overview/Sessions copy.
- Modify `apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`: route metadata regression tests for the Chat default.

## Task 1: Shell IA Pure Contract

**Files:**
- Create: `apps/ezagent_plugin_world/assets/js/world_ia.js`
- Test: `apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`

**Interfaces:**
- Produces `primaryNavItems(): Array<{label: string, href: string}>`.
- Produces `sectionRoot(path?: string): {label: string, href: string} | null`.
- Produces `isPrimaryNavActive(path: string | undefined, href: string): boolean`.
- Produces `pageTitleForComponent(component?: string): string`.

- [x] **Step 1: Write the failing test**

```js
import assert from "node:assert/strict"
import {
  isPrimaryNavActive,
  pageTitleForComponent,
  primaryNavItems,
  sectionRoot,
} from "../js/world_ia.js"

assert.deepEqual(primaryNavItems().map((item) => item.label), ["Chat", "Agents", "Manage"])
assert.deepEqual(primaryNavItems().map((item) => item.href), ["/sessions", "/identities/agents", "/workspaces"])

assert.equal(isPrimaryNavActive("/", "/sessions"), true)
assert.equal(isPrimaryNavActive("/sessions", "/sessions"), true)
assert.equal(isPrimaryNavActive("/sessions?session=x", "/sessions"), true)
assert.equal(isPrimaryNavActive("/identities/agents/new", "/identities/agents"), true)
assert.equal(isPrimaryNavActive("/admin/routing", "/workspaces"), true)
assert.equal(isPrimaryNavActive("/plugins/feishu/bindings", "/workspaces"), true)
assert.equal(isPrimaryNavActive("/profile", "/workspaces"), false)

assert.deepEqual(sectionRoot("/identities/agents/new"), {label: "Agents", href: "/identities/agents"})
assert.deepEqual(sectionRoot("/plugins/kanban"), {label: "Manage", href: "/workspaces"})
assert.deepEqual(sectionRoot("/admin/settings"), {label: "Manage", href: "/workspaces"})
assert.deepEqual(sectionRoot("/sessions"), {label: "Chat", href: "/sessions"})

assert.equal(pageTitleForComponent("sessions_table"), "Chat")
assert.equal(pageTitleForComponent("conversation"), "Chat")
assert.equal(pageTitleForComponent("profile"), "Profile")

console.log("world_ia_test: all assertions passed")
```

- [x] **Step 2: Run test to verify it fails**

Run: `node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../js/world_ia.js`.

- [x] **Step 3: Implement the pure helper and wire `main.tsx`**

Use `world_ia.js` as the only home for top-level labels and active grouping. Import its functions in `main.tsx`, replace local `NAV_ITEMS`, `sectionRoot`, `navClass`, and `pageTitle`, and keep existing class strings.

- [x] **Step 4: Run test to verify it passes**

Run: `node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`

Expected: PASS and print `world_ia_test: all assertions passed`.

## Task 2: Route Metadata Makes Chat The Default

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`

**Interfaces:**
- `Ezagent.World.Routes.route_for/2` returns `%{component: "sessions_table", title: "Chat"}` for `/` without a session param.
- `Ezagent.World.Routes.route_for/2` returns `%{component: "conversation", title: "Chat"}` for `/` or `/sessions` with a valid `session` query param.
- Unknown paths continue to fall back to `sessions_table`, now titled `Chat`.

- [x] **Step 1: Write the failing tests**

```elixir
test "root resolves to the Chat sessions surface" do
  route = Routes.route_for(%{}, "https://example.com/")

  assert route.component == "sessions_table"
  assert route.title == "Chat"
  assert route.path == "/"
end

test "session query resolves to the Chat conversation surface" do
  session = "session://acme/default/main"
  route = Routes.route_for(%{"session" => URI.encode_www_form(session)}, "https://example.com/sessions")

  assert route.component == "conversation"
  assert route.title == "Chat"
  assert URI.to_string(route.session_uri) == session
end

test "unknown world paths fall back to Chat rather than Overview copy" do
  route = Routes.route_for(%{}, "https://example.com/not-a-world-route")

  assert route.component == "sessions_table"
  assert route.title == "Chat"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`

Expected: FAIL because `/` currently resolves to `overview` and sessions are titled `Conversation` or `Sessions`.

- [x] **Step 3: Update route resolution**

Change only the top `/` and `/sessions` branch plus the final fallback. Leave all nested route maps unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`

Expected: PASS.

## Task 3: Header Owns Global Context, Account Owns Profile

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`
- Test: `apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

**Interfaces:**
- Header still renders `WorkspaceSwitcher`.
- Header does not render the visible `world-cmdk-open` button.
- `AccountMenu` accepts `children?: React.ReactNode` or an equivalent `themeControl?: React.ReactNode` prop and renders Profile, theme, and Sign out.

- [x] **Step 1: Write the failing structure assertions**

```js
import assert from "node:assert/strict"
import fs from "node:fs"

const main = fs.readFileSync("apps/ezagent_plugin_world/assets/src/main.tsx", "utf8")

assert.equal(main.includes('id="world-cmdk-open"'), false)
assert.equal(main.includes('href="/profile"'), true)
assert.equal(main.includes("<ThemeToggle />"), false)
assert.match(main, /<AccountMenu[\s\S]*themeControl=\{<ThemeToggle/)

console.log("world_ui_structure_test: all assertions passed")
```

- [x] **Step 2: Run test to verify it fails**

Run: `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

Expected: FAIL because `world-cmdk-open` and standalone `<ThemeToggle />` currently exist.

- [x] **Step 3: Update header and account menu**

Remove the header Command button. Keep `<CommandPalette>` mounted so server-pushed `cmdk.open` state still works. Pass theme control into `AccountMenu`. Add a Profile link before Sign out.

- [x] **Step 4: Run test to verify it passes**

Run: `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

Expected: PASS.

## Task 4: Chat Conversation Adds Session Rail

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- Test: `apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

**Interfaces:**
- Conversation root has `data-world-chat-layout="im"` and desktop grid `lg:grid-cols-[260px_minmax(0,1fr)_280px]`.
- Left rail uses `aria-label="Sessions"` and `data-world-session-rail`.
- Center transcript and right drawer keep existing send, invite, remove, routing, PTY, and debug callbacks.

- [x] **Step 1: Extend the failing structure assertions**

```js
const conversation = fs.readFileSync("apps/ezagent_plugin_world/assets/src/components/Conversation.tsx", "utf8")

assert.equal(conversation.includes('data-world-chat-layout="im"'), true)
assert.equal(conversation.includes("lg:grid-cols-[260px_minmax(0,1fr)_280px]"), true)
assert.equal(conversation.includes("data-world-session-rail"), true)
assert.equal(conversation.includes('aria-label="Sessions"'), true)
assert.equal(conversation.includes('aria-label="Session members"'), true)
```

- [x] **Step 2: Run test to verify it fails**

Run: `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

Expected: FAIL because the session rail markers do not exist yet.

- [x] **Step 3: Update Conversation layout**

Add a left session rail built from `state.sessions`. Each session row calls `onSwitch(session.uri)`. Keep the existing select only as a compact fallback for narrow layouts if useful; the desktop rail is the primary switcher.

- [x] **Step 4: Run test to verify it passes**

Run: `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`

Expected: PASS.

## Task 5: Verification

**Files:**
- No new source files beyond Tasks 1-4.

**Interfaces:**
- JS structure tests and route tests are the minimum gate.
- Build gate proves TypeScript/React integration.
- `mix precommit` remains the final repository gate; record environment failures exactly if PostgreSQL or external services are unavailable.

- [x] **Step 1: Run asset tests**

Run:

```bash
node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs
node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs
node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs
```

Expected: all pass.

- [ ] **Step 2: Run Elixir route and registry tests**

Run:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/navigation_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs \
  apps/ezagent_plugin_world/test/assets/world_navigation_test.exs
```

Expected: all pass after dependencies are installed.

- [x] **Step 3: Build world assets**

Run:

```bash
cd apps/ezagent_plugin_world/assets
corepack pnpm install --prefer-offline
corepack pnpm build
corepack pnpm check:mounts
```

Expected: install succeeds from cache or registry, Vite build passes, mount check passes.

- [ ] **Step 4: Run final gate**

Run: `mix precommit`

Expected: PASS. If local PostgreSQL at `127.0.0.1:55432` refuses connections, report that as an environment failure and include the narrower tests that did pass.

## Execution Notes

- Completed: JS navigation/IA/structure tests, formatter check for touched Elixir files, Vite build, and world mount gate.
- Completed with alternate pure verification: route metadata implementation. The standard ExUnit route test path was attempted but did not reach assertions because local PostgreSQL at `127.0.0.1:55432` refused connections while Mix tried to create the test DB.
- Blocked by local environment: combined ExUnit route/navigation/slot registry test run and `mix precommit`, both at the same PostgreSQL connection-refused step.
