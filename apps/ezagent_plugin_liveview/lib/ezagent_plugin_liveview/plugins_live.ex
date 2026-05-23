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
    {:ok,
     socket
     |> assign(:plugins, list_plugins())
     |> assign(:cc_orchestrator_status, load_cc_orchestrator_status())}
  end

  # G-9 fix (audit 2026-05-23) — read the cc-orchestrator seed status
  # from `Ezagent.Orchestrator.CcOrchestratorSeed.seed_status/0`. The
  # function is soft-guarded via `Code.ensure_loaded?` so this LV stays
  # decoupled from the chat domain at compile time (the seed lives in
  # `ezagent_domain_chat`; we don't want a compile-time alias here to
  # avoid back-pressure on the dep graph).
  defp load_cc_orchestrator_status do
    seed_module = Ezagent.Orchestrator.CcOrchestratorSeed

    if Code.ensure_loaded?(seed_module) and function_exported?(seed_module, :seed_status, 0) do
      seed_module.seed_status()
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  end

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

              <%!--
                G-9 fix (audit 2026-05-23) — Boot diagnostics. Today's
                surfaced check: the cc-orchestrator AgentTemplate seed.
                A silent seed failure used to leave the orchestrator
                unable to spawn — operators had no way to see this
                without grepping logs. Future boot checks slot into
                this same card.
              --%>
              <.boot_diagnostics_card status={@cc_orchestrator_status} />

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

  # G-9 fix — the boot-diagnostics card. Renders a single line per
  # check, with a colored status badge + a one-sentence operator-facing
  # explanation. The card is always rendered (even when all checks
  # pass) so operators see "everything OK" at a glance instead of
  # wondering whether the page just hides its diagnostics.
  attr :status, :any, required: true

  defp boot_diagnostics_card(assigns) do
    ~H"""
    <.card class="mt-4" id="boot-diagnostics">
      <:header>{gettext("Boot diagnostics")}</:header>
      <div class="flex items-start justify-between gap-3" id="cc-orchestrator-seed-row">
        <div class="min-w-0">
          <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">
            {gettext("cc-orchestrator AgentTemplate seed")}
          </div>
          <div class="text-xs text-zinc-500 mt-0.5">
            {cc_seed_subtitle(@status)}
          </div>
        </div>
        <div class="shrink-0">
          {cc_seed_badge(assigns)}
        </div>
      </div>
    </.card>
    """
  end

  defp cc_seed_badge(%{status: {:ok, _}} = assigns) do
    ~H"""
    <.badge variant="success">{gettext("seeded")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: {:partial, _}} = assigns) do
    ~H"""
    <.badge variant="warning">{gettext("partial")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: {:missing, _}} = assigns) do
    ~H"""
    <.badge variant="danger">{gettext("missing")}</.badge>
    """
  end

  defp cc_seed_badge(%{status: :unavailable} = assigns) do
    ~H"""
    <.badge variant="default">{gettext("unavailable")}</.badge>
    """
  end

  defp cc_seed_subtitle({:ok, %{template_uri: uri}}),
    do: gettext("Populated at %{uri}.", uri: uri)

  defp cc_seed_subtitle({:partial, %{template_uri: uri}}),
    do:
      gettext(
        "Kind alive at %{uri} but template slice is empty — soft sandbox-files write may have failed. Check application logs.",
        uri: uri
      )

  defp cc_seed_subtitle({:missing, %{template_uri: uri}}),
    do:
      gettext(
        "No Kind registered at %{uri} — seed did not run or failed at boot. Generator-spawned orchestrators will fail.",
        uri: uri
      )

  defp cc_seed_subtitle(:unavailable),
    do: gettext("Seed module not loaded — ezagent_domain_chat may not be running.")
end
