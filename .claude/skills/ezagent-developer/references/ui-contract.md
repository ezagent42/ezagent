# UI / Frontend Contract

The UI has a **3-layer component architecture plus a runtime refresh contract**: changing one atom propagates to every page, while committed state reaches a mounted renderer through one declared, caller-scoped path. Style replacements (font / accent / dark palette) hit a small, well-known set of files. **Never write inline `style=""` in `.heex` files** outside the auth boundary pages (see below) — it bypasses the boundary and breaks theme-toggle infrastructure.

## UI architecture: component layers plus runtime refresh

- **Layer 1 — atoms** (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/`): stateless `Phoenix.Component`s. Zero LV deps. Files: `primitives.ex` (low-level: button, badge, status_dot, avatar, modal, tabs, toast, tree_list, empty_state, form_field, uri_chip, uri_picker, toolbar, tooltip, icon), `components.ex` (page_header, breadcrumb, card, stat), the shell components (see **Nested shell architecture** below). **The style-replacement boundary lives here.**
- **Layer 2 — plugin component compositions** (`apps/ezagent_plugin_world/lib/ezagent/world/` and renderer assets): plugin-level components and state builders compose atoms into a surface. A plugin declares what it contributes; it does not import World or own shell orchestration.
- **Layer 3 — World shell containers** (`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` and React world assets): World owns routes, caller context, subscription lifecycle, and transport to the mounted renderer. A container stays plugin-agnostic: no plugin-name branch or plugin-specific refresh handler.

### Runtime refresh contract (core UI architecture)

Component layers describe **where markup lives**. Realtime refresh is a separate
runtime contract describing **how mounted UI state changes**:

```
committed Kind slice
  → Ezagent.SliceChange
  → WorldLive subscription and refresh scheduling
  → RefreshSurfaceRegistry lookup
  → caller-scoped state_builder.refresh_state(uri, ctx)
  → world:surface_state partial payload
  → React shallow merge for that mounted surface
```

- A plugin page exposes `refresh_state/2`; standalone World surfaces declare
  `refresh_surfaces/0` through `Ezagent.World.UiSurfaceProvider`. The callback
  returns only JSON-safe, caller-authorized **partial** state for its renderer.
- `RefreshSurfaceRegistry` combines validated page and standalone declarations,
  fails closed for invalid data or provider errors, and never encodes a
  particular plugin's business rules.
- `WorldLive` is the sole consumer of `SliceChange` for browser refresh. It
  selects the active declared surface, coalesces pending refreshes, rebuilds
  state with current presenter caps, and emits `world:surface_state`.
- React may merge that envelope into the matching mounted surface; it must not
  infer permissions, refetch privileged state, or add plugin-specific event
  names for ordinary refreshes.

**Do not bypass this path.** A plugin must not add a bespoke World handler,
direct PubSub-to-browser refresh, or a `WorldLive` branch keyed by its name.
New UI state belongs in a surface declaration and `refresh_state/2`; new
transport semantics require an explicit architecture decision.

## Nested shell architecture (refactor 2026-05-22, SPEC `docs/superpowers/specs/2026-05-22-nested-shell-refactor.md`)

ONE outer shell owns the universal chrome; TWO inner perspectives fill its body. (Replaced the prior two-sibling-shell design — `ide_shell` + `AdminSettingsShell` — which left admin pages with no avatar/notifications/search.)

```
AppShell.app_shell        (Tier-3, ezagent_plugin_liveview) — the single thing an LV renders.
│  Wraps the Tier-2 outer chrome AND fills its :command_palette slot with the
│  stateful CommandPaletteComponent ONCE. Has a `perspective` attr + a :body slot.
│
└─ IdeShell.ide_shell_outer (Tier-2, ezagent_domain_ui/ide_shell.ex) — OUTER chrome:
   │  universal header (context affordance · search/⌘K · notifications · help · avatar)
   │  + :command_palette slot + :body slot. `perspective :: :workspace | :admin`.
   └─ :body — exactly one inner perspective:
      ├─ WorkspaceShell.workspace_shell (Tier-2, workspace_shell.ex) — Activity Bar +
      │    Resource Panel + Main Window + Right Sidebar + Status Bar.
      └─ AdminShell.admin_shell        (Tier-2, admin_shell.ex) — left settings nav + main.
```

- An LV renders `<AppShell.app_shell perspective={:workspace}>` with `<WorkspaceShell.workspace_shell>` in `:body` (workflow surfaces — /sessions, /routing, /identities, /plugins, …) OR `perspective={:admin}` with `<AdminShell.admin_shell>` (system-config surfaces — /admin/*, /workspaces).
- CmdK / `CommandPaletteComponent` is wired exactly ONCE, inside `app_shell` — never per-LV. `CommandSource` (Tier-2) is the pure ranking fn; nav routes flow DOWN from the `EzagentWeb.LiveAuth` `:cmdk_nav` on_mount assign.
- `perspective` is a typed context contract: `:workspace` → header shows the workspace dropdown; `:admin` → a system-context label (admin pages are `workspace://system` global config — you don't "switch workspace" there).

## Header / status-bar separation principle (Allen 2026-05-22)

The shell chrome splits into a **top header** (in `ide_shell_outer/1`, the outer
shell) and a **bottom status bar** (`status_bar/1`, internal to `workspace_shell`).
They have DIFFERENT semantic roles — don't put a control in the wrong one:

- **Header = workspace-scoped, view-INVARIANT.** Shows info that does NOT
  change as the user navigates between surfaces: the `ezagent / <workspace>`
  dropdown, global search (⌘K), notifications bell, help, the avatar menu.
  A control belongs in the header only if it would make sense on *every*
  page.
- **Status bar = position-scoped, view-VARIANT.** Shows info + controls
  tied to *where the user currently is*: the current entity URI, the
  current `session://` URI, agents/bridges signal lights, the Members-panel
  toggle, debug-events count. When the user switches view, the status bar
  is allowed (expected) to change.

Litmus test before placing a button: *"does this control still make sense
when the user navigates to a different page?"* — yes → header; no (it acts
on the current view/session/position) → status bar.

History: the Members-panel toggle was first (wrongly) placed in the header
next to the bell (V1 fix PR #178); moved to the status bar 2026-05-22 when
Allen surfaced this principle.

## DO list

- Wrap every shell LV `render/1` in `<AppShell.app_shell perspective={:workspace|:admin}>` with one inner perspective (`<WorkspaceShell.workspace_shell>` or `<AdminShell.admin_shell>`) in its `:body` slot. Never render a shell component directly — `app_shell` is the entry point (it wires CmdK).
- For a manual URI field, use `<.uri_picker mode={:single|:multi} options={...} />` — not a raw text input. Options come from `Ezagent.UI.UriOptions` (caller-authorized, workspace-scoped).
- Use `<.page_header title="...">...<:subtitle>...</:subtitle></.page_header>` for every page title.
- Use `<.breadcrumb items={[{"Admin", "/admin"}, {"This page", nil}]} />` for nested pages.
- Use `<.card class="...">` to wrap content blocks.
- Use `<.button variant="primary|secondary|ghost|danger">` for action buttons.
- Use `<.badge variant="success|warning|danger|info|primary">` for status pills.
- Use `<.empty_state title="..." description="...">` for "no items yet" screens.
- Use `<.icon name="..." size="xs|sm|md">` for iconography (Heroicons 24/outline).
- **Always pair `bg-*` / `text-*` / `border-*` with `dark:` variants.** Substitution table:

  | Light | Dark |
  |---|---|
  | `bg-white` | `dark:bg-zinc-900` |
  | `bg-zinc-50` | `dark:bg-zinc-950` |
  | `text-zinc-900` | `dark:text-zinc-100` |
  | `border-zinc-200` | `dark:border-zinc-800` |
  | `bg-blue-50` | `dark:bg-blue-950` (apply same -50 → -950 pattern across colors) |
  | `text-emerald-700` | `dark:text-emerald-300` (apply same -700 → -300 pattern across colors) |

- Use `font-mono` for URI / entity id / command palette display (JetBrains Mono via `--font-mono` CSS var).
- Use `text-orange-600` (signature accent) **sparingly** — only for the active Activity Bar rail or equivalent "this is selected" indicator.

## DON'T list (concrete violations from PR-A through PR-H audit)

- DON'T write `<h1 style="font-size: 22px; font-weight: 600;">` — use `<.page_header>` or `<h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">`.
- DON'T write `<a style="color: #0969da;">` — use `<a class="text-blue-600 dark:text-blue-400 hover:text-blue-700">`.
- DON'T write `<section style="margin-top: 24px; padding: 16px; border: 1px solid #d1d5da; border-radius: 6px;">` — use `<.card class="mt-6">`.
- DON'T add raw `bg-white` / `text-zinc-900` etc without their `dark:` sibling — dark-mode toggle silently breaks for that subtree.
- DON'T hard-code hex colors (`#1f883d`, `#cf222e`) — use Tailwind tokens (`bg-emerald-600`, `text-rose-600`).
- DON'T introduce new fonts. Geist + JetBrains Mono are the only two; both loaded via Google Fonts in `root.html.heex`.
- DON'T write inline `<style>` blocks in `.heex` files **except** in the controller-rendered auth boundary pages (login, custom 404) — they don't load `app.css` so they need self-contained `<style>` to brand themselves.
- DON'T write `<%!-- ... --%>` inside a raw HTML heredoc string (e.g. `@login_html """..."""` in `session_controller.ex`). EEx comment syntax only works inside `.heex` templates; in a raw heredoc the literal text renders verbatim into the browser. **In raw heredocs use `<!-- ... -->` (HTML comments — the browser strips them).** Lesson Allen 2026-05-20 after Phase 8c login-form edit shipped the EEx-style comment as visible page text.
- DON'T link to a route that doesn't exist. If a feature was deleted, REMOVE the link rather than leaving a dead button. Memory `feedback_ui_no_misleading_buttons`.

## Style-replacement safety checklist

When changing the visual design:

- **Swap fonts**: edit `app.css` (`--font-sans` / `--font-mono`) + `root.html.heex` (Google Fonts link) + `session_controller.ex` (login boundary inline style) + `404.html.heex` (404 boundary inline style). 4 files total.
- **Swap signature accent color**: search-replace `orange-600` / `orange-700` across `apps/ezagent_domain_ui/lib/` — should be ~3 occurrences (active Activity Bar rail).
- **Swap dark mode palette**: edit `app.css` `@plugin "../vendor/daisyui-theme" { name: "dark"; ... }` block. Components inherit via `dark:` Tailwind tokens — no per-atom edits needed.
- **Atoms vs LVs**: changing an atom (e.g. `<.card>`) propagates to every LV automatically. Changing a single LV touches only that file. The 3-layer architecture is what makes this work — don't fork atom logic into an LV "just for this page."

## Adding a new component to Layer 1

- File: pick the matching tier — `primitives.ex` (low-level atoms), `components.ex` (composite page-level atoms like header / breadcrumb / card / stat), or the shell files (`ide_shell.ex` outer chrome, `workspace_shell.ex` / `admin_shell.ex` inner perspectives — see Nested shell architecture).
- Pattern:

  ```elixir
  attr :foo, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def my_component(assigns) do
    ~H"""
    <div class={["base-classes dark:base-classes-dark", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
  ```

- Tests: add to `apps/ezagent_domain_ui/test/ezagent_domain_ui/...`.
- Reference example: `breadcrumb/1` in `components.ex` (added in PR-E, commit `bfa74ba`).

## Architecture invariants enforced by tests

- `apps/ezagent_domain_ui/test/ezagent_domain_ui/` — shell component tests (`ide_shell_outer`, `workspace_shell`, `admin_shell`) incl. Activity Bar item count + path mappings + the `perspective` header contract.
- `apps/ezagent_core/test/invariants/sessions_have_workspace_test.exs` — every session has a WorkspaceRegistry binding (Allen 2026-05-20).
- `apps/ezagent_web/test/ezagent_web/controllers/error_html_test.exs` — branded 404 renders with Activity Bar fallbacks.
- `lv_cli_parity_test.exs` (2026-05-25) — every LV `handle_event` has an equivalent `mix esr` CLI invocation, so headless ops can drive the system without the LV.
