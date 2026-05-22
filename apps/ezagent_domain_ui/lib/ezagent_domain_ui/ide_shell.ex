defmodule EzagentDomainUi.IdeShell do
  @moduledoc """
  Phase 8 — Agent IDE Shell layout components.

  Stateless Phoenix.Component layout primitives that wrap any LiveView
  in the IDE-style Activity Bar / Resource Panel / Top Command Bar /
  Main Window / Right Sidebar / Status Bar topology.

  Per Phase 8 spec §2 decision D1, these are functional components,
  not LiveComponents. State (which Activity is active, what's in the
  resource panel, etc.) is owned by the wrapping LiveView and passed
  down as attrs.

  Per decision D2, the active Activity is derived from the current URL,
  not socket state. Use `EzagentDomainUi.IdeShell.activity_for_path/1`
  to compute it.

  Phase 8 polish (Allen 2026-05-20):
  - 4 Activity items (Settings moved under the avatar dropdown; Dashboard
    dropped in PR-F because /admin is now a settings-drawer perspective,
    not a peer workflow; Workspaces folded into the top-left dropdown in
    PR-L because workspace is a context container, not a feature surface).
  - Top bar shows `ezagent / <workspace>` (workspace derived from the
    current session's bound workspace via `Ezagent.WorkspaceRegistry`).
    When the LV passes a non-empty `workspaces` list, the label becomes a
    clickable dropdown listing every workspace + a "Manage workspaces..."
    link to `/workspaces`.
  - Business routes live at top level (`/sessions`, `/identities`,
    `/routing`, `/plugins`). `/workspaces` still routes — it's reached
    via the top-left dropdown. `/admin/*` is rendered by
    `EzagentDomainUi.AdminSettingsShell` (no Activity Bar, no status bar).

  ## Usage

      <.ide_shell
        current_entity_uri={@current_entity_uri}
        current_path={@socket.assigns.current_path}
        status={@status}
      >
        <:resource_panel>
          <.tree_list>...</.tree_list>
        </:resource_panel>
        <:main_window>
          <.editor_tabs items={@tabs} selected={@active_tab} />
          ... main content ...
        </:main_window>
        <:right_sidebar>
          <.member_roster members={@members} />
        </:right_sidebar>
      </.ide_shell>
  """

  use Phoenix.Component
  use EzagentDomainUi.Primitives
  alias Phoenix.LiveView.JS

  # --- ide_shell -------------------------------------------------------------

  attr(:current_entity_uri, :any, required: true)
  attr(:current_path, :string, required: true)
  attr(:status, :map, default: %{})

  attr(:workspace_name, :string,
    default: nil,
    doc: """
    Phase 8c PR-F (Allen 2026-05-20) — workspace name to display in the
    top-left as `ezagent / <workspace_name>`. `nil` means no workspace
    context, in which case top-left shows just `ezagent`.

    LVs compute this from `Ezagent.WorkspaceRegistry.lookup(session_uri)`
    and pass it through. Default `nil` keeps backward compat for any LV
    that doesn't need workspace context.
    """
  )

  attr(:workspaces, :list,
    default: [],
    doc: """
    Phase 8c PR-L (Allen 2026-05-20) — list of known workspaces, used
    to populate the top-left `ezagent / <workspace>` dropdown. Each item
    is a map `%{name: String.t(), uri: String.t() | URI.t()}`.

    When the list is non-empty, the top-left chrome becomes a clickable
    dropdown listing every workspace + a "Manage workspaces..." link to
    `/workspaces`. When empty (the default), the chrome stays plain
    text — non-admin surfaces don't need the dropdown affordance.

    Only `admin_live` (the sessions surface) currently opts in.
    """
  )

  attr(:is_admin?, :boolean,
    default: false,
    doc: """
    Phase 8c PR-F (Allen 2026-05-20) — whether the current entity is an
    admin. Controls visibility of the "Admin" link in the avatar
    dropdown. Default `false` is the safe non-admin fallback.

    LVs compute this via `Ezagent.Identity.admin?/1` and pass it in.
    Threaded as an attr (rather than computed inside this component)
    because ezagent_domain_ui is a pure UI library — it doesn't depend
    on ezagent_domain_identity.
    """
  )

  attr(:is_system_member?, :boolean,
    default: false,
    doc: """
    Phase 9 PR-8 (SPEC v3 §13.3) — whether the current entity is a
    member of `workspace://system`. Controls the workspace dropdown's
    affordance for non-current rows:

    - System member → all rows clickable, no lock indicator;
      clicking POSTs `/workspaces/switch` and gets a context-swap
      with no logout.
    - Regular user → other workspaces are visually locked AND still
      clickable (they hit the controller-rendered denial page that
      offers a "Sign in to <ws>" prompt).

    Computed by `EzagentWeb.LiveAuth.on_mount/4` from the caller URI
    + workspace, threaded as an attr like `is_admin?`.
    """
  )

  slot(:resource_panel)
  slot(:main_window, required: true)
  slot(:right_sidebar)
  slot(:command_palette)

  def ide_shell(assigns) do
    ~H"""
    <div
      id="ide-shell"
      class="fixed inset-0 flex flex-col bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 text-sm font-sans"
    >
      <.top_command_bar
        current_entity_uri={@current_entity_uri}
        workspace_name={@workspace_name}
        workspaces={@workspaces}
        is_admin?={@is_admin?}
        is_system_member?={@is_system_member?}
        has_resource_panel={@resource_panel != []}
      />

      <div class="flex-1 flex min-h-0 relative">
        <.activity_bar current_path={@current_path} />

        <%!-- V1 UI fix (Allen 2026-05-21) — mobile-responsive side
              panels with desktop-safe toggle behavior.

              On `lg+` (≥1024px): both panels render inline (`lg:static`
              + `lg:block`) at their fixed widths.

              Below `lg`: both panels default to `hidden`; toggle buttons
              in `top_command_bar` flip visibility via `JS.toggle`. When
              shown on mobile, the panel becomes a fixed-position overlay
              anchored to the viewport edge (top: header height, bottom:
              status bar height).

              REMOVED `phx-click-away={JS.hide(...)}`:
              - JS.hide writes inline `style="display:none"` which beats
                `lg:block` CSS at any breakpoint. On desktop this caused
                the sidebar to vanish on any outside-click with no way to
                recover (the `lg:hidden` toggle button was invisible).
              - Bug report: Allen Feishu 2026-05-21 — right sidebar
                (Members) auto-hides on /sessions page, no reopen button.
              - Toggle buttons in `top_command_bar` are now always visible
                (not `lg:hidden`) so the user can intentionally toggle
                either panel on desktop too.
              - `display: "block"` option on JS.toggle ensures the show
                side restores `display: block` (matches `lg:block` intent
                so the panel reappears at its inline-on-desktop / overlay-
                on-mobile state). --%>

        <div
          :if={@resource_panel != []}
          id="left-resource-panel"
          class="hidden lg:block lg:static fixed top-10 bottom-6 left-12 z-40 w-56 max-w-[80vw] border-r border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-y-auto shadow-xl lg:shadow-none"
        >
          {render_slot(@resource_panel)}
        </div>

        <div class="flex-1 flex flex-col min-w-0 bg-white dark:bg-zinc-900">
          {render_slot(@main_window)}
        </div>

        <div
          :if={@right_sidebar != []}
          id="right-sidebar"
          class="hidden lg:block lg:static fixed top-10 bottom-6 right-0 z-40 w-72 max-w-[80vw] border-l border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-y-auto shadow-xl lg:shadow-none"
        >
          {render_slot(@right_sidebar)}
        </div>
      </div>

      <.status_bar
        current_entity_uri={@current_entity_uri}
        status={@status}
        has_right_sidebar={@right_sidebar != []}
      />

      {render_slot(@command_palette)}
    </div>
    """
  end

  # --- activity_bar ----------------------------------------------------------

  @doc """
  Vertical icon strip on the left edge. 4 top-level Activities (PR-F:
  Dashboard removed — /admin is now a settings drawer rendered by
  `EzagentDomainUi.AdminSettingsShell`, not a peer Activity. PR-L:
  Workspaces removed — workspace is a context container, folded into
  the top-left `ezagent / <workspace>` dropdown).
  """
  attr(:current_path, :string, required: true)

  def activity_bar(assigns) do
    items = activity_items()
    active_key = activity_for_path(assigns.current_path)
    assigns = assign(assigns, :items, items) |> assign(:active_key, active_key)

    ~H"""
    <nav class="w-12 border-r border-zinc-200 dark:border-zinc-800 bg-zinc-100 dark:bg-zinc-900 flex flex-col items-center py-2 gap-1">
      <a
        :for={item <- @items}
        href={item.path}
        class={[
          "relative w-10 h-10 flex items-center justify-center rounded-md transition-colors",
          (item.key == @active_key &&
             "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100") ||
            "text-zinc-500 hover:bg-zinc-200 dark:hover:bg-zinc-700 hover:text-zinc-700 dark:hover:text-zinc-300"
        ]}
        title={item.label}
        aria-label={item.label}
      >
        <%!-- Phase 8c PR-C: signature accent — burnt orange left rail on
              the active Activity. Sharp accent vs the otherwise neutral
              palette (per skill: "Dominant colors with sharp accents
              outperform timid, evenly-distributed palettes"). --%>
        <span
          :if={item.key == @active_key}
          class="absolute left-0 top-1.5 bottom-1.5 w-0.5 rounded-r bg-orange-600"
          aria-hidden="true"
        />
        <.icon name={item.icon} size="md" />
      </a>
    </nav>
    """
  end

  @doc """
  List of all 4 Activity Bar items in display order.

  Phase 8c PR-F (2026-05-20): Dashboard removed — /admin is no longer
  a peer Activity (it conflated "permission/role" with "workflow"
  dimensions). It is now a settings-drawer perspective opened from
  the avatar dropdown and rendered by `EzagentDomainUi.AdminSettingsShell`.

  Phase 8c PR-L (2026-05-20): Workspaces removed — workspace is a
  deployment-unit / context concept, not a feature workflow. Placing
  /workspaces in Activity Bar peer-with Sessions/Identities/Routing/Plugins
  muddled the "context container" vs "feature surface" distinction.
  Workspace context lives in the top-left chrome (`ezagent / <name>`)
  and reaches the management page via dropdown link.

  The 4 items are pure feature surfaces: Sessions / Identities /
  Routing / Plugins.
  """
  def activity_items do
    [
      %{key: :sessions, label: "Sessions", icon: "message-square", path: "/sessions"},
      %{key: :identities, label: "Identities", icon: "users", path: "/identities"},
      %{key: :routing, label: "Routing", icon: "route", path: "/routing"},
      %{key: :plugins, label: "Plugins", icon: "puzzle", path: "/plugins"}
    ]
  end

  @doc """
  Compute which Activity is "active" based on the current path.

  Returns `nil` for `/admin*` paths — the admin drawer renders inside
  `EzagentDomainUi.AdminSettingsShell` which has no Activity Bar, so
  no Activity should be highlighted when the admin surface is open.

  Returns `nil` for `/workspaces*` paths (PR-L) — workspaces are no
  longer a top-level Activity. The WorkspacesLive page still renders
  (reachable via the top-left "Manage workspaces..." dropdown link),
  but the Activity Bar shows no highlighted item while it's open.

  Examples:

      iex> activity_for_path("/sessions")
      :sessions

      iex> activity_for_path("/workspaces/demo")
      nil

      iex> activity_for_path("/admin/logs")
      nil
  """
  def activity_for_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/sessions") -> :sessions
      String.starts_with?(path, "/workspaces") -> nil
      String.starts_with?(path, "/identities") -> :identities
      String.starts_with?(path, "/routing") -> :routing
      String.starts_with?(path, "/plugins") -> :plugins
      String.starts_with?(path, "/admin") -> nil
      String.starts_with?(path, "/profile") -> :sessions
      # V1 fix (Allen Feishu 2026-05-21 17:44): /settings was migrated
      # to /admin/settings — that branch is caught by the /admin clause
      # above (no Activity highlight, drawer perspective).
      true -> :sessions
    end
  end

  def activity_for_path(_), do: :sessions

  # --- top_command_bar -------------------------------------------------------

  attr(:current_entity_uri, :any, required: true)
  attr(:workspace_name, :string, default: nil)
  attr(:workspaces, :list, default: [])
  attr(:is_admin?, :boolean, default: false)
  attr(:is_system_member?, :boolean, default: false)

  attr(:has_resource_panel, :boolean,
    default: false,
    doc: "Phase 8c follow-up — mobile toggle button for the left resource panel renders when this is true."
  )

  # NOTE: the right-sidebar (Members) toggle moved OUT of the header
  # into status_bar/1 — V1 UI fix (Allen 2026-05-22) — per the
  # header/statusbar separation principle (see SKILL.md UI Contract).

  def top_command_bar(assigns) do
    ~H"""
    <header class="h-10 border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 px-3 flex items-center gap-3 shrink-0">
      <%!-- V1 UI fix (Allen 2026-05-21) — toggle button for the left
            resource panel. Visible on BOTH mobile AND desktop so the
            user can intentionally re-show the panel if it gets hidden
            (the prior `lg:hidden` left desktop users stranded when the
            panel went away — see ide_shell main layout comment).

            `display: "block"` makes JS.toggle's show-side write
            `display:block` (matches `lg:block` intent — panel reappears
            at its inline-on-desktop / overlay-on-mobile state). --%>
      <button
        :if={@has_resource_panel}
        type="button"
        phx-click={JS.toggle(to: "#left-resource-panel", display: "block")}
        class="p-1 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-500"
        title="Toggle resource panel"
        aria-label="Toggle resource panel"
      >
        <.icon name="folder" size="sm" />
      </button>
      <%!-- Phase 8c PR-F (Allen 2026-05-20) — workspace label in the
            top-left. Format: `ezagent / <workspace>` when a workspace
            is in scope; bare `ezagent` otherwise.

            Phase 8c PR-L (Allen 2026-05-20) — when the LV passes a
            non-empty `workspaces` list, the label becomes a clickable
            dropdown button (Activity Bar 5→4 dropped the Workspaces
            tile in favor of this dropdown). When `workspaces` is empty
            (the default), the chrome stays as plain text — non-admin
            surfaces don't need the dropdown affordance. --%>
      <%= if @workspaces != [] do %>
        <.workspace_dropdown
          workspace_name={@workspace_name}
          workspaces={@workspaces}
          is_system_member?={@is_system_member?}
        />
      <% else %>
        <div class="flex items-center gap-2 shrink-0">
          <span class="font-semibold text-xs tracking-tight">ezagent</span>
          <span :if={@workspace_name} class="text-zinc-400 dark:text-zinc-600 select-none">/</span>
          <span
            :if={@workspace_name}
            class="font-mono text-xs text-zinc-600 dark:text-zinc-400"
          >
            {@workspace_name}
          </span>
        </div>
      <% end %>

      <%!-- Phase 8c PR-D — cycling typing-animation placeholder. 4
            prompts rotate every 3s for a 12s total cycle. Pure CSS:
            4 stacked spans, all but the active one transparent, with
            staggered `opacity` keyframes. No JS hook, no LV state.
            `aria-live="polite"` so screen readers announce changes
            gracefully. --%>
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
            <span class="ez-typing-line">搜索 sessions</span>
            <span class="ez-typing-line">召唤 entity</span>
            <span class="ez-typing-line">执行 action</span>
            <span class="ez-typing-line">跳转 routing</span>
          </span>
          <span class="ml-auto text-[10px] text-zinc-400 dark:text-zinc-600 font-mono">⌘K</span>
        </button>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <%!-- V1 UI fix (Allen 2026-05-22) — header/statusbar separation
              principle: the header shows WORKSPACE-level info that does
              NOT change with the user's current view. View-/position-
              related controls (like the Members-panel toggle) belong in
              the status bar. The Members toggle moved to status_bar/1.
              bell + help + avatar stay — those are workspace/account
              scoped, not position-scoped. --%>
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
        title="Switch workspace"
        aria-label="Switch workspace"
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
          <div class="text-[10px] uppercase tracking-wide text-zinc-500">Workspaces</div>
        </div>
        <div class="py-1 max-h-64 overflow-y-auto">
          <%= for ws <- @workspaces do %>
            <% ws_name = workspace_item_name(ws) %>
            <% current? = ws_name == @workspace_name %>
            <%= if current? do %>
              <div class="px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 flex items-center justify-between gap-2 bg-zinc-50 dark:bg-zinc-950">
                <span class="font-mono truncate">{ws_name}</span>
                <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded border bg-zinc-900 dark:bg-zinc-100 text-zinc-50 dark:text-zinc-900 border-zinc-900 dark:border-zinc-100 shrink-0">
                  current
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
                      do: "Operate on workspace " <> ws_name,
                      else: "Sign in to workspace " <> ws_name <> " (you'll be asked to re-auth)"
                  }
                >
                  <span class="font-mono truncate">{ws_name}</span>
                  <span
                    :if={not @is_system_member?}
                    class="text-[10px] text-zinc-400 dark:text-zinc-600 shrink-0"
                    aria-label="locked"
                    title="You'll be asked to sign in to this workspace"
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
            <.icon name="folder" size="xs" /> Manage workspaces...
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
        title="Your profile"
        aria-label="Your profile"
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
              <span>online</span>
            </div>
          </div>
        </div>
        <div class="py-1">
          <a
            href="/profile"
            class="block px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            Profile
          </a>
          <%!-- V1 fix (Allen Feishu 2026-05-21 17:44) — the former
                "Preferences" link (→ /settings) was REMOVED. Its
                target page hosted admin-only config (SMTP +
                registration domains), so it was migrated to
                /admin/settings and lives in the admin drawer
                (AdminSettingsShell sidebar) below. Personal-config
                settings (display name + avatar) stay on /profile. --%>
          <%!-- Phase 8c PR-F (Allen 2026-05-20) — Admin link opens the
                AdminSettingsShell drawer (system layer of the 3-layer
                architecture). Gated on `Ezagent.Identity.admin?/1`;
                hidden for non-admin entities for UX clarity.
                TODO Phase 8d: replace with proper cap:admin check
                once /admin enforces admin caps at the route gate. --%>
          <a
            :if={@is_admin?}
            href="/admin"
            class="block px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="settings" size="xs" /> Admin
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
            <.icon name="sun" size="xs" /> Light theme
          </button>
          <button
            type="button"
            data-phx-theme="dark"
            phx-click={JS.dispatch("phx:set-theme")}
            class="w-full text-left px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="moon" size="xs" /> Dark theme
          </button>
          <button
            type="button"
            data-phx-theme="system"
            phx-click={JS.dispatch("phx:set-theme")}
            class="w-full text-left px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2"
          >
            <.icon name="settings" size="xs" /> System
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
              Sign out
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # --- status_bar ------------------------------------------------------------

  attr(:current_entity_uri, :any, required: true)
  attr(:status, :map, default: %{})

  attr(:has_right_sidebar, :boolean,
    default: false,
    doc:
      "When true, render the Members-panel toggle in the status bar. " <>
        "Per the header/statusbar separation principle (Allen 2026-05-22): " <>
        "view-/position-related controls live in the status bar, not the header."
  )

  def status_bar(assigns) do
    # Phase 8c PR-B (Allen 2026-05-20) — state-aware signal lights.
    # The bar should communicate health at a glance: green when something
    # is alive and OK, gray when zero (the resting state), amber when
    # something needs attention.
    agents = Map.get(assigns.status, :agents_alive, 0)
    bridges = Map.get(assigns.status, :bridges, 0)
    events = Map.get(assigns.status, :debug_events, 0)

    assigns =
      assigns
      |> assign(:agents_count, agents)
      |> assign(:bridges_count, bridges)
      |> assign(:events_count, events)
      |> assign(:agents_color, if(agents > 0, do: "green", else: "gray"))
      |> assign(:bridges_color, if(bridges > 0, do: "green", else: "gray"))
      |> assign(:events_color, if(events > 0, do: "amber", else: "gray"))

    ~H"""
    <footer class="h-6 border-t border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 px-3 flex items-center gap-4 text-[11px] text-zinc-600 dark:text-zinc-400 shrink-0">
      <span class="flex items-center gap-1">
        <.icon name="users" size="xs" />
        <span class="font-mono">{format_uri_for_status(@current_entity_uri)}</span>
      </span>
      <span :if={Map.get(@status, :session_uri)} class="flex items-center gap-1">
        <.icon name="message-square" size="xs" />
        <span class="font-mono">{format_uri_for_status(@status.session_uri)}</span>
      </span>
      <span class="flex items-center gap-1">
        <.status_dot color={@agents_color} />
        <span>{@agents_count} agents</span>
      </span>
      <span class="flex items-center gap-1">
        <.status_dot color={@bridges_color} />
        <span>{@bridges_count} bridges</span>
      </span>
      <a
        href="/admin/logs"
        class="flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100 ml-auto"
      >
        <.icon name="bug" size="xs" />
        <span class={(@events_color == "amber" && "text-amber-700 dark:text-amber-300") || ""}>
          {@events_count} events
        </span>
      </a>
      <%!-- V1 UI fix (Allen 2026-05-22) — Members-panel toggle. Lives in
            the status bar (not the header) because it's a view-/position-
            related control — see the header/statusbar separation
            principle in SKILL.md UI Contract. --%>
      <button
        :if={@has_right_sidebar}
        type="button"
        phx-click={JS.toggle(to: "#right-sidebar", display: "block")}
        class="flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100"
        title="Toggle members panel"
        aria-label="Toggle members panel"
      >
        <.icon name="users" size="xs" />
        <span>members</span>
      </button>
      <span class="font-mono text-zinc-400 dark:text-zinc-600">
        v{Map.get(@status, :version, "dev")}
      </span>
    </footer>
    """
  end

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
            placeholder="搜索 sessions / entities / actions ..."
            autocomplete="off"
            autofocus
            class="w-full px-4 py-3 text-sm border-b border-zinc-200 dark:border-zinc-800 focus:outline-none"
          />
        </form>
        <div class="max-h-96 overflow-y-auto">
          <div :if={@results == []} class="px-4 py-8 text-center text-xs text-zinc-500">
            {(@query == "" && "输入开始搜索") || "没有结果"}
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
