defmodule EzagentPluginLiveview.AutoService.Admin.DebugAgentLive do
  @moduledoc """
  Debug Agent — sandbox vs release response comparison tool.

  Left panel: Customer message input + Send button.
  Right panel: Sandbox response vs Release response side-by-side comparison.

  Accessible at `/admin/autoservice/tenants/:tid/debug`.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer}
  alias EzagentPluginContent.Skill.SkillIndexer

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Debug Agent",
       tid: tid,
       message: "",
       sandbox_response: nil,
       release_response: nil
     )}
  end

  @impl true
  def handle_event("test", %{"message" => message}, socket) do
    tid = socket.assigns.tid

    # Generate sandbox preview
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    base_dir = TenantRuntime.base_dir()
    role = "customer"
    templates = SoulLoader.load(priv_dir, tid, role)
    slots = read_slots(tid, role)
    sandbox = SoulRenderer.full_claude_md(templates, slots, SkillIndexer.build(base_dir, tid, role))

    # Generate release preview
    release_dir = Path.join([TenantRuntime.release_path(tid), "_current"])
    release_slots = read_release_slots(tid, role, release_dir)
    release =
      if release_slots,
        do: SoulRenderer.full_claude_md(templates, release_slots, ""),
        else: "(no release)"

    {:noreply,
     assign(socket,
       message: message,
       sandbox_response: sandbox,
       release_response: release
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-4">🧪 Debug Agent</h1>
        <div class="mb-4">
          <form phx-submit="test" class="flex gap-2">
            <input
              type="text"
              name="message"
              value={@message}
              placeholder="输入测试客户消息..."
              class="flex-1 rounded border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
            <button
              type="submit"
              class="rounded bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700"
            >
              Send
            </button>
          </form>
        </div>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <h3 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">
              🔧 Sandbox Response
            </h3>
            <pre class="text-xs text-gray-800 dark:text-zinc-200 bg-gray-50 dark:bg-zinc-900 border border-gray-200 dark:border-zinc-800 rounded p-3 overflow-auto max-h-96"><%= @sandbox_response || "(输入消息后点击 Send)" %></pre>
          </div>
          <div>
            <h3 class="text-sm font-medium text-gray-700 dark:text-zinc-300 mb-2">
              📦 Release Response
            </h3>
            <pre class="text-xs text-gray-800 dark:text-zinc-200 bg-gray-50 dark:bg-zinc-900 border border-gray-200 dark:border-zinc-800 rounded p-3 overflow-auto max-h-96"><%= @release_response || "(输入消息后点击 Send)" %></pre>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_slots(tid, role) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{role}.yaml"])

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp read_release_slots(_tid, role, release_dir) do
    path = Path.join([release_dir, "slots", "#{role}.yaml"])

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, map} when is_map(map) -> map
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
