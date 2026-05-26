defmodule EzagentPluginLiveview.PluginsLive do
  @moduledoc """
  `/plugins` — the installed-plugin listing (plugin authoring contract
  SPEC §6.2 / PR-4).

  100% registry-driven. `mount` enumerates `Ezagent.PluginRegistry`;
  each plugin's own `plugin_info/0` supplies the card's name /
  description / version, and `config_surface/0` supplies the config
  icon's target. The page holds NO per-slug knowledge — the hardcoded
  `pretty_name/1` / `pretty_desc/1` / `primary_link/1` of the previous
  version are deleted, which is the whole point of the contract: a
  plugin declares its own metadata, core UI never changes when a plugin
  is added.

  Each plugin renders as one `<.plugin_card>` (Tier-1 atom). The config
  icon is wired from `config_surface/0`:

    - `:route`  → the icon links to the surface's own `path`.
    - `:flavor` → the icon links to `/identities?filter=agent:<flavor>`
      (manage that flavor's agents — SPEC §6.1, Allen Q1).
    - `nil`     → no config target; the card renders a disabled icon.

  PR-2/2b removed the redundant left sidebar from this page — the cards
  ARE the listing. The page is on the nested shell (`app_shell` +
  `workspace_shell`); that wrapping is kept.
  """
  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :plugins, list_plugins())}
  end

  # 2026-05-26 (Allen): the G-9 boot-diagnostics card (cc-orchestrator
  # AgentTemplate seed status) moved from this page to
  # `AdminDashboardLive` (`/admin`) — system-level boot-health is
  # admin scope, not per-plugin metadata. Per-session orchestrator
  # INSTANCE health lives in the session-detail UI (separate panel).

  # Enumerate PluginRegistry — every card is built from the plugin's
  # OWN declarations (plugin_info/0 + config_surface/0). No per-slug
  # branch lives here.
  defp list_plugins do
    Ezagent.PluginRegistry.list_all()
    |> Enum.map(fn plugin_module ->
      info = plugin_module.plugin_info()
      {config_path, config_label} = config_target(plugin_module.config_surface())

      %{
        slug: info.slug,
        name: info.name,
        description: info.description,
        version: info.version,
        config_path: config_path,
        config_label: config_label
      }
    end)
    |> Enum.sort_by(& &1.slug)
  end

  # Translate a plugin's config_surface/0 into the card's config icon
  # target (SPEC §6.1).
  defp config_target(%{kind: :route, path: path, label: label})
       when is_binary(path) and is_binary(label),
       do: {path, label}

  defp config_target(%{kind: :flavor, flavor: flavor, label: label})
       when is_binary(flavor) and is_binary(label),
       do: {"/identities?filter=agent:#{flavor}", label}

  defp config_target(nil), do: {nil, gettext("Configure")}

  # PR-5 codex MEDIUM-5 — defensive catch-all. The `:ezagent_plugin_check`
  # gate + `Ezagent.Plugin.boot/1` both reject a `:form` or malformed
  # config_surface/0, so a non-conforming surface should never reach
  # here. But `/plugins` must NOT crash with a FunctionClauseError if
  # one slips through (e.g. a hot-installed plugin that bypassed the
  # gate) — an unknown surface renders a disabled config icon instead.
  defp config_target(_unknown), do: {nil, gettext("Configure")}

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/plugins"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6">
              <.page_header title={gettext("Plugins")}>
                <:subtitle>{gettext("Installed ezagent plugins. Each one extends a core capability.")}</:subtitle>
              </.page_header>

              <%!-- 2026-05-26 (Allen): boot diagnostics card moved to
                    /admin (AdminDashboardLive). System-level boot-
                    health is admin scope; this page lists installed
                    plugins per the plugin authoring contract (SPEC §6.2). --%>

              <div class="grid grid-cols-2 gap-4 mt-4">
                <.plugin_card
                  :for={p <- @plugins}
                  name={p.name}
                  description={p.description}
                  version={p.version}
                  config_path={p.config_path}
                  config_label={p.config_label}
                />
              </div>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  # 2026-05-26 (Allen): boot-diagnostics card + cc_seed_badge/1 +
  # cc_seed_subtitle/1 helpers MOVED to AdminDashboardLive (`/admin`).
  # System-level boot-health is admin scope, not per-plugin metadata.
end
