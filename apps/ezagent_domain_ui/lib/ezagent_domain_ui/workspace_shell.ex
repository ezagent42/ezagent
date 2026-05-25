defmodule EzagentDomainUi.WorkspaceShell do
  @moduledoc """
  Nested-shell refactor PR-1 (SPEC §1, §6 row 1) — the workspace
  perspective BODY.

  Stateless `Phoenix.Component` (Tier-2, `ezagent_domain_ui` — zero
  LiveView/registry deps). This is today's `EzagentDomainUi.IdeShell.ide_shell`
  BODY — Activity Bar + Resource Panel + Main Window + Right Sidebar +
  Status Bar — with the universal header REMOVED.

  Per the nested-shell SPEC §1, the universal header (workspace
  dropdown / search-⌘K / bell / help / avatar) now lives in the
  OUTER shell (`IdeShell.ide_shell_outer/1`). `workspace_shell/1` is
  ONE of the two inner perspectives the outer shell's `:body` slot
  hosts; `admin_shell/1` is the other.

  PR-1 is purely additive — the old monolithic `ide_shell/1` is left
  intact and keeps working until its consumers migrate (PR-2). This
  component is a faithful COPY of that body region (restructure, not
  redesign).

  Status bar + Activity Bar are internal to this component (not slots)
  — they are workspace-perspective chrome, always present on a
  workspace surface.

  ## Usage

      <WorkspaceShell.workspace_shell
        current_entity_uri={@current_entity_uri}
        current_path="/sessions"
        status={@status}
      >
        <:resource_panel>
          <.tree_list>...</.tree_list>
        </:resource_panel>
        <:main_window>
          ... main content ...
        </:main_window>
        <:right_sidebar>
          <.member_roster members={@members} />
        </:right_sidebar>
      </WorkspaceShell.workspace_shell>
  """

  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend. NOT a
  # dependency on `ezagent_web` (see `EzagentDomainUi.Gettext` moduledoc).
  use Gettext, backend: EzagentDomainUi.Gettext
  use EzagentDomainUi.Primitives
  alias Phoenix.LiveView.JS

  # --- workspace_shell -------------------------------------------------------

  attr(:current_entity_uri, :any, required: true)
  attr(:current_path, :string, required: true)
  attr(:status, :map, default: %{})

  slot(:resource_panel)
  slot(:main_window, required: true)
  slot(:right_sidebar)

  def workspace_shell(assigns) do
    ~H"""
    <div
      id="workspace-shell"
      class="flex-1 flex flex-col min-h-0 bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 text-sm font-sans"
    >
      <div class="flex-1 flex min-h-0 relative">
        <.activity_bar current_path={@current_path} />

        <%!-- Nested-shell PR-1: this body markup is a faithful copy of
              the V1 ide_shell body (Allen 2026-05-21 mobile-responsive
              side panels). On `lg+` both panels render inline; below
              `lg` they default `hidden` and become fixed overlays
              toggled by the outer-shell / status-bar buttons. No
              `phx-click-away` on the panels — JS.hide's inline
              `display:none` beats `lg:block` on desktop. --%>

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
    </div>
    """
  end

  # --- activity_bar ----------------------------------------------------------

  @doc """
  Vertical icon strip on the left edge. 4 top-level Activities
  (Sessions / Identities / Routing / Plugins). Internal to the
  workspace perspective.

  Copy of `EzagentDomainUi.IdeShell.activity_bar/1` (nested-shell PR-1).
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
  List of the 3 Activity Bar items in display order: Sessions /
  Identities / Plugins.

  Copy of `EzagentDomainUi.IdeShell.activity_items/0` (nested-shell PR-1).

  2026-05-25 — Routing tile dropped from the workspace activity bar.
  Routing-rule mutation is admin-scope (moved to `/admin/routing`);
  per-session routing lives in the Session view-switcher
  (`EzagentDomainUi.Routing.RoutingView`). Same precedent as the
  Workspaces tile drop (PR-L).
  """
  def activity_items do
    [
      %{key: :sessions, label: gettext("Sessions"), icon: "message-square", path: "/sessions"},
      %{key: :identities, label: gettext("Identities"), icon: "users", path: "/identities"},
      %{key: :plugins, label: gettext("Plugins"), icon: "puzzle", path: "/plugins"}
    ]
  end

  @doc """
  Compute which Activity is "active" based on the current path.

  Returns `nil` for `/admin*` and `/workspaces*` paths. Copy of
  `EzagentDomainUi.IdeShell.activity_for_path/1` (nested-shell PR-1).

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
      String.starts_with?(path, "/plugins") -> :plugins
      # /routing was relocated to /admin/routing on 2026-05-25; the
      # tile was dropped from the activity bar. Falls through to the
      # `/admin*` clause below which returns nil (admin paths don't
      # highlight any workspace activity).
      String.starts_with?(path, "/admin") -> nil
      String.starts_with?(path, "/profile") -> :sessions
      true -> :sessions
    end
  end

  def activity_for_path(_), do: :sessions

  # --- status_bar ------------------------------------------------------------

  @doc """
  Bottom status bar — position-scoped, view-VARIANT chrome (current
  entity URI + session URI + agents/bridges signal lights + events
  link + Members-panel toggle).

  Copy of `EzagentDomainUi.IdeShell.status_bar/1` (nested-shell PR-1).
  Internal to the workspace perspective.
  """
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
        <span>{gettext("%{count} agents", count: @agents_count)}</span>
      </span>
      <span class="flex items-center gap-1">
        <.status_dot color={@bridges_color} />
        <span>{gettext("%{count} bridges", count: @bridges_count)}</span>
      </span>
      <a
        href="/admin/logs"
        class="flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100 ml-auto"
      >
        <.icon name="bug" size="xs" />
        <span class={(@events_color == "amber" && "text-amber-700 dark:text-amber-300") || ""}>
          {gettext("%{count} events", count: @events_count)}
        </span>
      </a>
      <%!-- Members-panel toggle — a view-/position-related control, so
            it lives in the status bar (header/statusbar separation
            principle, Allen 2026-05-22). --%>
      <button
        :if={@has_right_sidebar}
        type="button"
        phx-click={JS.toggle(to: "#right-sidebar", display: "block")}
        class="flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100"
        title={gettext("Toggle members panel")}
        aria-label={gettext("Toggle members panel")}
      >
        <.icon name="users" size="xs" />
        <span>{gettext("members")}</span>
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
end
