defmodule EzagentPluginLiveview.Tenant.CrDashboardLive do
  @moduledoc """
  T2A.2 — CR Dashboard at `/autoservice/tenant/:tid/cr`.

  Shows the active CR with publish and cancel buttons.
  Calls `CrEngine.ensure_active_cr/1`, `publish/1`, `cancel/1`.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("CR: %{tid}", tid: tid))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, tid)
     |> assign(:cr, load_cr(tid))
     |> assign(:cr_history, [])
     |> assign(:error, nil)
     |> assign(:flash_info, nil)}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("CR Dashboard"))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, nil)
     |> assign(:cr, nil)
     |> assign(:cr_history, [])
     |> assign(:error, nil)
     |> assign(:flash_info, gettext("No tenant ID provided."))}
  end

  defp load_cr(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      case apply(mod, :ensure_active_cr, [tid]) do
        {:ok, cr} -> cr
        {:error, _} -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("publish", _params, socket) do
    tid = socket.assigns.tid
    mod = EzagentPluginCr.CrEngine

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :publish, 1) do
        apply(mod, :publish, [tid])
      else
        {:error, "CrEngine not available"}
      end

    case result do
      {:ok, cr} ->
        {:noreply,
         socket
         |> assign(:cr, cr)
         |> assign(:error, nil)
         |> assign(:flash_info, gettext("Published successfully."))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  rescue
    e -> {:noreply, assign(socket, :error, Exception.message(e))}
  end

  def handle_event("cancel", _params, socket) do
    tid = socket.assigns.tid
    mod = EzagentPluginCr.CrEngine

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :cancel, 1) do
        apply(mod, :cancel, [tid])
      else
        {:error, "CrEngine not available"}
      end

    case result do
      {:ok, cr} ->
        {:noreply,
         socket
         |> assign(:cr, cr)
         |> assign(:error, nil)
         |> assign(:flash_info, gettext("CR cancelled."))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  rescue
    e -> {:noreply, assign(socket, :error, Exception.message(e))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:cr, load_cr(socket.assigns.tid))
     |> assign(:error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-3xl">
      <div class="flex items-center justify-between mb-4">
        <.page_header title={@page_title}>
          <:subtitle>
            {gettext("Manage the active Change Request for this tenant.")}
          </:subtitle>
        </.page_header>
        <a
          href={"/autoservice/tenant/#{@tid}"}
          class="text-xs text-zinc-500 hover:text-zinc-700"
        >
          {gettext("Back to Dashboard")} ←
        </a>
      </div>

      <p :if={@flash_info} class="mb-4 text-sm text-green-600 dark:text-green-400 bg-green-50 dark:bg-green-950 p-3 rounded-md">
        {@flash_info}
      </p>

      <p :if={@error} class="mb-4 text-sm text-rose-600 dark:text-rose-400 bg-rose-50 dark:bg-rose-950 p-3 rounded-md">
        {@error}
      </p>

      <div class="flex items-center gap-2 mb-4">
        <button phx-click="refresh" class="text-xs underline text-zinc-500 hover:text-zinc-700">
          {gettext("Refresh")}
        </button>
      </div>

      <%= if @cr do %>
        <.card class="mb-4">
          <:header>
            <div class="flex items-center justify-between">
              <span>{gettext("Active CR")}</span>
              <.badge variant={cr_status_variant(@cr)}>{@cr["status"] || "—"}</.badge>
            </div>
          </:header>

          <div class="text-sm space-y-1 mb-4">
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("CR ID")}</span>
              <span class="font-mono text-xs">{@cr["cr_id"] || "—"}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Tenant")}</span>
              <span>{@cr["tenant_id"] || @tid}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Created By")}</span>
              <span class="font-mono text-xs">{@cr["created_by"] || "—"}</span>
            </div>
            <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
              <span class="text-zinc-500">{gettext("Created At")}</span>
              <span class="text-xs">{@cr["created_at"] || "—"}</span>
            </div>
            <%= if @cr["published_version"] do %>
              <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
                <span class="text-zinc-500">{gettext("Published Version")}</span>
                <span class="font-mono text-xs">{@cr["published_version"]}</span>
              </div>
            <% end %>
            <%= if @cr["published_at"] do %>
              <div class="flex justify-between py-1">
                <span class="text-zinc-500">{gettext("Published At")}</span>
                <span class="text-xs">{@cr["published_at"]}</span>
              </div>
            <% end %>
          </div>

          <%!-- Action buttons --%>
          <div class="flex gap-2">
            <button
              :if={@cr["status"] == "open"}
              phx-click="publish"
              class="px-4 py-1.5 text-sm bg-zinc-800 text-white rounded-md hover:bg-zinc-700"
            >
              {gettext("Publish CR")}
            </button>
            <button
              :if={@cr["status"] == "open"}
              phx-click="cancel"
              class="px-4 py-1.5 text-sm border border-rose-300 text-rose-700 rounded-md hover:bg-rose-50 dark:border-rose-700 dark:text-rose-400 dark:hover:bg-rose-950"
            >
              {gettext("Cancel CR")}
            </button>
          </div>
        </.card>
      <% else %>
        <.card>
          <p class="text-sm text-zinc-500 italic">
            {gettext("No active CR found. A new CR will be created when the first change is made.")}
          </p>
        </.card>
      <% end %>

      <%!-- CR History (placeholder) --%>
      <.card>
        <:header>{gettext("CR History")}</:header>
        <p class="text-sm text-zinc-500 italic">
          {gettext("CR history will be shown here when available.")}
        </p>
      </.card>
    </div>
    """
  end

  defp cr_status_variant(%{"status" => "open"}), do: :warning
  defp cr_status_variant(%{"status" => "published"}), do: :success
  defp cr_status_variant(%{"status" => "cancelled"}), do: :danger
  defp cr_status_variant(_), do: :default
end
