defmodule EzagentPluginLiveview.AutoService.Admin.VersionTimelineLive do
  use Phoenix.LiveView
  import Phoenix.Component
  alias EzagentPluginContent.Tenant.TenantRuntime

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    versions = list_versions(tid)
    current = get_current(tid)
    {:ok, assign(socket, page_title: "Version History", tid: tid, versions: versions, current: current, flash_msg: nil)}
  end

  defp list_versions(tid) do
    release = TenantRuntime.release_path(tid)
    case File.ls(release) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "v"))
        |> Enum.sort_by(&extract_version/1, :desc)
        |> Enum.map(fn dir ->
          full = Path.join(release, dir)
          stat = try do File.stat!(full, time: :posix) rescue _ -> %{mtime: 0} end
          %{version: dir, mtime: stat.mtime}
        end)
      _ -> []
    end
  end

  defp get_current(tid) do
    current_link = Path.join([TenantRuntime.release_path(tid), "_current"])
    case File.read_link(current_link) do
      {:ok, path} -> Path.basename(path)
      _ -> nil
    end
  end

  defp extract_version("v" <> rest) do
    case Integer.parse(rest) do {n, _} -> n; :error -> 0 end
  end
  defp extract_version(_), do: 0

  def handle_event("rollback", %{"version" => version}, socket) do
    tid = socket.assigns.tid
    current_link = Path.join([TenantRuntime.release_path(tid), "_current"])
    target = Path.join([TenantRuntime.release_path(tid), version])
    if File.exists?(target) do
      File.rm!(current_link)
      File.ln_s!(target, current_link)
      {:noreply, assign(socket, current: version, flash_msg: "Rolled back to #{version}")}
    else
      {:noreply, assign(socket, flash_msg: "Version #{version} not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6">
      <h1 class="text-xl font-bold text-gray-900 mb-4">版本历史</h1>
      <div :if={@flash_msg} class="text-sm text-green-700 bg-green-50 rounded px-3 py-2 mb-4">{@flash_msg}</div>
      <div class="space-y-2">
        <%= for v <- @versions do %>
          <div class={["flex items-center justify-between rounded-lg border px-4 py-3",
            v.version == @current && "border-blue-300 bg-blue-50",
            v.version != @current && "border-gray-200 bg-white"]}>
            <div>
              <span class="font-mono text-sm font-medium"><%= v.version %></span>
              <span :if={v.version == @current} class="ml-2 text-xs bg-blue-600 text-white px-1.5 py-0.5 rounded">current</span>
            </div>
            <button :if={v.version != @current}
              phx-click="rollback" phx-value-version={v.version}
              phx-confirm={"确认回滚到 #{v.version} ？"}
              class="rounded border border-red-300 text-red-700 px-3 py-1 text-xs hover:bg-red-50">
              Rollback
            </button>
          </div>
        <% end %>
      </div>
      <p :if={@versions == []} class="text-sm text-gray-400">No published versions yet.</p>
    </div>
    """
  end
end
