defmodule EzagentPluginLiveview.AutoService.Admin.FastAgentLive do
  @moduledoc """
  Fast Agent configuration page — edits sandbox/config/fast_ack_prompt.md,
  the DeepSeek instant-acknowledgement prompt used when the primary model is busy.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    prompt_path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])

    content =
      case File.read(prompt_path) do
        {:ok, c} -> c
        _ -> ""
      end

    {:ok, assign(socket, page_title: "Fast Agent", tid: tid, content: content, saved_flash: nil)}
  end

  def handle_event("save", %{"content" => content}, socket) do
    tid = socket.assigns.tid
    path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    CrEngine.record_file_change(tid, "config/fast_ack_prompt.md")
    {:noreply, assign(socket, content: content, saved_flash: "已保存")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-4xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-2">⚡ Fast Agent 配置</h1>
          <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
            sandbox/config/fast_ack_prompt.md — DeepSeek 即时安抚回复提示词
          </p>
          <div
            :if={@saved_flash}
            class="text-sm text-green-700 bg-green-50 dark:bg-green-950 rounded px-3 py-1.5 mb-3"
          >
            {@saved_flash}
          </div>
          <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">Fast Agent ACK Prompt</h2>
            </div>
            <div class="p-4">
              <form phx-submit="save">
                <textarea
                  name="content"
                  rows="16"
                  class="w-full font-mono text-sm border border-gray-300 dark:border-zinc-700 rounded p-3 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                ><%= @content %></textarea>
                <div class="mt-3 flex justify-end">
                  <button
                    type="submit"
                    class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700"
                  >
                    保存
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
