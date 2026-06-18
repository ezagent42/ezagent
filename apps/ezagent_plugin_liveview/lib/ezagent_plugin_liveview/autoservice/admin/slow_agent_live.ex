defmodule EzagentPluginLiveview.AutoService.Admin.SlowAgentLive do
  @moduledoc """
  Slow Agent configuration page — STOP-GAP.

  The route `/admin/autoservice/tenants/:tid/agent/slow` was added during the
  admin-UI v2 migration but the page module was never created (caused an
  `UndefinedFunctionError`). This stop-gap renders the chrome + the current
  working entry points so the route no longer 500s.

  TODO (#4 full): merge the archived soul_editor / slot_editor / skill_manager /
  kb_manager into a single 6-tab editor (Soul / Slots / Skills / KB / Diff /
  Preview) sharing one assign.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok, assign(socket, page_title: "Slow Agent", tid: tid)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen text-zinc-900 dark:text-zinc-100">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-3xl">
          <h1 class="text-xl font-bold mb-1">🧠 Slow Agent 配置</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400 mb-6">
            Soul · Skills · KB · Slots — 完整功能 agent
          </p>

          <div class="rounded-xl border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950 p-5">
            <h2 class="font-semibold text-amber-900 dark:text-amber-200">
              🚧 统一编辑器建设中
            </h2>
            <p class="text-sm text-amber-800 dark:text-amber-300 mt-1">
              6-tab 编辑器(Soul / Slots / Skills / KB / Diff / Preview)即将上线。
              当前可通过以下入口编辑该租户内容:
            </p>
            <div class="mt-4 flex flex-wrap gap-2">
              <a
                href={"/admin/autoservice/tenants/#{@tid}/init"}
                class="rounded-lg bg-amber-600 text-white px-4 py-2 text-sm font-medium hover:bg-amber-700"
              >
                🚀 Init Wizard（Soul / Slots / KB）
              </a>
              <a
                href={"/admin/autoservice/tenants/#{@tid}/debug"}
                class="rounded-lg border border-amber-400 text-amber-700 dark:text-amber-300 px-4 py-2 text-sm font-medium hover:bg-amber-100 dark:hover:bg-amber-900"
              >
                🧪 Debug Agent
              </a>
              <a
                href={"/admin/autoservice/tenants/#{@tid}"}
                class="rounded-lg border border-amber-400 text-amber-700 dark:text-amber-300 px-4 py-2 text-sm font-medium hover:bg-amber-100 dark:hover:bg-amber-900"
              >
                ← Overview
              </a>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
