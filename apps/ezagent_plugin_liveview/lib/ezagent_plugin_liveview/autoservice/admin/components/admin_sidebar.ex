defmodule EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar do
  use Phoenix.Component
  attr(:tid, :string, required: true)

  def admin_sidebar(assigns) do
    tids =
      [assigns[:tid] | list_tids()]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()

    assigns = assign(assigns, :tids, tids)

    ~H"""
    <nav class="w-48 flex-shrink-0 border-r border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 p-3 space-y-1 min-h-screen">
      <%!-- Tenant switcher --%>
      <div class="px-2 pb-3 mb-1 border-b border-gray-200 dark:border-zinc-700">
        <div class="text-[10px] uppercase tracking-wider text-gray-400 dark:text-zinc-500 mb-1">
          Tenant
        </div>
        <select
          onchange="if(this.value){window.location.href='/admin/autoservice/tenants/'+this.value}"
          class="w-full text-sm font-medium border border-gray-300 dark:border-zinc-700 rounded px-2 py-1 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100"
        >
          <option :for={t <- @tids} value={t} selected={t == @tid}>{t}</option>
        </select>
        <a href="/admin/autoservice" class="block mt-2 text-[11px] text-blue-600 hover:underline">
          ← All Tenants
        </a>
      </div>

      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">
        Config Agents
      </div>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/agent/fast"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>⚡</span> Fast Agent
      </a>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/agent/slow"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>🧠</span> Slow Agent
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">
        Orchestrate
      </div>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/orchestrate"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>🔀</span> Routeset
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">
        Verify & Release
      </div>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/debug"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>🧪</span> Debug Agent
      </a>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/cr"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>🔄</span> CR Review
      </a>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/versions"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>📋</span> History
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">
        Config
      </div>
      <a
        href={"/admin/autoservice/tenants/#{@tid}"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>📊</span> Overview
      </a>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/init"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>🚀</span> Init Wizard
      </a>
      <a
        href={"/admin/autoservice/tenants/#{@tid}/operators"}
        class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300"
      >
        <span>👥</span> Operators
      </a>
    </nav>
    """
  end

  # All known tenant ids, from the ConfigPointer rows (same source the master
  # dashboard uses). Cheap query; degrades to [] on any error.
  defp list_tids do
    import Ecto.Query
    alias Ezagent.Socialware.ConfigPointer
    alias EzagentCore.Repo

    Repo.all(
      from(p in ConfigPointer,
        where: like(p.key, "tenant:%:config"),
        select: p.key
      )
    )
    |> Enum.map(fn key -> key |> String.split(":") |> Enum.at(1) end)
  rescue
    _ -> []
  end
end
