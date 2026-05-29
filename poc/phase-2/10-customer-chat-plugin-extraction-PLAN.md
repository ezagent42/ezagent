# Customer-chat Plugin Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the customer-service surface into a dedicated `ezagent_plugin_customer_chat` plugin (so it registers on `/plugins` and can evolve independently), add a direct `/operator/:tenant` entry + a real operator cap, without breaking any passing e2e flow.

**Architecture:** New umbrella app `apps/ezagent_plugin_customer_chat` carrying the `Ezagent.Plugin` contract + the customer chat LiveView/widget-logic + the operator console. The two HTTP controllers stay in `ezagent_web` (the HTTP edge) and call into the moved `Bootstrap`. `Ezagent.Behavior.Mode` stays in `ezagent_domain_chat`. The operator console is detached from the admin-UI chrome (`EzagentPluginLiveview.AppShell`) so it runs under a non-admin operator scope and carries no backwards dependency on the admin plugin.

**Tech Stack:** Elixir umbrella, Phoenix LiveView, `Ezagent.Plugin` contract + `:ezagent_plugin_check` compiler gate, `Ezagent.Capability`, `Ezagent.Identity.list_caps_for/1`.

**Worktree / run context:**
- Repo: `~/workspace/ezagent42/ezagent-poc-phase-2`, branch `poc/phase-2-customer-service`.
- Compile/test: prefix every mix command with `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps`. **NEVER** run `mix deps.get`.
- New umbrella app is auto-discovered under `apps/`; `mix phx.server` starts all umbrella apps, so the plugin's `boot/1` runs once the app dir + `mix.exs` exist.
- Server restart for e2e: see `MANUAL-TEST-PLAN.md` appendix (the `EZAGENT_BRIDGE_WS_URL` + `env -u …` workarounds + the `deps`-symlink/`mix esbuild` asset note).
- Spec this implements: `poc/phase-2/10-customer-chat-plugin-extraction-design.md`.

---

## File Structure

| Path | Responsibility | New/Modify/Move |
|---|---|---|
| `apps/ezagent_plugin_customer_chat/mix.exs` | umbrella app + plugin-check compiler + deps | Create |
| `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/application.ex` | `Ezagent.Plugin` contract module (plugin_info + config_surface route) | Create |
| `.../lib/ezagent_plugin_customer_chat/theme.ex` | per-tenant theme resolver | Move+rename |
| `.../lib/ezagent_plugin_customer_chat/bootstrap.ex` | session+cc+bridge+dispatch + builders | Move+rename |
| `.../lib/ezagent_plugin_customer_chat/components.ex` | shared HEEx components + row mapping | Move+rename |
| `.../lib/ezagent_plugin_customer_chat/chat_live.ex` | public customer chat LiveView | Move+rename |
| `.../lib/ezagent_plugin_customer_chat/dashboard_live.ex` | operator console — live session list | Move+rename+detach-chrome |
| `.../lib/ezagent_plugin_customer_chat/session_view_live.ex` | operator console — per-session + take-over | Move+rename+detach-chrome |
| `.../priv/customer_chat_themes/acme.json` | acme theme fixture | Move |
| `.../test/ezagent_plugin_customer_chat/{theme,bootstrap,components}_test.exs` | unit tests | Move+rename |
| `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex` | SSE controller → calls moved Bootstrap | Modify |
| `apps/ezagent_web/lib/ezagent_web/router.ex` | repoint LV refs + add `/operator` routes + redirect | Modify |
| `apps/ezagent_web/mix.exs` | add dep on new plugin | Modify |
| `apps/ezagent_plugin_liveview/.../customer_chat/*`, `customer_session*_live.ex`, `priv/customer_chat_themes/*`, tests | removed | Delete |

**Module renames (apply consistently):**
- `EzagentPluginLiveview.CustomerChat.Theme|Bootstrap|Components|ChatLive` → `EzagentPluginCustomerChat.Theme|Bootstrap|Components|ChatLive`
- `EzagentPluginLiveview.CustomerSessionsDashboardLive` → `EzagentPluginCustomerChat.DashboardLive`
- `EzagentPluginLiveview.CustomerSessionViewLive` → `EzagentPluginCustomerChat.SessionViewLive`

**Testing note:** the 3 pure unit suites (theme/bootstrap/components) move and stay green under the new module names. The runtime-coupled paths (cc spawn, operator cap, tenant-routed mount) are validated by the manual e2e gate (Task 11), exactly as Phase 2/3 were accepted. Do NOT write tests that spawn a real cc agent.

---

## Task 1: Scaffold the empty plugin app

Creates the app so it compiles, passes `:ezagent_plugin_check`, and shows on `/plugins` — before any business code moves in.

**Files:**
- Create: `apps/ezagent_plugin_customer_chat/mix.exs`
- Create: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/application.ex`
- Modify: `apps/ezagent_web/mix.exs`

- [ ] **Step 1: Create `mix.exs`**

```elixir
# apps/ezagent_plugin_customer_chat/mix.exs
defmodule EzagentPluginCustomerChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_customer_chat,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # phoenix_live_view first (preprocesses .heex colocated hooks);
      # :ezagent_plugin_check last (non-bypassable contract gate).
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:ezagent_plugin_check]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentPluginCustomerChat.Application, []},
      env: [ezagent_plugin: EzagentPluginCustomerChat.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_chat, in_umbrella: true},
      {:ezagent_domain_ui, in_umbrella: true},
      {:ezagent_plugin_cc, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end
end
```

- [ ] **Step 2: Create the plugin contract module**

```elixir
# apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/application.ex
defmodule EzagentPluginCustomerChat.Application do
  @moduledoc """
  Customer-chat plugin OTP application — the `Ezagent.Plugin` contract
  module (the AI-customer-service template's frontend slice).

  Ships UI + bootstrap logic only: the public customer chat LiveView +
  widget logic, and the operator console. It declares NO Kinds /
  Behaviors / agent flavors / templates — the generic takeover
  primitive (`Ezagent.Behavior.Mode`) lives in `ezagent_domain_chat`.

  `config_surface/0` is a `:route` to `/operator`, so the `/plugins`
  card links straight to the operator console. `adapters/0` is left
  empty but reserved — it is the future home for a foreign-IM
  External Mirror adapter (e.g. CINNOX); see
  `poc/phase-2/10-customer-chat-plugin-extraction-design.md` §7.
  """
  use Application
  use Ezagent.Plugin

  @impl true
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "customer_chat",
      name: "Customer Service",
      description: "AI customer service — web chat, embeddable widget, operator takeover.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/operator", label: "Customer Service"}
  end
end
```

- [ ] **Step 3: Add the dep edge from `ezagent_web`**

In `apps/ezagent_web/mix.exs` `deps/0`, add (next to the existing `:ezagent_plugin_liveview` line):

```elixir
      {:ezagent_plugin_customer_chat, in_umbrella: true},
```

- [ ] **Step 4: Compile — app + contract gate**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -25`
Expected: compiles clean; `Generated ezagent_plugin_customer_chat app`; no `:ezagent_plugin_check` errors. (An empty plugin with only `plugin_info` + `config_surface` is contract-valid; all other callbacks default.)

If the gate complains the `:route` config_surface path has no matching route yet: the gate only validates the surface *shape* (`%{kind: :route, path:, label:}`), not that the route exists — so this passes. The `/operator` route is added in Task 8.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/mix.exs apps/ezagent_plugin_customer_chat/lib apps/ezagent_web/mix.exs
git commit -m "feat(customer-chat): scaffold ezagent_plugin_customer_chat plugin app"
```

---

## Task 2: Move Theme + fixture

**Files:**
- Move: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/theme.ex`
- Move: `apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json` → `apps/ezagent_plugin_customer_chat/priv/customer_chat_themes/acme.json`
- Move: `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs` → `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/theme_test.exs`

- [ ] **Step 1: git mv the files**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
mkdir -p apps/ezagent_plugin_customer_chat/priv/customer_chat_themes
mkdir -p apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/theme.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/theme.ex
git mv apps/ezagent_plugin_liveview/priv/customer_chat_themes/acme.json \
       apps/ezagent_plugin_customer_chat/priv/customer_chat_themes/acme.json
git mv apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/theme_test.exs \
       apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/theme_test.exs
```

- [ ] **Step 2: Rename module + fix priv_dir app atom**

In `theme.ex`: `EzagentPluginLiveview.CustomerChat.Theme` → `EzagentPluginCustomerChat.Theme`. The `file_theme/1` reads `:code.priv_dir(:ezagent_plugin_liveview)` → change to `:ezagent_plugin_customer_chat`. The config key `Application.get_env(:ezagent_plugin_liveview, :customer_chat_themes, ...)` → `:ezagent_plugin_customer_chat`.

```bash
sed -i '' \
  -e 's/EzagentPluginLiveview.CustomerChat.Theme/EzagentPluginCustomerChat.Theme/g' \
  -e 's/:ezagent_plugin_liveview/:ezagent_plugin_customer_chat/g' \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/theme.ex
```

In `theme_test.exs`: rename the alias + the `Application.put_env(:ezagent_plugin_liveview, ...)` app key + module name:

```bash
sed -i '' \
  -e 's/EzagentPluginLiveview.CustomerChat.Theme/EzagentPluginCustomerChat.Theme/g' \
  -e 's/:ezagent_plugin_liveview/:ezagent_plugin_customer_chat/g' \
  apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/theme_test.exs
```

- [ ] **Step 3: Run the theme test under the new app**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/theme_test.exs`
Expected: PASS (3 tests). (`:code.priv_dir(:ezagent_plugin_customer_chat)` now resolves the moved fixture.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): move Theme + acme fixture into the plugin"
```

---

## Task 3: Move Bootstrap

**Files:**
- Move: `…/customer_chat/bootstrap.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex`
- Move: `…/customer_chat/bootstrap_test.exs` → `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs`

- [ ] **Step 1: git mv**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex
git mv apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/bootstrap_test.exs \
       apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs
```

- [ ] **Step 2: Rename module + config app keys**

`Bootstrap` reads two config keys with `Application.get_env(:ezagent_plugin_liveview, :customer_chat_sandbox_root/:customer_chat_soul_root, ...)`. Rename module + both app keys. The soul-root default uses a `__ENV__.file`-relative `../../../../../../poc/fixtures/plugins` path — the new file sits at the SAME directory depth (`apps/<app>/lib/<app>/bootstrap.ex`), so the hop count is unchanged.

```bash
sed -i '' \
  -e 's/EzagentPluginLiveview.CustomerChat.Bootstrap/EzagentPluginCustomerChat.Bootstrap/g' \
  -e 's/:ezagent_plugin_liveview/:ezagent_plugin_customer_chat/g' \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex
sed -i '' \
  -e 's/EzagentPluginLiveview.CustomerChat.Bootstrap/EzagentPluginCustomerChat.Bootstrap/g' \
  apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs
```

- [ ] **Step 3: Verify the soul-root path still resolves**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix run -e 'IO.puts(Path.expand("../../../../../../poc/fixtures/plugins", "/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2/apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex"))'`
Expected: `/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2/poc/fixtures/plugins`. If wrong, adjust the `..` count in `cc_soul_path_for_workspace/2`.

- [ ] **Step 4: Run the bootstrap test**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): move Bootstrap into the plugin"
```

---

## Task 4: Move Components

**Files:**
- Move: `…/customer_chat/components.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/components.ex`
- Move: `…/customer_chat/components_test.exs` → `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/components_test.exs`

- [ ] **Step 1: git mv + rename**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/components.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/components.ex
git mv apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/components_test.exs \
       apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/components_test.exs
sed -i '' -e 's/EzagentPluginLiveview.CustomerChat.Components/EzagentPluginCustomerChat.Components/g' \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/components.ex \
  apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/components_test.exs
```

- [ ] **Step 2: Run the components test**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/components_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): move HEEx components into the plugin"
```

---

## Task 5: Move ChatLive (customer page)

**Files:**
- Move: `…/customer_chat/chat_live.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/chat_live.ex`

- [ ] **Step 1: git mv + rename (module + its aliases/imports)**

ChatLive has `import EzagentPluginLiveview.CustomerChat.Components` and `alias EzagentPluginLiveview.CustomerChat.{Bootstrap, Components, Theme}`. The single `EzagentPluginLiveview.CustomerChat` → `EzagentPluginCustomerChat` rename covers the module name, the import, and the alias.

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/chat_live.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/chat_live.ex
sed -i '' -e 's/EzagentPluginLiveview.CustomerChat/EzagentPluginCustomerChat/g' \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/chat_live.ex
```

(ChatLive already has its own self-contained layout — no AppShell, no Gettext — so no chrome work here.)

- [ ] **Step 2: Compile**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | grep -iE "chat_live|customer_chat|error|Generated ezagent_plugin_customer_chat" | tail`
Expected: `Generated ezagent_plugin_customer_chat app`, no errors. (The router still points at the OLD module name until Task 7 — that's fine; `mix compile` of the plugin app doesn't need the route. If `ezagent_web` fails because the router references the now-missing `EzagentPluginLiveview.CustomerChat.ChatLive`, that's expected and resolved in Task 7; to keep this task green, run the scoped compile: `mix compile --no-deps-check 2>&1 | grep ezagent_plugin_customer_chat` OR proceed — Task 7 repoints the router. Note it as DONE_WITH_CONCERNS if ezagent_web won't compile yet, and proceed to Task 6/7.)

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): move customer ChatLive into the plugin"
```

---

## Task 6: Move operator LVs + detach admin chrome

The operator LVs (`DashboardLive`, `SessionViewLive`) currently `use Gettext, backend: EzagentPluginLiveview.Gettext`, `alias EzagentPluginLiveview.AppShell`, `alias EzagentDomainUi.AdminShell`, `use EzagentDomainUi.Components`, and render inside `<AppShell.app_shell …><AdminShell.admin_shell …>`. To run under the operator scope (non-admin) without a backwards dep on the admin plugin, replace that chrome with a self-contained layout and drop Gettext (inline the strings).

**Files:**
- Move: `…/customer_sessions_dashboard_live.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex`
- Move: `…/customer_session_view_live.ex` → `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex`

- [ ] **Step 1: git mv + module rename**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_sessions_dashboard_live.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex
git mv apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_session_view_live.ex \
       apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex
sed -i '' \
  -e 's/EzagentPluginLiveview.CustomerSessionsDashboardLive/EzagentPluginCustomerChat.DashboardLive/g' \
  -e 's/EzagentPluginLiveview.CustomerSessionViewLive/EzagentPluginCustomerChat.SessionViewLive/g' \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex
```

- [ ] **Step 2: Drop Gettext (inline strings)**

In BOTH files: remove the line `use Gettext, backend: EzagentPluginLiveview.Gettext`. Then replace every `gettext("…")` call with the bare string literal it wraps (e.g. `{gettext("Back")}` → `{"Back"}`; `gettext("Take over")` → `"Take over"`). For `gettext("… %{x} …", x: v)` interpolations, convert to an Elixir string interpolation (e.g. `gettext("Session %{id}", id: foo)` → `"Session #{foo}"`). Read each file and convert every occurrence; verify none remain:

```bash
grep -n "gettext\|EzagentPluginLiveview.Gettext" apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex
```
Expected after conversion: no matches.

- [ ] **Step 3: Replace the admin-shell chrome with a self-contained layout**

In BOTH files: remove `alias EzagentPluginLiveview.AppShell`. Keep `alias EzagentDomainUi.AdminShell` ONLY if still used after this step; if the outer `AdminShell.admin_shell` wrapper is removed, drop that alias and the `use EzagentDomainUi.Components` too (unless an inner `<.button>`/component from it is still used — grep to confirm).

In each `render/1`, replace the outer wrapper:

```elixir
<AppShell.app_shell perspective={:admin} current_entity_uri={…} … >
  <:body>
    <AdminShell.admin_shell current_path="/admin/customer_sessions" active_section={nil}>
      <:main>
        … KEEP THIS INNER CONTENT …
      </:main>
    </AdminShell.admin_shell>
  </:body>
</AppShell.app_shell>
```

with a self-contained operator layout (keep the inner functional markup verbatim — session list / transcript / take-over button / composer):

```elixir
<div class="h-screen flex flex-col bg-zinc-50">
  <header class="px-6 py-3 border-b border-zinc-200 bg-white flex items-center gap-3">
    <span class="font-semibold text-zinc-900">Customer Service</span>
    <span class="text-xs text-zinc-500 font-mono">{@tenant}</span>
  </header>
  <div class="flex-1 min-h-0 overflow-auto">
    … KEEP THIS INNER CONTENT (the former <:main> body) …
  </div>
</div>
```

(`@tenant` is assigned in Task 8's mount. Until then it's unset — Task 8 lands together with this; if executing strictly task-by-task, use `{@workspace_seg}` which the session-view already assigns, or assign `:tenant` now. Implementer: assign `:tenant` in mount in Task 8.)

- [ ] **Step 4: Compile the plugin (ignore router refs for now)**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | grep -iE "dashboard_live|session_view|customer_chat|undefined|error" | tail -20`
Expected: no errors attributable to these two files (AppShell/Gettext/AdminShell references gone). `ezagent_web` router still references old names → fixed in Task 7.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): move operator console into the plugin, detach admin chrome + gettext"
```

---

## Task 7: Repoint `ezagent_web` (controller + router) to the new modules

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`

- [ ] **Step 1: Repoint the SSE controller's alias**

In `customer_chat_controller.ex`: change `alias EzagentPluginLiveview.CustomerChat.Bootstrap` → `alias EzagentPluginCustomerChat.Bootstrap`.

```bash
sed -i '' -e 's/EzagentPluginLiveview.CustomerChat.Bootstrap/EzagentPluginCustomerChat.Bootstrap/g' \
  apps/ezagent_web/lib/ezagent_web/controllers/customer_chat_controller.ex
```

- [ ] **Step 2: Repoint the router's customer-chat + dashboard route module refs**

In `router.ex`: the public `live "/chat/:tenant"` currently points at `EzagentPluginLiveview.CustomerChat.ChatLive` (via the `scope "/", EzagentPluginLiveview` alias). Move that route into a scope aliased to the new plugin, OR fully-qualify. Cleanest: change the customer-chat `scope`'s alias.

Find the block (added in the frontend phase):
```elixir
  scope "/", EzagentPluginLiveview do
    pipe_through :customer_chat_browser
    live_session :customer_chat_public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do
      live "/chat/:tenant", CustomerChat.ChatLive
    end
  end
```
Replace the alias + module ref:
```elixir
  scope "/", EzagentPluginCustomerChat do
    pipe_through :customer_chat_browser
    live_session :customer_chat_public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do
      live "/chat/:tenant", ChatLive
    end
  end
```

For the OLD admin dashboard routes (`live "/admin/customer_sessions"` + `:id`) — these are replaced by Task 8's `/operator` routes + a redirect. For THIS task, just make them compile by repointing to the new modules (Task 8 then changes the paths):
```elixir
      live "/admin/customer_sessions", EzagentPluginCustomerChat.DashboardLive
      live "/admin/customer_sessions/:id", EzagentPluginCustomerChat.SessionViewLive
```
(They're inside the `scope "/", EzagentPluginLiveview` admin block; fully-qualify the module since the scope alias is `EzagentPluginLiveview`.)

- [ ] **Step 3: Compile the whole umbrella**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | tail -20`
Expected: clean across the umbrella now (plugin + ezagent_web both resolve). Fix any remaining `EzagentPluginLiveview.CustomerChat`/`CustomerSessions…` references the grep below surfaces:

```bash
grep -rn "EzagentPluginLiveview.CustomerChat\|CustomerSessionsDashboardLive\|CustomerSessionViewLive" apps --include=*.ex --include=*.exs
```
Expected: no matches (all repointed).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(customer-chat): repoint ezagent_web controller + router to the plugin"
```

---

## Task 8: Operator direct entry — `/operator/:tenant` + tenant-baked mount + operator cap

The new behavior. Adds the focused operator routes, makes the LVs read the tenant from the path (no workspace-switch), and replaces the "any cap" gate with the workspace-scoped `Mode.set` operator cap (admin bypass via `is_system_member?`).

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/dashboard_live.ex`
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex`

- [ ] **Step 1: Add operator routes + redirect the old admin paths**

In `router.ex`, inside the `live_session :require_entity` block (the logged-in, non-admin scope — gives `current_entity_uri` + `is_system_member?` assigns), add operator routes aliased to the new plugin:

```elixir
    scope "/", EzagentPluginCustomerChat do
      live "/operator", DashboardLive
      live "/operator/:tenant", DashboardLive
      live "/operator/:tenant/:conv", SessionViewLive
    end
```
(Place this scope adjacent to the other `:require_entity` LVs. `:require_entity` already chains `:put_locale`/`:cmdk_nav` and sets `current_entity_uri`, `current_workspace_uri`, `is_admin?`, `is_system_member?`.)

Then REMOVE the two `live "/admin/customer_sessions[…]"` lines from the admin block (Task 7 left them) and add a redirect controller route so old links still work. In a `scope "/", EzagentWeb` admin-gated block add:
```elixir
      get "/admin/customer_sessions", CustomerSessionsRedirectController, :redirect
```
Create `apps/ezagent_web/lib/ezagent_web/controllers/customer_sessions_redirect_controller.ex`:
```elixir
defmodule EzagentWeb.CustomerSessionsRedirectController do
  use Phoenix.Controller, formats: [:html]
  def redirect(conn, _params), do: Phoenix.Controller.redirect(conn, to: "/operator")
end
```

- [ ] **Step 2: Dashboard — read tenant from params, operator-cap gate**

In `dashboard_live.ex` `mount/3`, stop reading `current_workspace_uri` from assigns; derive the workspace from the `:tenant` path param. Replace the mount head + authorization:

```elixir
@impl true
def mount(params, _session, socket) do
  caller_uri = socket.assigns[:current_entity_uri]
  tenant = params["tenant"]

  cond do
    is_nil(tenant) ->
      # /operator with no tenant → pick the workspaces the operator can serve
      {:ok, redirect_to_single_or_list(socket, caller_uri)}

    not operator?(caller_uri, tenant, socket.assigns[:is_system_member?]) ->
      {:ok, socket |> put_flash(:error, "Operator access required for #{tenant}.") |> redirect(to: "/operator")}

    true ->
      workspace_uri = URI.parse("workspace://#{tenant}")
      if connected?(socket), do: subscribe_to_sessions(workspace_uri)
      rows = enumerate_session_rows(workspace_uri)

      {:ok,
       socket
       |> assign(:tenant, tenant)
       |> assign(:workspace_uri, workspace_uri)
       |> stream(:sessions, rows)
       # … keep the rest of the original assigns (page_title, etc.) …
      }
  end
end
```

Add the operator gate + a minimal tenant picker near the other private helpers:

```elixir
# Operator gate: a system member (admin) always passes; otherwise the
# caller must hold the takeover cap (Mode.set) over this workspace —
# "if you can take over here, you can use the operator console here".
defp operator?(nil, _tenant, _sys?), do: false
defp operator?(_caller, _tenant, true), do: true
defp operator?(%URI{} = caller, tenant, _sys?) do
  ws = URI.parse("workspace://#{tenant}")
  caller
  |> Ezagent.Identity.list_caps_for()
  |> Enum.any?(&mode_set_cap_for_workspace?(&1, ws))
end

defp mode_set_cap_for_workspace?(%Ezagent.Capability{} = c, %URI{} = ws) do
  c.kind == :session and c.behavior == Ezagent.Behavior.Mode and c.action == :set and
    (c.workspace == :any or c.workspace == ws or
       (match?(%URI{}, c.workspace) and URI.to_string(c.workspace) == URI.to_string(ws)))
end
defp mode_set_cap_for_workspace?(_, _), do: false

# /operator with no tenant: list workspaces the caller can serve; if
# exactly one, jump straight in.
defp redirect_to_single_or_list(socket, caller_uri) do
  tenants = servable_tenants(caller_uri, socket.assigns[:is_system_member?])
  case tenants do
    [only] -> push_navigate(socket, to: "/operator/#{only}")
    _ -> assign(socket, :servable_tenants, tenants) |> assign(:tenant, nil)
  end
end

defp servable_tenants(caller_uri, sys?) do
  Ezagent.Workspace.Store.list_all()       # [decoded()] ordered by name
  |> Enum.map(& &1.name)
  |> Enum.filter(fn t -> operator?(caller_uri, t, sys?) end)
end
```

(`Ezagent.Workspace.Store.list_all/0` returns decoded workspace maps with a `.name` field, ordered by name — confirmed. The no-tenant picker render is a simple list of links to `/operator/<t>`; add a small render branch when `@tenant == nil`.)

Delete the old `authorize_operator/2` + `has_any_cap?/1` + the `:no_workspace`/`:no_caps` `deny_message` clauses (superseded).

- [ ] **Step 3: SessionViewLive — read tenant + conv from params, same gate**

In `session_view_live.ex` `mount/3`: it currently parses an encoded session-URI `:id` param. Change to read `:tenant` + `:conv` path params and build the session URI directly; reuse the same `operator?/3` gate (copy the three private helpers, or extract to a shared `EzagentPluginCustomerChat.OperatorAuth` module and call from both — preferred to avoid duplication):

```elixir
@impl true
def mount(%{"tenant" => tenant, "conv" => conv} = _params, _session, socket) do
  caller_uri = socket.assigns[:current_entity_uri]
  if EzagentPluginCustomerChat.OperatorAuth.operator?(caller_uri, tenant, socket.assigns[:is_system_member?]) do
    session_uri = URI.parse("session://default/#{tenant}/#{conv}")
    # … existing subscribe + load_messages + assigns, using session_uri …
    {:ok, assign(socket, :tenant, tenant) |> …}
  else
    {:ok, socket |> put_flash(:error, "Operator access required.") |> redirect(to: "/operator")}
  end
end
```

Create `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/operator_auth.ex` holding `operator?/3` + `mode_set_cap_for_workspace?/2` (moved from Task 8 Step 2; have DashboardLive call it too — DRY).

Update the dashboard row links + `back` links to the new `/operator/:tenant[/:conv]` paths (was `/admin/customer_sessions/<encoded-uri>`). The row navigate target becomes `~p"/operator/#{@tenant}/#{conv_id}"` (or a plain string `"/operator/#{tenant}/#{conv}"`).

- [ ] **Step 4: Compile**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile --warnings-as-errors 2>&1 | grep -iE "customer_chat|operator_auth|dashboard|session_view|router|error|warning" | tail -25`
Expected: clean (pre-existing unrelated warnings in other apps are OK; nothing from the new plugin or the router).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(customer-chat): /operator/:tenant direct entry + workspace-scoped operator cap"
```

---

## Task 9: Remove leftovers from `ezagent_plugin_liveview`

**Files:**
- Delete: empty `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/` dir (files already `git mv`-d)
- Delete: empty `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/customer_chat/` dir
- Delete: `apps/ezagent_plugin_liveview/priv/customer_chat_themes/` if empty

- [ ] **Step 1: Confirm nothing customer-chat remains in liveview**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
grep -rn "CustomerChat\|customer_session\|customer_chat" apps/ezagent_plugin_liveview --include=*.ex --include=*.exs
find apps/ezagent_plugin_liveview -type d -empty
```
Expected: no source matches (only possibly empty dirs). Remove any now-empty `customer_chat`/`customer_chat_themes` dirs:
```bash
find apps/ezagent_plugin_liveview -type d -empty -delete
```

- [ ] **Step 2: Compile liveview alone**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile 2>&1 | grep -iE "ezagent_plugin_liveview|error|Generated" | tail`
Expected: `ezagent_plugin_liveview` compiles clean without the moved files.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "chore(customer-chat): drop customer-chat leftovers from ezagent_plugin_liveview"
```

---

## Task 10: Full suite + compile-clean + plugin-check + /plugins card

- [ ] **Step 1: Run the customer-chat unit suite under the new app**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ apps/ezagent_web/test/ezagent_web/controllers/customer_chat_widget_controller_test.exs`
Expected: all green (3 theme + 5 bootstrap + 4 components + 1 widget = 13).

- [ ] **Step 2: Compile warnings-as-errors across the umbrella**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile --force --warnings-as-errors 2>&1 | grep -iE "customer_chat|operator_auth|router|customer_chat_controller" | grep -iE "error|warning"`
Expected: no output (our code warning-clean). Pre-existing warnings elsewhere may exist; only our files matter.

- [ ] **Step 3: Confirm the plugin registers on `/plugins`**

Restart the server (PLAN header / appendix). Run:
```bash
curl -s --max-time 10 http://localhost:10142/plugins | grep -iE "Customer Service|customer_chat" | head
```
Expected: the "Customer Service" card text is present (served from `plugin_info/0`). (If `/plugins` requires auth and curl returns the login page, verify instead via `mix run -e 'IO.inspect(Ezagent.PluginRegistry.list_all())'` and confirm `EzagentPluginCustomerChat.Application` is listed.)

- [ ] **Step 4: Commit (if anything changed)**

```bash
git add -A && git commit -m "chore(customer-chat): green suite + compile-clean checkpoint" --allow-empty
```

---

## Task 11: End-to-end re-verification (acceptance gate)

Manual browser e2e on the extracted tree (mirrors how Phase 2/3 were accepted). Restart the server first; remember the asset build (`deps` symlink + `mix esbuild ezagent_web` + `mix tailwind ezagent_web`) per the MANUAL-TEST-PLAN appendix.

- [ ] **Step 1: Customer page + soul reply** — open `http://localhost:10142/chat/acme`, send "How long is the warranty on my Acme laptop?"; expect themed page + AI reply with 12-mo / 24-mo Pro facts. (criterion 1)
- [ ] **Step 2: Reload-resume** — reload; same thread restored. (criterion: localStorage hook still wired)
- [ ] **Step 3: Widget** — open `http://localhost:8088/widget-test.html` (start `python3 -m http.server 8088` in `/tmp` if needed); bubble → iframe chat works. (criterion 2)
- [ ] **Step 4: `/plugins` → operator** — log in as admin (`entity://user/system/admin` / `ezagent-dev`); `/plugins` shows "Customer Service"; clicking it lands on `/operator`. (config_surface route)
- [ ] **Step 5: Operator direct entry, no workspace switch** — go to `http://localhost:10142/operator/acme` directly; the dashboard lists acme's live customer sessions **without** switching the current workspace. (the tenant-baked route + operator gate; admin passes via `is_system_member?`)
- [ ] **Step 6: Takeover** — open a session (`/operator/acme/<conv>`), click "Take over", send an operator message; the customer `/chat/acme` page shows the `客服已接管` banner + notice + operator message live. (criterion 3 — C3-tension fix intact)
- [ ] **Step 7: Old-link redirect** — `http://localhost:10142/admin/customer_sessions` redirects to `/operator`.
- [ ] **Step 8: No hardcoded tenant** — `grep -rniE '"acme"|acme' apps/ezagent_plugin_customer_chat/lib` → only fixture/doc references, none driving logic.
- [ ] **Step 9: Record results** — append a "Plugin extraction — acceptance" section to `poc/phase-2/ACCEPTANCE.md`; commit.

```bash
git add poc/phase-2/ACCEPTANCE.md
git commit -m "docs(customer-chat): record plugin-extraction acceptance results"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage** (vs `10-…-design.md`): §3 plugin app → Task 1; §4 migration map → Tasks 2–7,9; §5 routes (incl. `/operator`) → Tasks 7–8; §6 operator cap → Task 8; §7 EM relationship → captured in `application.ex` moduledoc (Task 1) + `adapters/0` default-empty (no code, by design); §8 testing → Tasks 10–11; §9 out-of-scope honored (no escalation/EM-adapter/SSO/`/sessions` change); §10 acceptance → Task 11. No gaps.

**Type/name consistency:** module names `EzagentPluginCustomerChat.{Theme,Bootstrap,Components,ChatLive,DashboardLive,SessionViewLive,OperatorAuth,Application}` used consistently; `operator?/3` + `mode_set_cap_for_workspace?/2` defined once in `OperatorAuth` (Task 8 Step 3) and called from both LVs; route paths `/operator`, `/operator/:tenant`, `/operator/:tenant/:conv` consistent across Tasks 7–8 and Task 11.

**Placeholder scan:** the operator-LV render/gettext edits (Task 6) and the mount rewrites (Task 8) are "edit existing file" steps — they show the exact replacement layout/auth code and the exact removal list, with a grep to confirm completion, rather than reproducing the full ~430-line files (the implementer has them open). The workspace lister name was verified (`Ezagent.Workspace.Store.list_all/0`, returns decoded maps with `.name`). No TODO/TBD left as unspecified behavior.
