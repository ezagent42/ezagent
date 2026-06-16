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

  alias EzagentPluginContent.Tenant.TenantRuntime

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("CR: %{tid}", tid: tid))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, tid)
     |> assign(:cr, load_cr(tid))
     |> assign(:cr_history, load_cr_history(tid))
     |> assign(:lint_results, load_lint(tid))
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
     |> assign(:lint_results, nil)
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

  defp load_cr_history(tid) do
    release = TenantRuntime.release_path(tid)

    if File.dir?(release) do
      case File.ls(release) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.starts_with?(&1, "v"))
          |> Enum.sort_by(&extract_version/1, :desc)
          |> Enum.map(fn dir ->
            full = Path.join(release, dir)
            stat = File.stat!(full, time: :posix)

            time_str =
              stat.mtime
              |> DateTime.from_unix!()
              |> Calendar.strftime("%Y-%m-%d %H:%M")

            {dir, time_str}
          end)

        {:error, _} ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp extract_version("v" <> rest) do
    case Integer.parse(rest) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp extract_version(_), do: 0

  defp load_lint(tid) do
    mod = EzagentPluginCr.CrLint

    if Code.ensure_loaded?(mod) and function_exported?(mod, :check, 1) do
      apply(mod, :check, [tid])
    else
      {:ok, %{warnings: [], ok: []}}
    end
  rescue
    _ -> {:ok, %{warnings: [], ok: []}}
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
         |> assign(:lint_results, load_lint(tid))
         |> assign(:error, nil)
         |> assign(:flash_info, gettext("Published successfully."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:lint_results, load_lint(tid))
         |> assign(:error, inspect(reason))}
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

  def handle_event("revert_item", %{"path" => path}, socket) do
    tid = socket.assigns.tid
    mod = EzagentPluginCr.CrEngine

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :revert_item, 2) do
        apply(mod, :revert_item, [tid, path])
      else
        {:error, "CrEngine.revert_item not available"}
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:cr, load_cr(tid))
         |> assign(:flash_info, gettext("Reverted %{path}.", path: path))}

      {:error, :not_found} ->
        {:noreply, assign(socket, :error, gettext("File not found in release: %{path}", path: path))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, gettext("Revert failed: %{reason}", reason: inspect(reason)))}
    end
  rescue
    e -> {:noreply, assign(socket, :error, Exception.message(e))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:cr, load_cr(socket.assigns.tid))
     |> assign(:lint_results, load_lint(socket.assigns.tid))
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

      <p
        :if={@flash_info}
        class="mb-4 text-sm text-green-600 dark:text-green-400 bg-green-50 dark:bg-green-950 p-3 rounded-md"
      >
        {@flash_info}
      </p>

      <p
        :if={@error}
        class="mb-4 text-sm text-rose-600 dark:text-rose-400 bg-rose-50 dark:bg-rose-950 p-3 rounded-md"
      >
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

          <%!-- Sandbox diff items --%>
          <%= if @cr["sandbox_diff"] && @cr["sandbox_diff"]["items"] not in [nil, []] do %>
            <div class="mt-4 pt-3 border-t border-zinc-100 dark:border-zinc-800">
              <h3 class="text-sm font-medium mb-2">
                {gettext("Sandbox Changes")} ({@cr["sandbox_diff"]["files_changed"] || 0})
              </h3>
              <div class="space-y-1">
                <%= for item <- @cr["sandbox_diff"]["items"] do %>
                  <div class="flex items-center gap-2 text-xs py-1">
                    <span class={"inline-block w-1.5 h-1.5 rounded-full #{diff_item_color(item["kind"])}"}>
                    </span>
                    <span class="font-mono text-zinc-600 dark:text-zinc-400">{item["path"]}</span>
                    <span class="text-zinc-400">{item["kind"]}</span>
                    <button
                      :if={item["kind"] in ["modified", "added"]}
                      phx-click="revert_item"
                      phx-value-path={item["path"]}
                      class="ml-auto px-1.5 py-0.5 text-xs border border-zinc-300 dark:border-zinc-600 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-500 dark:text-zinc-400"
                      title={gettext("Revert this file from release")}
                    >
                      {gettext("Revert")}
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

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

      <%!-- Lint Results --%>
      <%= if @lint_results do %>
        <% lint_ok? = elem(@lint_results, 0) == :ok
        lint_data = elem(@lint_results, 1) %>
        <.card class="mb-4">
          <:header>
            <div class="flex items-center justify-between">
              <span>{gettext("Lint Results")}</span>
              <span class={"text-xs font-semibold px-2 py-0.5 rounded #{if lint_ok?, do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200", else: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"}"}>
                {if lint_ok?, do: gettext("PASS"), else: gettext("FAIL")}
              </span>
            </div>
          </:header>
          <div class="text-xs font-mono space-y-1">
            <%!-- Error items --%>
            <%= for {:error, msg} <- lint_data[:errors] || [] do %>
              <div class="flex items-center gap-1.5">
                <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200">
                  ERROR
                </span>
                <span class="text-red-700 dark:text-red-300">{msg}</span>
              </div>
            <% end %>
            <%!-- Warning items --%>
            <%= for {:warning, msg} <- lint_data[:warnings] || [] do %>
              <div class="flex items-center gap-1.5">
                <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                  WARN
                </span>
                <span class="text-amber-700 dark:text-amber-300">{msg}</span>
              </div>
            <% end %>
            <%!-- OK items --%>
            <%= for {:ok, msg} <- lint_data[:ok] || [] do %>
              <div class="flex items-center gap-1.5">
                <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
                  OK
                </span>
                <span class="text-green-700 dark:text-green-300">{msg}</span>
              </div>
            <% end %>
            <%!-- Empty state --%>
            <%= if (lint_data[:errors] || []) == [] and (lint_data[:warnings] || []) == [] and (lint_data[:ok] || []) == [] do %>
              <div class="text-zinc-400 italic">{gettext("No lint rules executed.")}</div>
            <% end %>
          </div>
        </.card>
      <% end %>

      <%!-- CR History --%>
      <%= if @cr_history != [] do %>
        <.card>
          <:header>{gettext("CR History")} ({length(@cr_history)})</:header>
          <div class="divide-y divide-zinc-100 dark:divide-zinc-800">
            <%= for {ver, info} <- @cr_history do %>
              <div class="py-2 flex items-center justify-between text-sm">
                <span class="font-mono text-xs text-zinc-700 dark:text-zinc-300">{ver}</span>
                <span class="text-xs text-zinc-400">{info}</span>
              </div>
            <% end %>
          </div>
        </.card>
      <% else %>
        <.card>
          <:header>{gettext("CR History")}</:header>
          <p class="text-sm text-zinc-500 italic">
            {gettext("No published releases yet. Publish a CR to create a release version.")}
          </p>
        </.card>
      <% end %>
    </div>
    """
  end

  defp cr_status_variant(%{"status" => "open"}), do: "warning"
  defp cr_status_variant(%{"status" => "published"}), do: "success"
  defp cr_status_variant(%{"status" => "cancelled"}), do: "danger"
  defp cr_status_variant(_), do: "default"

  defp diff_item_color("added"), do: "bg-green-500"
  defp diff_item_color("removed"), do: "bg-red-500"
  defp diff_item_color("modified"), do: "bg-yellow-400"
  defp diff_item_color("dir_modified"), do: "bg-yellow-400"
  defp diff_item_color(_), do: "bg-zinc-400"
end
