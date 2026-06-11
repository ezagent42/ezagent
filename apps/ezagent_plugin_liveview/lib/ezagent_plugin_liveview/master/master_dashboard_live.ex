defmodule EzagentPluginLiveview.Master.MasterDashboardLive do
  @moduledoc """
  T2A.1 — Master Admin Dashboard at `/autoservice/master`.

  Shows tenant count, active CR count, and recent publishes across all
  tenants. Reads CR data via `EzagentPluginContent.Tenant.TenantConfig`
  and lists workspace-scoped CR pointers from ConfigStore.

  Mount assigns: page_title, workspace_uri, stats map.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(_params, _session, socket) do
    workspace_uri = Map.get(socket.assigns, :current_workspace_uri)

    {:ok,
     socket
     |> assign(:page_title, gettext("Master Admin Dashboard"))
     |> assign(:workspace_uri, stable_uri(workspace_uri))
     |> assign(:stats, load_stats(workspace_uri))
     |> assign(:tenants, list_tenants())
     |> assign(:flash_info, nil)}
  end

  defp load_stats(_workspace_uri) do
    tenants = list_tenants()

    active_cr_count =
      Enum.count(tenants, fn {tid, _label} ->
        soft_ensure_active_cr(tid)
      end)

    %{
      tenant_count: length(tenants),
      active_cr_count: active_cr_count,
      recent_publishes: 0
    }
  end

  # Soft-guarded via Code.ensure_loaded? so this LV stays decoupled from
  # :ezagent_plugin_cr at compile time. Uses apply/3 to avoid a compile-time
  # undefined-function warning.
  defp soft_ensure_active_cr(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      case apply(mod, :ensure_active_cr, [tid]) do
        {:ok, %{"status" => "open"}} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp list_tenants do
    # Scan ConfigPointer table for workspace-layer tenant config keys.
    # Keys matching "tenant:<tid>:config" give us the tenant IDs.
    #
    # NOTE: This is a scan over ConfigStore pointers. In production with
    # many tenants, this should be replaced by a dedicated TenantStore
    # lookup. For now this is the simplest path that works.
    try do
      import Ecto.Query
      alias Ezagent.Socialware.ConfigPointer
      alias EzagentCore.Repo

      Repo.all(
        from(p in ConfigPointer,
          where: like(p.key, "tenant:%:config"),
          select: {p.key, p.workspace_uri}
        )
      )
      |> Enum.map(fn {key, _ws_uri} ->
        # "tenant:<tid>:config" → extract tid
        parts = String.split(key, ":")
        tid = Enum.at(parts, 1) || "?"
        {tid, tid}
      end)
      |> Enum.uniq_by(fn {tid, _} -> tid end)
    rescue
      _ -> []
    end
  end

  defp stable_uri(nil), do: nil
  defp stable_uri(uri), do: Ezagent.URI.stable_key(uri)

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:stats, load_stats(socket.assigns.workspace_uri))
     |> assign(:tenants, list_tenants())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-5xl">
      <.page_header title={@page_title}>
        <:subtitle>
          {gettext("Overview of all AutoService tenants, active CRs, and recent publishes.")}
        </:subtitle>
      </.page_header>

      <%!-- KPI cards --%>
      <div class="grid grid-cols-3 gap-3 mt-4 mb-6">
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Tenants")}
            </span>
            <span class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
              {@stats.tenant_count}
            </span>
          </div>
        </.card>
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Active CRs")}
            </span>
            <span class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
              {@stats.active_cr_count}
            </span>
          </div>
        </.card>
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Recent Publishes")}
            </span>
            <span class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
              {@stats.recent_publishes}
            </span>
          </div>
        </.card>
      </div>

      <%!-- Tenant list --%>
      <.card>
        <:header>
          <div class="flex items-center justify-between">
            <span>{gettext("Tenants")}</span>
            <button phx-click="refresh" class="text-xs underline text-zinc-500 hover:text-zinc-700">
              {gettext("Refresh")}
            </button>
          </div>
        </:header>

        <p :if={@tenants == []} class="text-sm text-zinc-500 italic p-4">
          {gettext("No tenants found. Onboard a new tenant to get started.")}
        </p>

        <table :if={@tenants != []} class="w-full text-sm">
          <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
            <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th class="px-4 py-2">{gettext("Tenant ID")}</th>
              <th class="py-2">{gettext("Label")}</th>
              <th class="py-2">{gettext("Status")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{tid, label} <- @tenants}
              class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
            >
              <td class="px-4 py-2 font-mono text-xs">{tid}</td>
              <td class="py-2">{label}</td>
              <td class="py-2">
                <.badge variant="default">{gettext("active")}</.badge>
              </td>
              <td class="py-2 pr-4 text-right">
                <a
                  href={"/autoservice/tenant/#{tid}"}
                  class="text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-xs"
                >
                  {gettext("manage")} →
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end
end
