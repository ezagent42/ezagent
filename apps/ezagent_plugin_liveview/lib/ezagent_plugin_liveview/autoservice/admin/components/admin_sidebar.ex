defmodule EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar do
  use Phoenix.Component
  attr :tid, :string, required: true

  def admin_sidebar(assigns) do
    ~H"""
    <nav class="w-48 flex-shrink-0 border-r border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 p-3 space-y-1 min-h-screen">
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Config Agents</div>
      <a href={"/admin/autoservice/tenants/#{@tid}/agent/fast"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>⚡</span> Fast Agent
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/agent/slow"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🧠</span> Slow Agent
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Orchestrate</div>
      <a href={"/admin/autoservice/tenants/#{@tid}/orchestrate"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🔀</span> Routeset
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Verify & Release</div>
      <a href={"/admin/autoservice/tenants/#{@tid}/debug"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🧪</span> Debug Agent
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/cr"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🔄</span> CR Review
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/versions"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📋</span> History
      </a>

      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Config</div>
      <a href={"/admin/autoservice/tenants/#{@tid}"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📊</span> Overview
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/init"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🚀</span> Init Wizard
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/operators"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>👥</span> Operators
      </a>
    </nav>
    """
  end
end
