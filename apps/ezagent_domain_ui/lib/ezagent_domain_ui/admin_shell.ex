defmodule EzagentDomainUi.AdminShell do
  @moduledoc """
  Nested-shell refactor PR-1 (SPEC §1, §6 row 1) — the admin
  (`workspace://system` config) perspective BODY.

  Stateless `Phoenix.Component` (Tier-2, `ezagent_domain_ui` — zero
  LiveView/registry deps). This is today's
  `EzagentDomainUi.AdminSettingsShell` BODY — the left settings nav +
  the main panel — with its stripped header (Back / centered title /
  close X) REMOVED.

  Per the nested-shell SPEC §1, the universal header now lives in the
  OUTER shell (`IdeShell.ide_shell_outer/1`). On an admin page the
  outer shell runs in `perspective: :admin`, so its header shows a
  plain `ezagent · System` label instead of the workspace dropdown
  (SPEC §2). `admin_shell/1` is ONE of the two inner perspectives the
  outer shell's `:body` slot hosts; `workspace_shell/1` is the other.

  Introduced additively in PR-1 as a faithful COPY of the old
  `AdminSettingsShell` body region (restructure, not redesign). PR-3
  migrated the last consumer onto this component and DELETED the old
  `AdminSettingsShell` — `admin_shell/1` is now the sole admin
  perspective body. The left settings nav (`sidebar_nav/1`) is
  internal to this component, not a slot.

  ## Usage

      <AdminShell.admin_shell
        current_path={@current_path}
        active_section={:logs}
      >
        <:main>
          <.page_header title="Logs & Audit" />
          ...
        </:main>
      </AdminShell.admin_shell>

  `active_section` is one of `:overview | :workspaces | :logs |
  :registry | :snapshots | :templates | :settings` (the keys returned
  by `sections/0`) and controls which sidebar item is highlighted.
  `nil` derives it from `current_path`.
  """

  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend. NOT a
  # dependency on `ezagent_web` (see `EzagentDomainUi.Gettext` moduledoc).
  use Gettext, backend: EzagentDomainUi.Gettext
  use EzagentDomainUi.Primitives

  # --- admin_shell ----------------------------------------------------------

  attr(:current_path, :string,
    default: "/admin",
    doc: "Current request path. Used as a fallback to derive active_section if not given."
  )

  attr(:active_section, :atom,
    default: nil,
    doc: """
    Which sidebar item is highlighted. One of `:overview | :workspaces |
    :logs | :registry | :snapshots | :templates | :settings`, OR `nil` to
    derive from `current_path`.
    """
  )

  slot(:main, required: true)

  def admin_shell(assigns) do
    active = assigns.active_section || section_for_path(assigns.current_path)
    assigns = assign(assigns, :active_section, active)

    ~H"""
    <%!-- Nested-shell PR-1: body region only — the left settings nav +
          the main panel. The stripped header (Back / centered title /
          close X) that AdminSettingsShell carried is REMOVED; the
          universal header is now owned by the outer shell. --%>
    <div
      id="admin-shell"
      class="flex-1 flex min-h-0 bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 text-sm font-sans"
    >
      <.sidebar_nav active_section={@active_section} />

      <div
        id="admin-shell-main"
        class="flex-1 flex flex-col min-w-0 bg-white dark:bg-zinc-900 overflow-auto"
      >
        {render_slot(@main)}
      </div>
    </div>
    """
  end

  # --- sidebar_nav ----------------------------------------------------------

  @doc """
  Left rail listing the admin sub-sections. Vertical labeled list
  (NOT an icon strip like the Activity Bar). Internal to the admin
  perspective.

  Copy of `EzagentDomainUi.AdminSettingsShell.sidebar_nav/1`
  (nested-shell PR-1). The `top-10` offset positions the mobile
  overlay below the outer shell's universal header.
  """
  attr(:active_section, :atom, required: true)

  def sidebar_nav(assigns) do
    assigns = assign(assigns, :items, sections())

    ~H"""
    <nav
      id="admin-shell-sidebar"
      phx-click-away={Phoenix.LiveView.JS.hide(to: "#admin-shell-sidebar")}
      class="hidden lg:flex lg:static fixed top-10 bottom-0 left-0 z-40 w-56 max-w-[80vw] border-r border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 flex-col py-2 px-2 gap-px shrink-0 shadow-xl lg:shadow-none"
    >
      <div class="text-[10px] uppercase tracking-wide text-zinc-500 px-2 mb-1">
        {gettext("Admin Settings")}
      </div>
      <a
        :for={item <- @items}
        href={item.path}
        class={[
          "flex items-center gap-2 px-2 py-1.5 text-xs rounded-md transition-colors",
          (item.key == @active_section &&
             "bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-medium shadow-sm border border-zinc-200 dark:border-zinc-800") ||
            "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100"
        ]}
        aria-current={(item.key == @active_section && "page") || nil}
      >
        <.icon name={item.icon} size="xs" />
        <span>{item.label}</span>
      </a>
    </nav>
    """
  end

  # --- sections / routing helpers ------------------------------------------

  @doc """
  The 6 admin sub-sections in display order. Each entry:

      %{key: atom, label: String.t(), icon: String.t(), path: String.t()}

  Copy of `EzagentDomainUi.AdminSettingsShell.sections/0`
  (nested-shell PR-1).
  """
  @spec sections() :: [%{key: atom(), label: String.t(), icon: String.t(), path: String.t()}]
  def sections do
    [
      %{key: :overview, label: gettext("Overview"), icon: "dashboard", path: "/admin"},
      %{key: :workspaces, label: gettext("Workspaces"), icon: "folder", path: "/workspaces"},
      %{key: :logs, label: gettext("Logs & Audit"), icon: "bug", path: "/admin/logs"},
      %{key: :registry, label: gettext("Registry"), icon: "users", path: "/admin/registry"},
      %{key: :snapshots, label: gettext("Snapshots"), icon: "folder", path: "/admin/snapshots"},
      # G-1 + G-2 V0 stop-gap (audit 2026-05-23) — AgentTemplate +
      # SessionTemplate Kinds list, read-only.
      %{key: :templates, label: gettext("Templates"), icon: "folder", path: "/admin/templates"},
      %{key: :settings, label: gettext("Settings"), icon: "settings", path: "/admin/settings"}
    ]
  end

  @doc """
  Compute the active sidebar section from the current path. Used as a
  fallback when the caller doesn't pass `active_section` explicitly.

  Copy of `EzagentDomainUi.AdminSettingsShell.section_for_path/1`
  (nested-shell PR-1).

  Examples:

      iex> section_for_path("/admin")
      :overview

      iex> section_for_path("/admin/logs")
      :logs

      iex> section_for_path("/admin/registry")
      :registry

      iex> section_for_path("/admin/snapshots")
      :snapshots

      iex> section_for_path("/workspaces")
      :workspaces

      iex> section_for_path("/workspaces/demo")
      :workspaces

      iex> section_for_path("/admin/settings")
      :settings

      iex> section_for_path("/sessions")
      :overview
  """
  @spec section_for_path(String.t() | nil) :: atom()
  def section_for_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/admin/logs") -> :logs
      String.starts_with?(path, "/admin/registry") -> :registry
      String.starts_with?(path, "/admin/snapshots") -> :snapshots
      String.starts_with?(path, "/admin/templates") -> :templates
      String.starts_with?(path, "/admin/settings") -> :settings
      String.starts_with?(path, "/workspaces") -> :workspaces
      true -> :overview
    end
  end

  def section_for_path(_), do: :overview
end
