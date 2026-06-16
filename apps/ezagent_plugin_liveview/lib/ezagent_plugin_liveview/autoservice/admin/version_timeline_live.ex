defmodule EzagentPluginLiveview.AutoService.Admin.VersionTimelineLive do
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar
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
    release_path = TenantRuntime.release_path(tid)
    sandbox_path = TenantRuntime.sandbox_path(tid)

    source = Path.join([release_path, version])

    # Copy release files back to sandbox
    ["souls", "slots", "skills", "kb", "config"]
    |> Enum.each(fn dir ->
      src = Path.join([source, dir])
      dst = Path.join([sandbox_path, dir])
      if File.exists?(src) do
        File.rm_rf!(dst)
        File.cp_r!(src, dst)
      end
    end)

    # Flip symlink
    current = Path.join([release_path, "_current"])
    if File.exists?(current) do
      File.rm!(current)
    end
    File.ln_s!(source, current)

    {:noreply, assign(socket, current: version, flash_msg: "已回滚到 #{version}，sandbox 已恢复")}
  rescue
    e -> {:noreply, assign(socket, flash_msg: "回滚失败: #{Exception.message(e)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-3xl mx-auto">
      <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-4">版本历史</h1>
      <div :if={@flash_msg} class="text-sm text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-3 py-2 mb-4">{@flash_msg}</div>
      <div class="space-y-2">
        <%= for v <- @versions do %>
          <div class={["flex items-center justify-between rounded-lg border px-4 py-3",
            v.version == @current && "border-blue-300 dark:border-blue-700 bg-blue-50 dark:bg-blue-950",
            v.version != @current && "border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900"]}>
            <div>
              <span class="font-mono text-sm font-medium text-gray-900 dark:text-zinc-100"><%= v.version %></span>
              <span :if={v.version == @current} class="ml-2 text-xs bg-blue-600 text-white px-1.5 py-0.5 rounded">current</span>
            </div>
            <button :if={v.version != @current}
              phx-click="rollback" phx-value-version={v.version}
              phx-confirm={"确认回滚到 #{v.version} ？"}
              class="rounded border border-red-300 dark:border-red-800 text-red-700 dark:text-red-400 px-3 py-1 text-xs hover:bg-red-50 dark:hover:bg-red-950">
              Rollback
            </button>
          </div>
        <% end %>
      </div>
      <p :if={@versions == []} class="text-sm text-gray-400 dark:text-zinc-500">No published versions yet.</p>
        </div>
      </main>
    </div>
    """
  end
end
