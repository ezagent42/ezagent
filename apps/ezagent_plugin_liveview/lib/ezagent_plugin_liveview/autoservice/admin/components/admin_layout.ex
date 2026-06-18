defmodule EzagentPluginLiveview.AutoService.Admin.Components.AdminLayout do
  @moduledoc """
  Shared chrome for the per-tenant AutoService admin pages — a LiveView
  `:layout` so the top bar + sidebar are applied site-wide and no page can
  "lose" them. Wired via `live_session ..., layout: {__MODULE__, :shell}`.

  Reads `@tid` (every per-tenant admin LV assigns it) + `@current_entity_uri`
  (set by LiveAuth). The LV's rendered content arrives as `@inner_content`.
  """
  use Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  def shell(assigns) do
    assigns =
      assigns
      |> assign_new(:tid, fn -> nil end)
      |> assign(:tids, list_tids())
      |> assign_new(:current_entity_uri, fn -> nil end)

    ~H"""
    <div class="min-h-screen text-zinc-900 dark:text-zinc-100">
      <%!-- Global top bar --%>
      <header class="flex items-center justify-between border-b border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-4 h-12">
        <a href="/admin/autoservice" class="flex items-center gap-2">
          <span class="text-lg">⚡</span>
          <span class="font-bold">ezagent Admin</span>
          <span class="text-[10px] bg-blue-100 text-blue-700 px-2 py-0.5 rounded-full">AutoService v2</span>
        </a>
        <div class="flex items-center gap-3 text-sm">
          <label class="text-gray-500 dark:text-zinc-400">Tenant:</label>
          <select
            onchange="if(this.value){window.location.href='/admin/autoservice/tenants/'+this.value}"
            class="text-sm font-medium border border-gray-300 dark:border-zinc-700 rounded px-2 py-1 bg-white dark:bg-zinc-900"
          >
            <option :for={t <- @tids} value={t} selected={t == @tid}>{t}</option>
          </select>
          <span class="text-gray-300 dark:text-zinc-600">|</span>
          <span class="text-gray-500 dark:text-zinc-400">{user_label(@current_entity_uri)}</span>
        </div>
      </header>

      <div class="flex">
        <.admin_sidebar :if={@tid} tid={@tid} />
        <main class="flex-1 px-6 py-6">
          {@inner_content}
        </main>
      </div>
    </div>
    """
  end

  defp user_label(nil), do: "—"

  defp user_label(uri) do
    s = if is_binary(uri), do: uri, else: URI.to_string(uri)
    # entity://system/user/admin -> admin@system
    case Regex.run(~r{entity://([^/]+)/user/([^/?#]+)}, s) do
      [_, ws, user] -> "#{user}@#{ws}"
      _ -> s
    end
  rescue
    _ -> "—"
  end

  defp list_tids do
    import Ecto.Query
    alias Ezagent.Socialware.ConfigPointer
    alias EzagentCore.Repo

    Repo.all(from(p in ConfigPointer, where: like(p.key, "tenant:%:config"), select: p.key))
    |> Enum.map(fn key -> key |> String.split(":") |> Enum.at(1) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    _ -> []
  end
end
