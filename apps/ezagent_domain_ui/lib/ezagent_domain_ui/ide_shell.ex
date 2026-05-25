defmodule EzagentDomainUi.IdeShell do
  @moduledoc """
  Agent IDE Shell — the Tier-2 OUTER chrome (nested-shell SPEC §1).

  Stateless `Phoenix.Component`s (Tier-2, `ezagent_domain_ui` — zero
  LiveView/registry deps, per the UI Contract). State (which Activity
  is active, what's in the resource panel, etc.) is owned by the
  wrapping LiveView and passed down as attrs.

  ## Nested-shell refactor (SPEC §1, §6)

  - **PR-1** added `ide_shell_outer/1` — the new Tier-2 OUTER chrome:
    universal header + `:command_palette` slot + `:body` slot.
  - **PR-3** deleted the old monolithic `ide_shell/1` and its
    body-only helpers (`activity_bar/1`, `activity_items/0`,
    `activity_for_path/1`, `top_command_bar/1`, `status_bar/1`) once
    its last consumer migrated. Those body helpers were copied into
    `EzagentDomainUi.WorkspaceShell` in PR-1; that module is now their
    home. The OUTER chrome (`ide_shell_outer/1`) + the shared header
    helpers (`outer_command_bar/1`, `workspace_dropdown/1`,
    `avatar_menu/1`) stay here.

  The `:body` slot of `ide_shell_outer/1` hosts exactly one inner
  perspective — `EzagentDomainUi.WorkspaceShell.workspace_shell/1`
  (sessions/agents) or `EzagentDomainUi.AdminShell.admin_shell/1`
  (`workspace://system` config).

  This module still also carries a few standalone presentational
  atoms (`editor_tabs/1`, `split_pane/1`, `command_palette/1`) used
  inside inner-perspective bodies.
  """

  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend. NOT a
  # dependency on `ezagent_web` (see `EzagentDomainUi.Gettext` moduledoc).
  use Gettext, backend: EzagentDomainUi.Gettext
  use EzagentDomainUi.Primitives
  alias Phoenix.LiveView.JS

  # --- ide_shell_outer -------------------------------------------------------

  @doc """
  Nested-shell refactor PR-1 (SPEC §1, §2, §6 row 1) — the Tier-2
  OUTER chrome.

  Renders ONLY the universal top header + a `:command_palette` slot +
  a `:body` slot. The `:body` slot hosts exactly one inner perspective
  — `EzagentDomainUi.WorkspaceShell.workspace_shell/1` (sessions/agents)
  or `EzagentDomainUi.AdminShell.admin_shell/1` (`workspace://system`
  config).

  Stateless `Phoenix.Component` (Tier-2 — zero LiveView/registry deps,
  per the UI Contract). The `:command_palette` slot is filled by the
  Tier-3 `EzagentPluginLiveview.AppShell.app_shell/1`, which renders
  the stateful `CommandPaletteComponent` LiveComponent — keeping the
  stateful piece out of the stateless-atom layer (SPEC §3).

  Nested-shell PR-3 deleted the old monolithic `ide_shell/1` once its
  last consumer migrated; `ide_shell_outer/1` is now the sole shell
  entry point in this module.

  ## The `perspective` context contract (SPEC §2)

  `perspective :: :workspace | :admin` governs the header's left
  affordance — it is NOT cosmetic:

  - `:workspace` — left affordance is the `workspace_dropdown`
    (`ezagent / <workspace>`); switching workspace is meaningful.
  - `:admin` — admin pages are `workspace://system` global config.
    Left affordance is a plain system-context label (`ezagent ·
    System`), NOT the tenant workspace dropdown — you do not "switch
    workspace" while editing global runtime config.

  ## Usage

      <IdeShell.ide_shell_outer
        perspective={:workspace}
        current_entity_uri={@current_entity_uri}
        workspace_name={@workspace_name}
        workspaces={@workspaces}
        is_admin?={@is_admin?}
        is_system_member?={@is_system_member?}
      >
        <:command_palette>...</:command_palette>
        <:body>
          <WorkspaceShell.workspace_shell ...>...</WorkspaceShell.workspace_shell>
        </:body>
      </IdeShell.ide_shell_outer>
  """
  attr(:perspective, :atom,
    required: true,
    values: [:workspace, :admin],
    doc: """
    SPEC §2 context contract. `:workspace` → header shows the
    `workspace_dropdown`. `:admin` → header shows the plain
    `ezagent · System` label (no tenant workspace switcher).
    """
  )

  attr(:current_entity_uri, :any, required: true)
  attr(:workspace_name, :string, default: nil)
  attr(:workspaces, :list, default: [])
  attr(:is_admin?, :boolean, default: false)
  attr(:is_system_member?, :boolean, default: false)

  slot(:command_palette)
  slot(:body, required: true)

  def ide_shell_outer(assigns) do
    ~H"""
    <div
      id="ide-shell-outer"
      class="fixed inset-0 flex flex-col bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 text-sm font-sans"
    >
      <.outer_command_bar
        perspective={@perspective}
        current_entity_uri={@current_entity_uri}
        workspace_name={@workspace_name}
        workspaces={@workspaces}
        is_admin?={@is_admin?}
        is_system_member?={@is_system_member?}
      />

      {render_slot(@body)}

      {render_slot(@command_palette)}
    </div>
    """
  end

  # --- outer_command_bar -----------------------------------------------------

  @doc """
  Nested-shell PR-1 — the universal header for `ide_shell_outer/1`.

  Context affordance + search/⌘K trigger + bell + help + avatar menu.
  Differs from `top_command_bar/1` in that the left context affordance
  is driven by the `perspective` attr (SPEC §2):

  - `:workspace` → `workspace_dropdown` (always — empty-list state
    shows a placeholder row + the "Manage workspaces..." footer
    link, since the dropdown is the sole entry to `/workspaces`).
  - `:admin` → plain `ezagent · System` system-context label.

  It carries no resource-panel toggle — panel toggles belong to the
  inner `workspace_shell` body / status bar.
  """
  attr(:perspective, :atom, required: true, values: [:workspace, :admin])
  attr(:current_entity_uri, :any, required: true)
  attr(:workspace_name, :string, default: nil)
  attr(:workspaces, :list, default: [])
  attr(:is_admin?, :boolean, default: false)
  attr(:is_system_member?, :boolean, default: false)

  def outer_command_bar(assigns) do
    ~H"""
    <header class="h-10 border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 px-3 flex items-center gap-3 shrink-0">
      <%!-- SPEC §2 — context affordance. `:admin` shows a plain
            system-context label (you do not switch tenant workspace
            while editing global config); `:workspace` always shows
            the `workspace_dropdown` — even with an empty workspaces
            list, the dropdown is the only entry point to
            `/workspaces` (Activity Bar dropped its Workspaces tile
            in PR-L). Workspace-rename (#335) removed the seeded
            `default` workspace; first-time operators land here with
            `@workspaces == []` and MUST be able to reach
            "Manage workspaces..." to create the first one. --%>
      <%= if @perspective == :admin do %>
        <div class="flex items-center gap-2 shrink-0">
          <span class="font-semibold text-xs tracking-tight">ezagent</span>
          <span class="text-zinc-400 dark:text-zinc-600 select-none">·</span>
          <span class="text-xs text-zinc-600 dark:text-zinc-400">{gettext("System")}</span>
        </div>
      <% else %>
        <.workspace_dropdown
          workspace_name={@workspace_name}
          workspaces={@workspaces}
          is_system_member?={@is_system_member?}
        />
      <% end %>

      <%!-- search / ⌘K trigger — universal, present on every page. --%>
      <div class="flex-1 max-w-md mx-auto">
        <button
          type="button"
          phx-click={JS.dispatch("ezagent:open-command-palette")}
          class="w-full flex items-center gap-2 px-3 py-1.5 bg-zinc-100 dark:bg-zinc-900 hover:bg-zinc-200 dark:hover:bg-zinc-700 rounded-md text-xs text-zinc-500 transition-colors"
        >
          <.icon name="search" size="xs" />
          <span
            class="ez-typing-placeholder relative flex-1 text-left h-4 overflow-hidden"
            aria-live="polite"
          >
            <span class="ez-typing-line">{gettext("Search sessions")}</span>
            <span class="ez-typing-line">{gettext("Summon entity")}</span>
            <span class="ez-typing-line">{gettext("Run action")}</span>
            <span class="ez-typing-line">{gettext("Jump to routing")}</span>
          </span>
          <span class="ml-auto text-[10px] text-zinc-400 dark:text-zinc-600 font-mono">⌘K</span>
        </button>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <.icon
          name="bell"
          size="sm"
          class="text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 cursor-pointer"
        />
        <.icon
          name="help"
          size="sm"
          class="text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 cursor-pointer"
        />
        <.avatar_menu
          current_entity_uri={@current_entity_uri}
          is_admin?={@is_admin?}
        />
      </div>
    </header>
    """
  end

  # --- workspace_dropdown ----------------------------------------------------

  @doc """
  Top-left `ezagent / <workspace>` button + dropdown menu (Phase 8c
  PR-L, Allen 2026-05-20).

  Replaces the prior plain-text label in `top_command_bar/1` when the
  LV opts in by passing a non-empty `workspaces` list. Activity Bar
  dropped its Workspaces tile (5→4); workspace management is reached
  from this dropdown's "Manage workspaces..." link instead.

  Dropdown contents:
  - WORKSPACES caption header
  - One row per known workspace; the current one (matches
    `workspace_name`) shows a "current" badge and is not clickable.
    Other rows navigate to `/workspaces/<name>` (the workspace detail
    page) — "switching context" mid-session is a future flow.
  - Divider
  - "Manage workspaces..." link → `/workspaces`

  Uses the same `Phoenix.LiveView.JS.toggle/1` transition idiom as
  `avatar_menu/1` and the session_editor settings dropdown — no LV
  state needed since the menu is purely presentational.
  """
  attr(:workspace_name, :string, default: nil)
  attr(:workspaces, :list, required: true)

  attr(:is_system_member?, :boolean,
    default: false,
    doc: """
    Phase 9 PR-8 (SPEC v3 §13.2) — system-member callers see no lock
    indicator on non-current rows (clicking does a context swap with
    no logout). Regular users see a 🔒 lock badge on non-current
    rows; clicking still POSTs to /workspaces/switch but the
    controller renders the denial page.
    """
  )

  def workspace_dropdown(assigns) do
    assigns =
      assigns
      |> assign_new(:menu_id, fn -> "workspace-menu" end)

    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click={
          JS.toggle(
            to: "##{@menu_id}",
            in: {"ease-out duration-150", "opacity-0 -translate-y-1", "opacity-100 translate-y-0"},
            out: {"ease-in duration-100", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
          )
        }
        title={gettext("Switch workspace")}
        aria-label={gettext("Switch workspace")}
        class="flex items-center gap-2 px-1.5 py-1 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
      >
        <span class="font-semibold text-xs tracking-tight">ezagent</span>
        <span :if={@workspace_name} class="text-zinc-400 dark:text-zinc-600 select-none">/</span>
        <span
          :if={@workspace_name}
          class="font-mono text-xs text-zinc-600 dark:text-zinc-400"
        >
          {@workspace_name}
        </span>
        <.icon name="chevron-down" size="xs" class="text-zinc-400 dark:text-zinc-600" />
      </button>

      <%!-- Phase 8c follow-up (Allen 2026-05-20) — phx-click-away
            dismisses the menu when the user clicks anywhere outside.
            JS.hide mirrors the open transition reversed; popovers
            without this stay sticky after losing focus. --%>
      <div
        id={@menu_id}
        phx-click-away={
          JS.hide(
            transition: {"ease-in duration-100", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
          )
        }
        class="hidden absolute left-0 top-full mt-1 w-64 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-md shadow-lg z-40 transition transform"
      >
        <div class="px-3 py-2 border-b border-zinc-200 dark:border-zinc-800">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500">{gettext("Workspaces")}</div>
        </div>
        <div class="py-1 max-h-64 overflow-y-auto">
          <%!-- Empty-state placeholder (workspace-rename #335 follow-up,
                Allen 2026-05-25). After PR #335 deleted the seeded
                `default` workspace, fresh DBs and freshly-onboarded
                users land here with `@workspaces == []`. We keep the
                dropdown trigger visible (it's the sole entry to
                /workspaces — Activity Bar dropped its tile in PR-L)
                and show a placeholder row so the menu doesn't look
                broken; the "Manage workspaces..." footer link below
                stays reachable. --%>
          <%= if @workspaces == [] do %>
            <div class="px-3 py-3 text-xs text-zinc-500 dark:text-zinc-400 italic">
              {gettext("No workspaces yet")}
            </div>
          <% end %>
          <%= for ws <- @workspaces do %>
            <% ws_name = workspace_item_name(ws) %>
            <% current? = ws_name == @workspace_name %>
            <%= if current? do %>
              <div class="px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 flex items-center justify-between gap-2 bg-zinc-50 dark:bg-zinc-950">
                <span class="font-mono truncate">{ws_name}</span>
                <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded border bg-zinc-900 dark:bg-zinc-100 text-zinc-50 dark:text-zinc-900 border-zinc-900 dark:border-zinc-100 shrink-0">
                  {gettext("current")}
                </span>
              </div>
            <% else %>
              <%!-- Phase 9 PR-8 (SPEC v3 §6.4 amendment 3 + §13.2) —
                    permission-gated switch. System members get a
                    seamless context swap (no logout); regular users
                    get a denial page offering "Sign in to <ws>".
                    Both branches POST to /workspaces/switch — the
                    controller chooses the UX based on caller
                    membership. The lock icon is the operator-side
                    affordance: "you'll be asked to re-auth." --%>
              <form action="/workspaces/switch" method="post" class="block">
                <input
                  type="hidden"
                  name="_csrf_token"
                  value={Plug.CSRFProtection.get_csrf_token()}
                />
                <input type="hidden" name="workspace" value={ws_name} />
                <button
                  type="submit"
                  class={[
                    "w-full text-left px-3 py-1.5 text-xs flex items-center justify-between gap-2 hover:bg-zinc-100 dark:hover:bg-zinc-800",
                    if(@is_system_member?,
                      do: "text-zinc-700 dark:text-zinc-300",
                      else: "text-zinc-500 dark:text-zinc-400"
                    )
                  ]}
                  title={
                    if @is_system_member?,
                      do: gettext("Operate on workspace %{name}", name: ws_name),
                      else:
                        gettext(
                          "Sign in to workspace %{name} (you'll be asked to re-auth)",
                          name: ws_name
                        )
                  }
                >
                  <span class="font-mono truncate">{ws_name}</span>
                  <span
                    :if={not @is_system_member?}
                    class="text-[10px] text-zinc-400 dark:text-zinc-600 shrink-0"
                    aria-label={gettext("locked")}
                    title={gettext("You'll be asked to sign in to this workspace")}
                  >
                    🔒
                  </span>
                </button>
              </form>
            <% end %>
          <% end %>
        </div>
        <div class="border-t border-zinc-200 dark:border-zinc-800 py-1">
          <a
            href="/workspaces"
            class="block px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="folder" size="xs" /> {gettext("Manage workspaces...")}
          </a>
        </div>
      </div>
    </div>
    """
  end

  # Extract the workspace display name from whatever shape the LV passed.
  # Accepts: %{name: "..."} | %{uri: "workspace://name"} |
  # %{uri: %URI{host: "name"}} | %URI{host: "name"} | "workspace://name" |
  # "name". Robust to whichever source the LV pulls from (Workspace.Store
  # row vs WorkspaceRegistry vs hand-built map).
  defp workspace_item_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp workspace_item_name(%{uri: %URI{host: host}}) when is_binary(host), do: host
  defp workspace_item_name(%{uri: uri_str}) when is_binary(uri_str) do
    case URI.parse(uri_str) do
      %URI{host: host} when is_binary(host) -> host
      _ -> uri_str
    end
  end
  defp workspace_item_name(%URI{host: host}) when is_binary(host), do: host
  defp workspace_item_name(s) when is_binary(s) do
    case URI.parse(s) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> s
    end
  end
  defp workspace_item_name(_), do: "—"

  # --- avatar_menu -----------------------------------------------------------

  @doc """
  Right-corner avatar button + dropdown menu (Phase 8 polish #5,
  Allen 2026-05-20).

  Replaces the prior `<.uri_chip>` in `top_command_bar/1`. Dropdown
  shows Profile / Settings / Sign out links. Menu visibility is
  handled by `Phoenix.LiveView.JS.toggle/1` — no LV state needed
  because the menu is purely presentational.

  Tooltip on the avatar shows "Your profile".
  """
  attr(:current_entity_uri, :any, required: true)
  attr(:is_admin?, :boolean, default: false)

  def avatar_menu(assigns) do
    assigns =
      assigns
      |> assign_new(:menu_id, fn -> "avatar-menu" end)
      |> assign(:uri_str, format_uri_for_status(assigns.current_entity_uri))

    ~H"""
    <%!-- V1 UI fix (Allen 2026-05-22, 2nd attempt) — dropdown would not
          open. ROOT CAUSE: click-away race. `phx-click-away` was on the
          MENU div; the avatar button is a SIBLING (outside the menu).
          Clicking the button: (1) `phx-click` JS.toggle shows the menu,
          (2) the SAME click is "outside the menu" → menu's
          `phx-click-away` immediately JS.hide's it. Net: open→close in
          one tick, looks like it never opens.
          FIX: move `phx-click-away` to the WRAPPER div (clicks on the
          button + menu are now "inside" → no dismiss); the JS.hide
          action still targets the menu by id. Genuine outside clicks
          (outside the wrapper) still dismiss.
          Regression origin: the `phx-click-away` was added in Phase 8c
          (2026-05-20 "outside-click dismiss") onto the menu div — that
          is the commit that introduced the race. --%>
    <div class="relative" phx-click-away={JS.hide(to: "##{@menu_id}")}>
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@menu_id}", display: "block")}
        title={gettext("Your profile")}
        aria-label={gettext("Your profile")}
        class="flex items-center"
      >
        <.avatar uri={@current_entity_uri} size="sm" />
      </button>

      <%!-- z-50 (not z-40): the right sidebar panel is z-40 and later in
            the DOM, so a z-40 menu paints BEHIND it — the avatar dropdown
            overlaps the Members panel on the right edge and was fully
            occluded. z-50 (same tier as the command palette) clears all
            z-40 chrome. Third + final piece of the 2026-05-22 avatar fix:
            (1) plain JS.toggle, (2) click-away on wrapper, (3) this. --%>
      <div
        id={@menu_id}
        class="hidden absolute right-0 top-full mt-1 w-64 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-md shadow-lg z-50"
      >
        <div class="px-3 py-3 border-b border-zinc-200 dark:border-zinc-800 flex items-center gap-2">
          <.avatar uri={@current_entity_uri} size="md" />
          <div class="flex-1 min-w-0">
            <div class="font-mono text-[11px] text-zinc-700 dark:text-zinc-300 truncate">
              {@uri_str}
            </div>
            <div class="flex items-center gap-1 text-[10px] text-zinc-500 mt-0.5">
              <.status_dot color="green" />
              <span>{gettext("online")}</span>
            </div>
          </div>
        </div>
        <div class="py-1">
          <a
            href="/profile"
            class="block px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            {gettext("Profile")}
          </a>
          <%!-- V1 fix (Allen Feishu 2026-05-21 17:44) — the former
                "Preferences" link (→ /settings) was REMOVED. Its
                target page hosted admin-only config (SMTP +
                registration domains), so it was migrated to
                /admin/settings and lives in the admin drawer
                (AdminShell sidebar) below. Personal-config settings
                (display name + avatar) stay on /profile. --%>
          <%!-- Phase 8c PR-F (Allen 2026-05-20) — Admin link opens the
                admin drawer (system layer of the 3-layer
                architecture). Gated on `Ezagent.Identity.admin?/1`;
                hidden for non-admin entities for UX clarity.
                TODO Phase 8d: replace with proper cap:admin check
                once /admin enforces admin caps at the route gate. --%>
          <a
            :if={@is_admin?}
            href="/admin"
            class="block px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="settings" size="xs" /> {gettext("Admin")}
          </a>
        </div>
        <%!-- Phase 8c PR-C: dark mode toggle. daisyUI infrastructure
              already exists in root.html.heex (data-theme + localStorage +
              a window listener for `phx:set-theme`). Each button
              dispatches that event with its `data-phx-theme` payload. --%>
        <div class="border-t border-zinc-200 dark:border-zinc-800 py-1">
          <button
            type="button"
            data-phx-theme="light"
            phx-click={JS.dispatch("phx:set-theme")}
            class="w-full text-left px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="sun" size="xs" /> {gettext("Light theme")}
          </button>
          <button
            type="button"
            data-phx-theme="dark"
            phx-click={JS.dispatch("phx:set-theme")}
            class="w-full text-left px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="moon" size="xs" /> {gettext("Dark theme")}
          </button>
          <button
            type="button"
            data-phx-theme="system"
            phx-click={JS.dispatch("phx:set-theme")}
            class="w-full text-left px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="settings" size="xs" /> {gettext("System")}
          </button>
        </div>
        <div class="border-t border-zinc-200 dark:border-zinc-800 py-1">
          <form action="/logout" method="post" class="block">
            <input
              type="hidden"
              name="_csrf_token"
              value={Plug.CSRFProtection.get_csrf_token()}
            />
            <button
              type="submit"
              class="w-full text-left px-3 py-1.5 text-xs text-rose-600 dark:text-rose-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              {gettext("Sign out")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # --- format_uri_for_status -------------------------------------------------
  #
  # Shared URI display helper. Still used by `avatar_menu/1` (the
  # header chrome `ide_shell_outer/1` renders). The old `status_bar/1`
  # that also used it was a body helper of the deleted monolithic
  # `ide_shell/1` (nested-shell PR-3) — its replacement now lives in
  # `EzagentDomainUi.WorkspaceShell`.

  defp format_uri_for_status(%URI{} = uri), do: URI.to_string(uri)
  defp format_uri_for_status(s) when is_binary(s), do: s
  defp format_uri_for_status(nil), do: "—"
  defp format_uri_for_status(_), do: "—"

  # --- editor_tabs -----------------------------------------------------------

  @doc """
  Tab strip at the top of Main Window.

      <.editor_tabs items={[{:session, "main"}, {:terminal, "cc_demo"}]} selected={:session} />
  """
  attr(:items, :list, required: true)
  attr(:selected, :any, required: true)
  attr(:on_select, :string, default: "select_editor_tab")
  attr(:on_close, :string, default: "close_editor_tab")

  def editor_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-px border-b border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 px-2 shrink-0">
      <div
        :for={{key, label} <- @items}
        class={[
          "flex items-center gap-1 px-3 py-1.5 text-xs font-medium border-b-2 cursor-pointer",
          (to_string(key) == to_string(@selected) &&
             "border-zinc-900 dark:border-zinc-100 text-zinc-900 dark:text-zinc-100 bg-white dark:bg-zinc-900") ||
            "border-transparent text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
        ]}
        phx-click={@on_select}
        phx-value-key={inspect(key)}
      >
        <span>{label}</span>
        <button
          type="button"
          phx-click={@on_close}
          phx-value-key={inspect(key)}
          class="opacity-50 hover:opacity-100 text-[10px]"
        >
          ✕
        </button>
      </div>
    </div>
    """
  end

  # --- split_pane ------------------------------------------------------------

  @doc """
  Optional vertical or horizontal split between two slots.
  """
  attr(:open, :boolean, default: false)
  attr(:direction, :string, default: "vertical", values: ~w(vertical horizontal))
  slot(:primary, required: true)
  slot(:secondary)

  def split_pane(assigns) do
    ~H"""
    <div class={[
      "flex flex-1 min-h-0 min-w-0",
      (@direction == "vertical" && "flex-row") || "flex-col"
    ]}>
      <div class={[
        "flex-1 min-h-0 min-w-0",
        @open && @secondary != [] && "border-r border-zinc-200 dark:border-zinc-800"
      ]}>
        {render_slot(@primary)}
      </div>
      <div
        :if={@open && @secondary != []}
        class="flex-1 min-h-0 min-w-0"
      >
        {render_slot(@secondary)}
      </div>
    </div>
    """
  end

  # --- command_palette -------------------------------------------------------

  @doc """
  Command palette modal — triggered by ⌘K or CmdK button in TopCommandBar.
  """
  attr(:open, :boolean, default: false)
  attr(:query, :string, default: "")
  attr(:results, :list, default: [])

  def command_palette(assigns) do
    ~H"""
    <div
      id="command-palette"
      class={[
        "fixed inset-0 z-50 flex items-start justify-center pt-20",
        not @open && "hidden"
      ]}
      phx-window-keydown="close_command_palette"
      phx-key="escape"
    >
      <div
        class="absolute inset-0 bg-zinc-900/40 backdrop-blur-sm"
        phx-click="close_command_palette"
      />
      <div class="relative z-10 w-full max-w-xl mx-4 bg-white dark:bg-zinc-900 rounded-lg shadow-2xl overflow-hidden">
        <form phx-change="command_query" phx-submit="command_select">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search sessions / entities / actions ...")}
            autocomplete="off"
            autofocus
            class="w-full px-4 py-3 text-sm border-b border-zinc-200 dark:border-zinc-800 focus:outline-none"
          />
        </form>
        <div class="max-h-96 overflow-y-auto">
          <div :if={@results == []} class="px-4 py-8 text-center text-xs text-zinc-500">
            {(@query == "" && gettext("Type to start searching")) || gettext("No results")}
          </div>
          <button
            :for={r <- @results}
            type="button"
            phx-click="command_select_result"
            phx-value-key={r.key}
            class="w-full px-4 py-2 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2 border-b border-zinc-100 dark:border-zinc-900"
          >
            <.icon name={r.icon || "dot"} size="xs" />
            <span class="font-mono">{r.label}</span>
            <span
              :if={Map.get(r, :group)}
              class="ml-auto text-[10px] text-zinc-400 dark:text-zinc-600 uppercase"
            >
              {r.group}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
