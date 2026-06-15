defmodule EzagentPluginLiveview.Master.MasterDashboardLive do
  @moduledoc """
  T2A.1 — Master Admin Dashboard at `/admin/autoservice`.

  Shows tenant count, active CR count, recent publishes, and tenant list
  across all AutoService tenants. Master admins can onboard new tenants,
  manage existing ones, and access platform-level content management.

  Mount assigns: page_title, workspace_uri, stats map, tenants list.
  """

  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.{TenantConfig, TenantRuntime}

  @impl true
  def mount(_params, _session, socket) do
    workspace_uri = Map.get(socket.assigns, :current_workspace_uri)

    tenants = list_tenants()
    stats = build_stats(tenants)

    {:ok,
     socket
     |> assign(:page_title, gettext("Master Admin Dashboard"))
     |> assign(:workspace_uri, stable_uri(workspace_uri))
     |> assign(:stats, stats)
     |> assign(:tenants, tenants)
     |> assign(:flash_info, nil)}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp build_stats(tenants) do
    active_cr_count =
      Enum.count(tenants, fn %{tid: tid} ->
        soft_ensure_active_cr(tid)
      end)

    %{
      tenant_count: length(tenants),
      active_cr_count: active_cr_count,
      recent_publishes: count_recent_publishes(tenants)
    }
  end

  defp count_recent_publishes(tenants) do
    tenants
    |> Enum.reduce(0, fn %{tid: tid}, acc ->
      case TenantConfig.read_cr(tid, "active") do
        {:ok, %{"status" => "published", "published_version" => v}}
          when is_binary(v) ->
          acc + 1

        _ ->
          acc
      end
    end)
  rescue
    _ -> 0
  end

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

  # Returns a list of maps: %{tid: ..., brand_name: ..., status: ..., cr_status: ...}
  defp list_tenants do
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
        parts = String.split(key, ":")
        tid = Enum.at(parts, 1) || "?"

        # Read tenant config for brand name
        brand_name =
          case TenantConfig.read_config(tid) do
            {:ok, %{"brand_name" => bn}} when is_binary(bn) and bn != "" -> bn
            _ -> nil
          end

        # Determine status: online if sandbox exists and CR is present
        sandbox_exists? = File.dir?(TenantRuntime.sandbox_path(tid))

        cr_status =
          case TenantConfig.read_cr(tid, "active") do
            {:ok, %{"status" => s}} -> s
            _ -> nil
          end

        status =
          cond do
            sandbox_exists? and cr_status == "published" -> :published
            sandbox_exists? and cr_status == "open" -> :draft
            sandbox_exists? -> :provisioned
            true -> :pending
          end

        %{
          tid: tid,
          brand_name: brand_name || tid,
          status: status,
          cr_status: cr_status
        }
      end)
      |> Enum.uniq_by(fn %{tid: tid} -> tid end)
      |> Enum.sort_by(fn %{tid: tid} -> tid end)
    rescue
      _ -> []
    end
  end

  defp stable_uri(nil), do: nil
  defp stable_uri(uri), do: Ezagent.URI.stable_key(uri)

  # ---------------------------------------------------------------------------
  # handle_event
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    tenants = list_tenants()
    stats = build_stats(tenants)

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:tenants, tenants)}
  end

  def handle_event("onboard", _params, socket) do
    {:noreply,
     socket
     |> push_navigate(to: "/admin/autoservice/tenants/new")}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp status_variant(:published), do: "success"
  defp status_variant(:draft), do: "warning"
  defp status_variant(:provisioned), do: "info"
  defp status_variant(:pending), do: "default"

  defp status_label(:published), do: gettext("已发布")
  defp status_label(:draft), do: gettext("草稿")
  defp status_label(:provisioned), do: gettext("已初始化")
  defp status_label(:pending), do: gettext("待创建")

  defp cr_status_label("open"), do: gettext("CR 开放")
  defp cr_status_label("published"), do: gettext("已发布")
  defp cr_status_label("cancelled"), do: gettext("已取消")
  defp cr_status_label(nil), do: gettext("—")
  defp cr_status_label(_), do: gettext("未知")

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-5xl">
      <%!-- Header --%>
      <div class="flex items-center justify-between mb-4">
        <.page_header title={@page_title}>
          <:subtitle>
            {gettext("Overview of all AutoService tenants, active CRs, and recent publishes.")}
          </:subtitle>
        </.page_header>

        <div class="flex gap-2">
          <button
            phx-click="refresh"
            class="text-xs underline text-zinc-500 hover:text-zinc-700 px-2"
          >
            {gettext("Refresh")}
          </button>
          <button
            phx-click="onboard"
            class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
          >
            {gettext("+ 新建租户")}
          </button>
        </div>
      </div>

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
              {gettext("Published")}
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
          <span>{gettext("Tenants")} ({@stats.tenant_count})</span>
        </:header>

        <p :if={@tenants == []} class="text-sm text-zinc-500 italic p-4">
          {gettext("No tenants found. Click「+ 新建租户」to onboard a new tenant.")}
        </p>

        <table :if={@tenants != []} class="w-full text-sm">
          <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
            <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th class="px-4 py-2">{gettext("Tenant ID")}</th>
              <th class="py-2">{gettext("Brand")}</th>
              <th class="py-2">{gettext("CR")}</th>
              <th class="py-2">{gettext("Status")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={t <- @tenants}
              class="border-b border-zinc-100 dark:border-zinc-900 last:border-0 hover:bg-zinc-50 dark:hover:bg-zinc-900"
            >
              <td class="px-4 py-2 font-mono text-xs">{t.tid}</td>
              <td class="py-2 text-sm">{t.brand_name}</td>
              <td class="py-2">
                <span :if={t.cr_status} class={[
                  "rounded px-2 py-0.5 text-xs",
                  t.cr_status == "open" && "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300",
                  t.cr_status == "published" && "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300",
                  t.cr_status == "cancelled" && "bg-zinc-100 text-zinc-500"
                ]}>
                  {cr_status_label(t.cr_status)}
                </span>
                <span :if={is_nil(t.cr_status)} class="text-xs text-zinc-400">—</span>
              </td>
              <td class="py-2">
                <.badge variant={status_variant(t.status)}>{status_label(t.status)}</.badge>
              </td>
              <td class="py-2 pr-4 text-right whitespace-nowrap">
                <a
                  href={"/admin/autoservice/tenants/#{t.tid}"}
                  class="text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-xs"
                >
                  {gettext("管理 →")}
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
