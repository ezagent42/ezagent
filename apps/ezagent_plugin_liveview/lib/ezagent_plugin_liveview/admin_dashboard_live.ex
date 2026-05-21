defmodule EzagentPluginLiveview.AdminDashboardLive do
  @moduledoc """
  Phase 8 polish (Allen 2026-05-20) — admin dashboard at `/admin`.

  Replaces the former `/admin = Sessions` mapping (Sessions moved to
  `/sessions`). `/admin` is now reserved for sysadmin: overview KPIs
  plus links to `/admin/logs` (renamed from `/admin/observability`),
  `/admin/registry` (the KindRegistry live view, moved from
  `/admin/entities`), and `/admin/snapshots`.

  Phase 8c PR-F (2026-05-20): rendered inside
  `EzagentDomainUi.AdminSettingsShell` (the "settings drawer"
  perspective) instead of the IDE Shell. The drawer has no Activity
  Bar — admin is not a peer workflow, it's a permission/role
  perspective opened from the avatar dropdown.
  """
  use Phoenix.LiveView
  # i18n V1 (Allen 2026-05-21): backend module reference is runtime —
  # EzagentWeb.Gettext lives in the host app but doesn't need a
  # compile-time dep here. Gettext macros expand to runtime calls
  # against the named backend.
  use Gettext, backend: EzagentWeb.Gettext
  alias EzagentDomainUi.AdminSettingsShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_overview(socket)}
  end

  defp assign_overview(socket) do
    kinds = Ezagent.KindRegistry.list_all()

    sessions =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "session://")
      end)

    workspaces =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "workspace://")
      end)

    identities =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "entity://")
      end)

    agents =
      Enum.count(kinds, fn {uri_str, _pid} ->
        String.starts_with?(uri_str, "entity://agent/")
      end)

    socket
    |> assign(:kinds_total, length(kinds))
    |> assign(:sessions, sessions)
    |> assign(:workspaces, workspaces)
    |> assign(:identities, identities)
    |> assign(:agents, agents)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AdminSettingsShell.admin_settings_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/admin"
      active_section={:overview}
    >
      <:main>
        <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Overview")}>
            <:subtitle>
              System layer (admin settings drawer). Workspace-layer surfaces
              — Sessions, Workspaces, Identities, Routing, Plugins — live on
              the main Activity Bar. Close this drawer to return.
            </:subtitle>
          </.page_header>

          <%!-- Phase 8c PR-D — animated KPIs. The value renders SSR-final
                (no flash of 0); the `CountUp` JS hook resets to 0 on
                mount and animates 0 → target over 800ms with an
                ease-out curve. Falls back gracefully to the static
                number if JS doesn't run. --%>
          <div class="grid grid-cols-4 gap-3 mb-6">
            <.card><.kpi label="Sessions" value={@sessions} id="kpi-sessions" /></.card>
            <.card><.kpi label="Workspaces" value={@workspaces} id="kpi-workspaces" /></.card>
            <.card><.kpi label="Identities" value={@identities} id="kpi-identities" /></.card>
            <.card><.kpi label="Kinds alive" value={@kinds_total} id="kpi-kinds" /></.card>
          </div>

          <div class="grid grid-cols-3 gap-3">
            <a href="/admin/logs" class="block">
              <.card>
                <div class="font-medium text-sm">Logs &amp; Audit →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  Dispatch audit log, events, bridges. Renamed from Observability.
                </div>
              </.card>
            </a>
            <a href="/admin/registry" class="block">
              <.card>
                <div class="font-medium text-sm">Registry →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  Live <code>Ezagent.KindRegistry</code> snapshot — every Kind, every URI.
                </div>
              </.card>
            </a>
            <a href="/admin/snapshots" class="block">
              <.card>
                <div class="font-medium text-sm">Snapshots →</div>
                <div class="text-xs text-zinc-500 mt-1">
                  Persisted Kind state per <code>kind_snapshots</code> table.
                </div>
              </.card>
            </a>
          </div>
        </div>
      </:main>
    </AdminSettingsShell.admin_settings_shell>
    """
  end

  # --- kpi -----------------------------------------------------------------

  # Phase 8c PR-D — animated KPI tile.
  #
  # Renders the same visual shape as `Components.stat/1` but wraps the
  # numeric value in a `phx-hook="CountUp"` span so the JS hook animates
  # 0 → target on mount.
  #
  # `id` MUST be stable + unique on the page (LiveView hooks require it).
  # (`@doc` dropped — Elixir discards it on private functions.)
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:id, :string, required: true)

  defp kpi(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs uppercase tracking-wide text-zinc-500">{@label}</span>
      <span
        id={@id}
        phx-hook="CountUp"
        data-value={@value}
        class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"
      >
        {@value}
      </span>
    </div>
    """
  end
end
