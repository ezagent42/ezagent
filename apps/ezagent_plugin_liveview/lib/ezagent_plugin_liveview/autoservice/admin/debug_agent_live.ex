defmodule EzagentPluginLiveview.AutoService.Admin.DebugAgentLive do
  @moduledoc """
  Debug Agent — sandbox vs release comparison + chat test.

  - Agent selector: Fast Agent / Slow Agent, sandbox / release
  - View modes: Side-by-Side | Diff Only | Chat Test
  - Line-level diff with color-coded added/removed highlighting
  - Generates full CLAUDE.md composition for both sandbox and release

  Accessible at `/admin/autoservice/tenants/:tid/debug`.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer}
  alias EzagentPluginContent.Skill.SkillIndexer
  alias EzagentPluginContent.DiffEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Debug Agent",
       tid: tid,
       agent: "slow",
       message: "",
       mode: :diff,
       sandbox_response: nil,
       release_response: nil,
       diff_result: nil,
       error_flash: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("test", %{"message" => message}, socket) do
    tid = socket.assigns.tid
    agent = socket.assigns.agent
    role = "customer"

    {sandbox, release} = generate_responses(tid, role, agent)
    diff = compute_diff(release, sandbox)

    {:noreply,
     assign(socket,
       message: message,
       sandbox_response: sandbox,
       release_response: release,
       diff_result: diff,
       error_flash: nil
     )}
  end

  def handle_event("switch_agent", %{"agent" => agent}, socket) do
    {:noreply, assign(socket, agent: agent, sandbox_response: nil, release_response: nil, diff_result: nil)}
  end

  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode))}
  end

  # ---------------------------------------------------------------------------
  # Response generation
  # ---------------------------------------------------------------------------

  defp generate_responses(tid, role, agent) do
    priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
    templates = SoulLoader.load(priv_dir, tid, role)

    # Sandbox
    sandbox_slots = read_sandbox_slots(tid, role)
    sandbox_index = SkillIndexer.build(TenantRuntime.base_dir(), tid, role)
    sandbox_content = SoulRenderer.full_claude_md(templates, sandbox_slots, sandbox_index)

    # Release
    release_dir = Path.join([TenantRuntime.release_path(tid), "_current"])
    release_slots = read_release_slots(release_dir, role)
    release_content =
      if release_slots,
        do: SoulRenderer.full_claude_md(templates, release_slots, ""),
        else: "(no published release)"

    {sandbox_content, release_content}
  end

  defp compute_diff(nil, _sandbox), do: %{added: [], removed: [], unchanged: []}

  defp compute_diff(release, sandbox) do
    if Code.ensure_loaded?(DiffEngine) and function_exported?(DiffEngine, :diff, 2) do
      DiffEngine.diff(release, sandbox)
    else
      # Fallback: simple set-based diff
      rel_lines = String.split(release, "\n")
      san_lines = String.split(sandbox, "\n")
      %{added: san_lines -- rel_lines, removed: rel_lines -- san_lines, unchanged: san_lines -- (san_lines -- rel_lines)}
    end
  end

  # ---------------------------------------------------------------------------
  # Slot readers
  # ---------------------------------------------------------------------------

  defp read_sandbox_slots(tid, role) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "slots", "#{role}.yaml"])
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
      _ -> %{}
    end
  end

  defp read_release_slots(release_dir, role) do
    path = Path.join([release_dir, "slots", "#{role}.yaml"])
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, map} when is_map(map) -> map
          _ -> nil
        end
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp mode_tab_css(:side_by_side, :side_by_side), do: "border-b-2 border-blue-600 text-blue-600 font-medium"
  defp mode_tab_css(:diff, :diff), do: "border-b-2 border-blue-600 text-blue-600 font-medium"
  defp mode_tab_css(:chat, :chat), do: "border-b-2 border-blue-600 text-blue-600 font-medium"
  defp mode_tab_css(_, _), do: "text-gray-500 hover:text-gray-700"

  defp diff_line_css("+"), do: "bg-green-50 dark:bg-green-950 text-green-800 dark:text-green-300"
  defp diff_line_css("-"), do: "bg-red-50 dark:bg-red-950 text-red-800 dark:text-red-300"
  defp diff_line_css(_), do: ""

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-7xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-1">🧪 Debug Agent</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400 mb-4">
            Compare sandbox vs release — check how changes affect the agent's CLAUDE.md composition
          </p>

          <%!-- Agent selector --%>
          <div class="flex items-center gap-4 mb-4">
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-500">Agent:</span>
              <button
                phx-click="switch_agent" phx-value-agent="slow"
                class={[
                  "px-3 py-1.5 text-xs rounded-lg border font-medium transition",
                  @agent == "slow" && "bg-purple-100 border-purple-300 text-purple-700",
                  @agent != "slow" && "border-gray-200 text-gray-600 hover:bg-gray-50"
                ]}
              >🧠 Slow Agent</button>
              <button
                phx-click="switch_agent" phx-value-agent="fast"
                class={[
                  "px-3 py-1.5 text-xs rounded-lg border font-medium transition",
                  @agent == "fast" && "bg-amber-100 border-amber-300 text-amber-700",
                  @agent != "fast" && "border-gray-200 text-gray-600 hover:bg-gray-50"
                ]}
              >⚡ Fast Agent</button>
            </div>

            <%!-- Mode switcher --%>
            <div class="flex items-center gap-2 ml-auto">
              <span class="text-xs text-gray-500">View:</span>
              <button phx-click="switch_mode" phx-value-mode="diff"
                class={["px-3 py-1.5 text-xs rounded-lg border transition", mode_tab_css(@mode, :diff)]}>
                Δ Diff Only</button>
              <button phx-click="switch_mode" phx-value-mode="side_by_side"
                class={["px-3 py-1.5 text-xs rounded-lg border transition", mode_tab_css(@mode, :side_by_side)]}>
                Side-by-Side</button>
            </div>
          </div>

          <%!-- Input --%>
          <div class="mb-4">
            <form phx-submit="test" class="flex gap-2">
              <input
                type="text" name="message"
                value={@message}
                placeholder={"输入测试消息 — 对比 #{if @agent == "slow", do: "Slow", else: "Fast"} Agent sandbox vs release 的 CLAUDE.md 合成"}
                class="flex-1 rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2.5 text-sm bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
              />
              <button type="submit"
                class="rounded-lg bg-blue-600 text-white px-6 py-2.5 text-sm font-medium hover:bg-blue-700 transition">
                🔍 Compare
              </button>
            </form>
          </div>

          <%!-- Empty state --%>
          <div :if={is_nil(@sandbox_response)} class="text-center py-16 text-gray-400">
            <div class="text-5xl mb-4">🧪</div>
            <p class="text-sm">输入测试消息，查看 sandbox 和 release 的 CLAUDE.md 合成差异</p>
            <p class="text-xs mt-2 text-gray-300">支持 Slow Agent（Soul+Skills+KB+Slots）和 Fast Agent（Prompt only）</p>
          </div>

          <%!-- Diff Only mode --%>
          <div :if={@sandbox_response && @mode == :diff} class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
            <div class="flex items-center justify-between px-4 py-2.5 bg-gray-50 dark:bg-zinc-800 border-b border-gray-200 dark:border-zinc-700">
              <span class="text-sm font-semibold text-gray-700 dark:text-zinc-300">
                Δ Diff — <%= if Enum.empty?(@diff_result.added) && Enum.empty?(@diff_result.removed), do: "✅ No changes", else: "#{length(@diff_result.added)} added, #{length(@diff_result.removed)} removed" %>
              </span>
              <div class="flex items-center gap-2 text-[10px]">
                <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-sm bg-green-100 border border-green-300"></span> sandbox</span>
                <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-sm bg-red-100 border border-red-300"></span> release</span>
              </div>
            </div>
            <div class="p-3 font-mono text-xs max-h-[60vh] overflow-auto leading-relaxed">
              <%= if Enum.empty?(@diff_result.added) && Enum.empty?(@diff_result.removed) do %>
                <p class="text-gray-400 italic text-center py-8">Sandbox and release produce identical CLAUDE.md</p>
              <% else %>
                <div :for={line <- @diff_result.added} class={["px-2 py-0.5 rounded-sm", diff_line_css("+")]}>
                  <span class="text-green-500 font-bold select-none mr-2">+</span><%= line %>
                </div>
                <div :for={line <- @diff_result.removed} class={["px-2 py-0.5 rounded-sm", diff_line_css("-")]}>
                  <span class="text-red-500 font-bold select-none mr-2">-</span><%= line %>
                </div>
                <div :for={line <- @diff_result.unchanged} class="px-2 py-0.5 text-gray-400">
                  <span class="select-none mr-2">&nbsp;</span><%= line %>
                </div>
              <% end %>
            </div>

            <%!-- Summary --%>
            <div :if={!Enum.empty?(@diff_result.added) || !Enum.empty?(@diff_result.removed)} class="px-4 py-3 bg-amber-50 dark:bg-amber-950 border-t border-amber-200 dark:border-amber-800 flex items-center justify-between">
              <span class="text-xs text-amber-700 dark:text-amber-400">
                ⚡ #{length(@diff_result.added)} lines added to sandbox, #{length(@diff_result.removed)} lines removed from release. Review changes before publishing.
              </span>
              <a
                href={"/admin/autoservice/tenants/#{@tid}/cr"}
                class="text-xs bg-amber-600 text-white px-3 py-1.5 rounded hover:bg-amber-700 font-medium"
              >🔄 Review & Publish →</a>
            </div>
          </div>

          <%!-- Side-by-Side mode --%>
          <div :if={@sandbox_response && @mode == :side_by_side} class="grid grid-cols-2 gap-4">
            <div class="rounded-xl border-2 border-amber-300 overflow-hidden">
              <div class="px-4 py-2.5 bg-amber-50 dark:bg-amber-950 border-b border-amber-200">
                <span class="text-sm font-semibold text-amber-800">🧪 Sandbox</span>
                <span class="text-[10px] text-amber-600 ml-2">unpublished</span>
              </div>
              <pre class="p-3 text-xs font-mono text-gray-800 dark:text-zinc-200 overflow-auto max-h-[60vh] leading-relaxed"><%= @sandbox_response %></pre>
            </div>
            <div class="rounded-xl border-2 border-green-300 overflow-hidden">
              <div class="px-4 py-2.5 bg-green-50 dark:bg-green-950 border-b border-green-200">
                <span class="text-sm font-semibold text-green-800">✅ Release</span>
                <span class="text-[10px] text-green-600 ml-2">published</span>
              </div>
              <pre class="p-3 text-xs font-mono text-gray-800 dark:text-zinc-200 overflow-auto max-h-[60vh] leading-relaxed"><%= @release_response %></pre>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
