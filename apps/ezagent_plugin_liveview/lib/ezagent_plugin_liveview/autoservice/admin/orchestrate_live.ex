defmodule EzagentPluginLiveview.AutoService.Admin.OrchestrateLive do
  @moduledoc """
  Orchestrate — Routeset visual editor.

  Visualizes the agent routing chain:
    Customer -> Fast Agent (DeepSeek) -> Slow Agent (Claude) -> Operator (Human)

  Accessible at `/admin/autoservice/tenants/:tid/orchestrate`.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok, assign(socket, page_title: "Orchestrate", tid: tid)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-3xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-4">🔀 Routeset — Agent 路由链</h1>
          <div class="flex items-center justify-center gap-4 py-12">
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 text-center w-36">
              <div class="text-3xl mb-2">👤</div>
              <div class="font-medium text-sm text-gray-900 dark:text-zinc-100">Customer</div>
              <div class="text-xs text-gray-400 mt-1">消息入口</div>
            </div>
            <div class="text-2xl text-gray-400">→</div>
            <div class="rounded-xl border border-blue-300 bg-blue-50 dark:bg-blue-950 p-6 text-center w-36">
              <div class="text-3xl mb-2">⚡</div>
              <div class="font-medium text-sm text-blue-900 dark:text-blue-100">Fast Agent</div>
              <div class="text-xs text-blue-600 dark:text-blue-400 mt-1">DeepSeek ACK</div>
            </div>
            <div class="text-2xl text-gray-400">→</div>
            <div class="rounded-xl border border-purple-300 bg-purple-50 dark:bg-purple-950 p-6 text-center w-36">
              <div class="text-3xl mb-2">🧠</div>
              <div class="font-medium text-sm text-purple-900 dark:text-purple-100">Slow Agent</div>
              <div class="text-xs text-purple-600 dark:text-purple-400 mt-1">Claude KB</div>
            </div>
            <div class="text-2xl text-gray-400">→</div>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 text-center w-36">
              <div class="text-3xl mb-2">👨‍💼</div>
              <div class="font-medium text-sm text-gray-900 dark:text-zinc-100">Operator</div>
              <div class="text-xs text-gray-400 mt-1">人工接管</div>
            </div>
          </div>
          <p class="text-xs text-gray-500 text-center mt-4">Customer 消息 → Fast Agent 即时 ACK → Slow Agent 知识库回复 → Operator 监控/接管</p>
        </div>
      </main>
    </div>
    """
  end
end
