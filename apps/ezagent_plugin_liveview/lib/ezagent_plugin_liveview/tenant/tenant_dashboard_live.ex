defmodule EzagentPluginLiveview.Tenant.TenantDashboardLive do
  @moduledoc """
  T2A.2 — Tenant Admin Dashboard at `/autoservice/tenant/:tid`.

  Shows current version, active CRs, and a sandbox preview button.
  Reads tenant config via `EzagentPluginContent.Tenant.TenantConfig`.

  Mount reads the `:tid` param and loads config + CR state.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    config = load_tenant_config(tid)
    cr = load_active_cr(tid)
    initialized? = check_initialized?(tid)

    {:ok,
     socket
     |> assign(:page_title, gettext("Tenant: %{tid}", tid: tid))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, tid)
     |> assign(:config, config)
     |> assign(:cr, cr)
     |> assign(:initialized?, initialized?)
     |> assign(:version, cr && cr["published_version"] || gettext("none"))
     |> assign(:flash_info, nil)}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Tenant Dashboard"))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, nil)
     |> assign(:config, nil)
     |> assign(:cr, nil)
     |> assign(:version, gettext("n/a"))
     |> assign(:flash_info, gettext("No tenant ID provided."))}
  end

  defp load_tenant_config(tid) do
    mod = EzagentPluginContent.Tenant.TenantConfig

    if Code.ensure_loaded?(mod) and function_exported?(mod, :read_config, 1) do
      case apply(mod, :read_config, [tid]) do
        {:ok, body} -> body
        :none -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp check_initialized?(tid) do
    current = Path.join([TenantRuntime.release_path(tid), "_current"])
    File.exists?(current)
  rescue
    _ -> false
  end

  defp load_active_cr(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      case apply(mod, :ensure_active_cr, [tid]) do
        {:ok, cr} -> cr
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    tid = socket.assigns.tid

    {:noreply,
     socket
     |> assign(:config, load_tenant_config(tid))
     |> assign(:cr, load_active_cr(tid))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-4xl">
      <.page_header title={@page_title}>
        <:subtitle>
          {gettext("Tenant admin console — manage config, CRs, and operators.")}
        </:subtitle>
      </.page_header>

      <p :if={@flash_info} class="mb-4 text-sm text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-950 p-3 rounded-md">
        {@flash_info}
      </p>

      <%!-- Initialization CTA (shown when tenant is pending) --%>
      <div :if={!@initialized?} class="max-w-3xl mx-auto border-2 border-amber-300 rounded-xl overflow-hidden">
        <div class="bg-amber-50 px-6 py-5">
          <div class="flex items-start gap-4">
            <div class="text-4xl">🚀</div>
            <div class="flex-1">
              <h3 class="text-lg font-bold text-amber-900">{gettext("Tenant Not Initialized")}</h3>
              <p class="text-sm text-amber-700 mt-1">
                {gettext("This tenant has not completed initialization. The wizard will auto-generate the Soul template from your brand/industry info, prefill slot values, inherit platform skills, and create the initial release.")}
              </p>
              <div class="mt-4 flex gap-3">
                <a
                  href={"/admin/autoservice/tenants/#{@tid}/init"}
                  class="bg-amber-600 text-white rounded-lg px-6 py-2.5 text-sm font-medium hover:bg-amber-700 shadow"
                >
                  {gettext("Start Initialization")} →
                </a>
                <span class="text-xs text-amber-500 self-center">
                  💡 {gettext("Or use the sidebar menu to manually edit each module first.")}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@initialized?} class="flex items-center justify-between mb-4">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
          {gettext("Overview")}
        </h2>
        <button phx-click="refresh" class="text-xs underline text-zinc-500 hover:text-zinc-700">
          {gettext("Refresh")}
        </button>
      </div>

      <div class="grid grid-cols-3 gap-3 mb-6">
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Current Version")}
            </span>
            <span class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
              {@version}
            </span>
          </div>
        </.card>
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Active CR Status")}
            </span>
            <span class="text-lg font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
              {cr_status_badge_text(@cr)}
            </span>
          </div>
        </.card>
        <.card>
          <div class="flex flex-col gap-0.5">
            <span class="text-xs uppercase tracking-wide text-zinc-500">
              {gettext("Sandbox")}
            </span>
            <span class="text-sm text-zinc-900 dark:text-zinc-100">
              {gettext("Ready")}
            </span>
          </div>
        </.card>
      </div>

      <%!-- Tenant Config Card --%>
      <.card class="mb-4">
        <:header>{gettext("Tenant Configuration")}</:header>
        <%= if @config do %>
          <div class="text-sm space-y-1">
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Brand Name")}</span>
              <span>{@config["brand_name"] || "—"}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Industry")}</span>
              <span>{@config["industry"] || "—"}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Roles")}</span>
              <span>{Enum.join(@config["roles"] || [], ", ")}</span>
            </div>
            <div class="flex justify-between py-1">
              <span class="text-zinc-500">{gettext("Channels")}</span>
              <span>{Enum.join(@config["channels"] || [], ", ")}</span>
            </div>
          </div>
        <% else %>
          <p class="text-sm text-zinc-500 italic">
            {gettext("No configuration found for this tenant.")}
          </p>
        <% end %>
      </.card>

      <%!-- Active CR Card --%>
      <.card class="mb-4">
        <:header>{gettext("Active Change Request")}</:header>
        <%= if @cr do %>
          <div class="text-sm space-y-1 mb-3">
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("CR ID")}</span>
              <span class="font-mono text-xs">{@cr["cr_id"] || "—"}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Status")}</span>
              <.badge variant={cr_status_variant(@cr)}>{@cr["status"] || "—"}</.badge>
            </div>
            <div :if={@cr["published_version"]} class="flex justify-between py-1">
              <span class="text-zinc-500">{gettext("Published Version")}</span>
              <span class="font-mono text-xs">{@cr["published_version"]}</span>
            </div>
          </div>
          <div class="flex gap-2">
            <a
              href={"/autoservice/tenant/#{@tid}/cr"}
              class="px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-800"
            >
              {gettext("Manage CR")} →
            </a>
          </div>
        <% else %>
          <p class="text-sm text-zinc-500 italic">
            {gettext("No active CR found.")}
          </p>
        <% end %>
      </.card>

      <%!-- Quick Links --%>
      <.card>
        <:header>{gettext("Quick Links")}</:header>
        <div class="grid grid-cols-2 gap-2">
          <a
            href={"/autoservice/tenant/#{@tid}/cr"}
            class="block p-3 border border-zinc-200 dark:border-zinc-800 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-800 text-sm"
          >
            {gettext("CR Dashboard")} →
          </a>
          <a
            href={"/autoservice/tenant/#{@tid}/operators"}
            class="block p-3 border border-zinc-200 dark:border-zinc-800 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-800 text-sm"
          >
            {gettext("Operators")} →
          </a>
          <a
            href="/autoservice/admin"
            class="block p-3 border border-emerald-200 dark:border-emerald-800 rounded-md hover:bg-emerald-50 dark:hover:bg-emerald-900/30 text-sm font-medium text-emerald-700 dark:text-emerald-300"
          >
            {gettext("Content Edit")} →
          </a>
        </div>
      </.card>
    </div>
    """
  end

  defp cr_status_badge_text(nil), do: gettext("none")
  defp cr_status_badge_text(%{"status" => s}), do: s
  defp cr_status_badge_text(_), do: gettext("unknown")

  defp cr_status_variant(%{"status" => "open"}), do: "warning"
  defp cr_status_variant(%{"status" => "published"}), do: "success"
  defp cr_status_variant(%{"status" => "cancelled"}), do: "danger"
  defp cr_status_variant(_), do: "default"
end
