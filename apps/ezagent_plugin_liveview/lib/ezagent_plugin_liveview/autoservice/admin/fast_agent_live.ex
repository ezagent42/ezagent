defmodule EzagentPluginLiveview.AutoService.Admin.FastAgentLive do
  @moduledoc """
  Fast Agent configuration — edits sandbox/config/fast_ack_prompt.md.
  Three tabs: Source | Diff (sandbox vs release) | Preview (rendered)

  Accessible at `/admin/autoservice/tenants/:tid/agent/fast`.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.{SoulLoader, SoulRenderer}
  alias EzagentPluginContent.DiffEngine
  alias EzagentPluginCr.CrEngine

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    role = "customer"
    sandbox_content = read_prompt(tid)
    release_content = read_release_prompt(tid)
    diff = compute_diff(release_content, sandbox_content)

    preview = if sandbox_content != "" do
      priv_dir = Application.app_dir(:ezagent_plugin_content, "priv")
      templates = SoulLoader.load(priv_dir, tid, role)
      SoulRenderer.full_claude_md(templates, %{}, "")
    else
      ""
    end

    {:ok,
     assign(socket,
       page_title: "Fast Agent",
       tid: tid,
       active_tab: :source,
       content: sandbox_content,
       release_content: release_content,
       diff: diff,
       preview: preview,
       saved_flash: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("save", %{"content" => content}, socket) do
    tid = socket.assigns.tid
    path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    CrEngine.record_file_change(tid, "config/fast_ack_prompt.md")

    release_content = read_release_prompt(tid)
    diff = compute_diff(release_content, content)

    {:noreply,
     assign(socket,
       content: content,
       diff: diff,
       saved_flash: "💾 Saved to sandbox — config/fast_ack_prompt.md"
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab), saved_flash: nil)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_prompt(tid) do
    path = Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])
    case File.read(path), do: ({:ok, c} -> c; _ -> "")
  end

  defp read_release_prompt(tid) do
    path = Path.join([TenantRuntime.release_path(tid), "_current", "config", "fast_ack_prompt.md"])
    case File.read(path), do: ({:ok, c} -> c; _ -> nil)
  end

  defp compute_diff(nil, sandbox) do
    sandbox_lines = String.split(sandbox || "", "\n")
    %{added: sandbox_lines, removed: [], unchanged: []}
  end

  defp compute_diff(release, sandbox) when is_binary(release) and is_binary(sandbox) do
    if Code.ensure_loaded?(DiffEngine) and function_exported?(DiffEngine, :diff, 2) do
      DiffEngine.diff(release, sandbox)
    else
      rel_lines = String.split(release, "\n")
      san_lines = String.split(sandbox, "\n")
      %{added: san_lines -- rel_lines, removed: rel_lines -- san_lines, unchanged: san_lines -- (san_lines -- rel_lines)}
    end
  end

  # ---------------------------------------------------------------------------
  # Tab helpers
  # ---------------------------------------------------------------------------

  defp tab_css(:source, :source), do: "border-b-2 border-blue-600 text-blue-600 font-semibold"
  defp tab_css(:diff, :diff), do: "border-b-2 border-blue-600 text-blue-600 font-semibold"
  defp tab_css(:preview, :preview), do: "border-b-2 border-blue-600 text-blue-600 font-semibold"
  defp tab_css(_, _), do: "text-gray-500 hover:text-gray-700"

  defp diff_line("+"), do: "bg-green-50 dark:bg-green-950 text-green-800 dark:text-green-300"
  defp diff_line("-"), do: "bg-red-50 dark:bg-red-950 text-red-800 dark:text-red-300"
  defp diff_line(_), do: ""

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
        <div class="max-w-4xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-1">⚡ Fast Agent 配置</h1>
          <p class="text-xs text-gray-500 dark:text-zinc-400 mb-2">
            📂 <code class="bg-gray-100 dark:bg-zinc-800 px-1.5 py-0.5 rounded text-xs">sandbox/config/fast_ack_prompt.md</code>
          </p>

          <%!-- Saved flash --%>
          <div :if={@saved_flash} class="text-sm text-green-700 dark:text-green-400 bg-green-50 dark:bg-green-950 border border-green-200 rounded-lg px-3 py-2 mb-3 flex items-center gap-2">
            <span>{@saved_flash}</span>
            <span class="text-[10px] text-green-500">· CR tracked</span>
          </div>

          <%!-- Tabs --%>
          <div class="flex gap-0 border-b border-gray-200 dark:border-zinc-700 mb-4">
            <button phx-click="switch_tab" phx-value-tab="source" class={["px-4 py-2 text-sm transition", tab_css(@active_tab, :source)]}>🧬 Source</button>
            <button phx-click="switch_tab" phx-value-tab="diff" class={["px-4 py-2 text-sm transition", tab_css(@active_tab, :diff)]}>
              Δ Diff
              <span :if={!Enum.empty?(@diff.added) || !Enum.empty?(@diff.removed)} class="ml-1 text-[10px] bg-amber-100 text-amber-700 px-1 rounded-full">
                +#{length(@diff.added)} -#{length(@diff.removed)}
              </span>
            </button>
            <button phx-click="switch_tab" phx-value-tab="preview" class={["px-4 py-2 text-sm transition", tab_css(@active_tab, :preview)]}>👁️ Preview</button>
          </div>

          <%!-- Source Tab --%>
          <%= if @active_tab == :source do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-50 dark:bg-zinc-800 border-b border-gray-200 dark:border-zinc-700 flex justify-between items-center">
                <span class="text-sm font-semibold text-gray-700 dark:text-zinc-300">Fast Agent ACK Prompt</span>
                <span class="text-[10px] text-gray-400">DeepSeek quick-acknowledgment</span>
              </div>
              <div class="p-4">
                <form phx-submit="save">
                  <textarea
                    name="content"
                    rows="20"
                    class="w-full font-mono text-sm border border-gray-300 dark:border-zinc-700 rounded-lg p-4 bg-white dark:bg-zinc-900 text-gray-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-400"
                  ><%= @content %></textarea>
                  <div class="mt-3 flex justify-between items-center">
                    <span class="text-[10px] text-gray-400">编辑完成后保存到 sandbox，自动 CR 追踪</span>
                    <button type="submit" class="rounded-lg bg-amber-600 text-white px-5 py-2 text-sm font-medium hover:bg-amber-700 transition">
                      💾 Save to Sandbox
                    </button>
                  </div>
                </form>
              </div>
            </div>
          <% end %>

          <%!-- Diff Tab --%>
          <%= if @active_tab == :diff do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-50 dark:bg-zinc-800 border-b flex justify-between items-center">
                <span class="text-sm font-semibold text-gray-700 dark:text-zinc-300">Δ Sandbox vs Release</span>
                <div class="flex items-center gap-2 text-[10px]">
                  <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-sm bg-green-100 border border-green-300"></span> sandbox</span>
                  <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-sm bg-red-100 border border-red-300"></span> release</span>
                </div>
              </div>
              <div class="p-3 font-mono text-xs max-h-[60vh] overflow-auto leading-relaxed">
                <%= if Enum.empty?(@diff.added) && Enum.empty?(@diff.removed) do %>
                  <p class="text-gray-400 italic text-center py-12">✅ Sandbox matches release — no changes</p>
                <% else %>
                  <div :for={line <- @diff.added} class={["px-2 py-0.5 rounded-sm flex", diff_line("+")]}>
                    <span class="text-green-500 font-bold select-none w-5 shrink-0">+</span><span><%= line %></span>
                  </div>
                  <div :for={line <- @diff.removed} class={["px-2 py-0.5 rounded-sm flex", diff_line("-")]}>
                    <span class="text-red-500 font-bold select-none w-5 shrink-0">-</span><span><%= line %></span>
                  </div>
                  <div :for={line <- @diff.unchanged} class="px-2 py-0.5 flex text-gray-400">
                    <span class="select-none w-5 shrink-0">&nbsp;</span><span><%= line %></span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Preview Tab --%>
          <%= if @active_tab == :preview do %>
            <div class="rounded-xl border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden">
              <div class="px-4 py-2.5 bg-gray-50 dark:bg-zinc-800 border-b">
                <span class="text-sm font-semibold text-gray-700 dark:text-zinc-300">👁️ Full CLAUDE.md Composition</span>
              </div>
              <pre class="p-4 text-xs font-mono text-gray-800 dark:text-zinc-200 max-h-[60vh] overflow-auto whitespace-pre-wrap"><%= @preview %></pre>
            </div>
          <% end %>
        </div>
      </div>
    """
  end
end
