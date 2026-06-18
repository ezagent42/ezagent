defmodule EzagentPluginLiveview.AutoService.Admin.SlowAgentLive do
  @moduledoc """
  Slow Agent configuration — a tabbed shell that composes the per-module
  editors.

  The backend models a slow-agent config as four independent modules
  (souls / slots / skills / kb) that compose into one CLAUDE.md. Writes are
  per-module; Debug Agent runs the composed whole; CR Review owns the diff /
  revert / publish of the bundled change. So this page is a thin shell: each
  tab `live_render`s the matching standalone editor LiveView, and the diff is
  intentionally NOT a tab here — it lives in CR Review (linked from the banner).

  Accessible at `/admin/autoservice/tenants/:tid/agent/slow`.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginCr.CrEngine

  @tabs [
    {:soul, "🧬 Soul", EzagentPluginLiveview.AutoService.Admin.SoulEditorLive},
    {:slots, "🎛 Slots", EzagentPluginLiveview.AutoService.Admin.SlotEditorLive},
    {:skills, "🛠 Skills", EzagentPluginLiveview.AutoService.Admin.SkillManagerLive},
    {:kb, "📚 KB", EzagentPluginLiveview.AutoService.Admin.KbManagerLive},
    {:preview, "👁 Preview", EzagentPluginLiveview.AutoService.Admin.SandboxPreviewLive}
  ]

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Slow Agent",
       tid: tid,
       active_tab: :soul,
       pending_slow: pending_slow_count(tid)
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  # Re-read the pending count when a child reports a save (children that want
  # the banner to refresh can `send(self(), :cr_changed)` to their parent).
  @impl true
  def handle_info(:cr_changed, socket) do
    {:noreply, assign(socket, pending_slow: pending_slow_count(socket.assigns.tid))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tabs, do: @tabs

  defp active_module(tab), do: Enum.find_value(@tabs, fn {t, _l, m} -> t == tab && m end)

  defp pending_slow_count(tid) do
    cr = load_active_cr(tid)
    items = get_in(cr || %{}, ["sandbox_diff", "items"]) || []
    Enum.count(items, fn item -> not String.starts_with?(item_path(item), "config/") end)
  rescue
    _ -> 0
  end

  defp load_active_cr(tid) do
    if Code.ensure_loaded?(CrEngine) and function_exported?(CrEngine, :ensure_active_cr, 1) do
      case CrEngine.ensure_active_cr(tid),
        do: (
          {:ok, cr} -> cr
          _ -> nil
        )
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp item_path(%{"path" => p}) when is_binary(p), do: p
  defp item_path(%{"file" => p}) when is_binary(p), do: p
  defp item_path(p) when is_binary(p), do: p
  defp item_path(_), do: ""

  defp tab_css(tab, tab), do: "border-b-2 border-blue-600 text-blue-600 font-semibold"
  defp tab_css(_, _), do: "text-gray-500 hover:text-gray-700 dark:hover:text-zinc-300"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="max-w-5xl">
        <div class="flex items-start justify-between mb-1">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">🧠 Slow Agent 配置</h1>
          <a
            :if={@pending_slow > 0}
            href={"/admin/autoservice/tenants/#{@tid}/cr"}
            class="text-xs bg-amber-50 dark:bg-amber-950 text-amber-700 dark:text-amber-300 border border-amber-300 dark:border-amber-700 rounded-lg px-3 py-1.5 hover:bg-amber-100 dark:hover:bg-amber-900 transition flex items-center gap-1.5"
          >
            🔄 {@pending_slow} 处未发布改动 → CR Review
          </a>
        </div>
        <p class="text-sm text-gray-500 dark:text-zinc-400 mb-4">
          Soul · Slots · Skills · KB — 逐模块编辑，组合成完整 CLAUDE.md
        </p>

        <%!-- Module tabs --%>
        <div class="flex gap-0 border-b border-gray-200 dark:border-zinc-700 mb-4">
          <button
            :for={{t, label, _m} <- tabs()}
            phx-click="switch_tab"
            phx-value-tab={t}
            class={["px-4 py-2 text-sm transition", tab_css(@active_tab, t)]}
          >
            {label}
          </button>
        </div>

        <%!-- Active module editor (nested LiveView) --%>
        {live_render(@socket, active_module(@active_tab),
          id: "slow-tab-#{@active_tab}",
          session: %{"tid" => @tid}
        )}
      </div>
    </div>
    """
  end
end
