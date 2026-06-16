defmodule EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar do
  @moduledoc """
  Shared sidebar navigation for all admin pages.

  Displays a consistent left-side navigation menu with links to:
  Soul Editor, Slot Editor, Skill Manager, KB Manager, CR Dashboard,
  Version History, and Dashboard.
  """
  use Phoenix.Component

  attr :tid, :string, required: true

  def admin_sidebar(assigns) do
    ~H"""
    <nav class="w-48 flex-shrink-0 border-r border-gray-200 dark:border-zinc-800 bg-gray-50 dark:bg-zinc-950 p-3 space-y-1 min-h-screen">
      <div class="text-xs uppercase tracking-wider text-gray-500 dark:text-zinc-400 mb-2 px-2">Content</div>
      <a href={"/admin/autoservice/tenants/#{@tid}/soul"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📝</span> Soul 编辑
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/soul/slots"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🏷️</span> Slot 编辑
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/skills"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📚</span> Skill 管理
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/kb"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🗄️</span> KB 管理
      </a>
      <div class="border-t border-gray-200 dark:border-zinc-700 my-2"></div>
      <a href={"/admin/autoservice/tenants/#{@tid}/cr"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>🔄</span> CR Dashboard
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}/versions"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📋</span> 版本历史
      </a>
      <a href={"/admin/autoservice/tenants/#{@tid}"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-200 dark:hover:bg-zinc-800 text-gray-700 dark:text-zinc-300">
        <span>📊</span> Dashboard
      </a>
    </nav>
    """
  end
end
