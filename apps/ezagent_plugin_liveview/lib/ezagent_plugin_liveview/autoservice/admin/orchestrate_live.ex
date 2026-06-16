defmodule EzagentPluginLiveview.AutoService.Admin.OrchestrateLive do
  @moduledoc """
  Orchestrate — Routeset visual editor for Agent routing chain.

  Visualizes and edits routing rules:
    Customer → Fast Agent → Slow Agent → Operator

  Reads/writes `Ezagent.RoutingRegistry` via `MentionRouting` table.

  Accessible at `/admin/autoservice/tenants/:tid/orchestrate`.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginAutoservice.Refresh

  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    rules = load_rules(tid)

    {:ok,
     assign(socket,
       page_title: "Orchestrate",
       tid: tid,
       rules: rules,
       editing_id: nil,
       edit_form: %{},
       saved_flash: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) do
    idx = String.to_integer(id)
    rule = Enum.at(socket.assigns.rules, idx - 1) || %{}

    {:noreply,
     assign(socket,
       editing_id: idx,
       edit_form: %{
         "condition" => Map.get(rule, :condition, ""),
         "timeout_s" => Map.get(rule, :timeout_s, 30),
         "fallback" => Map.get(rule, :fallback, "")
       }
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, edit_form: %{})}
  end

  def handle_event("save_rule", params, socket) do
    tid = socket.assigns.tid
    mod = Ezagent.RoutingRegistry

    if Code.ensure_loaded?(mod) do
      rule = Enum.at(socket.assigns.rules, socket.assigns.editing_id - 1) || %{}
      updated = Map.merge(rule, %{
        condition: params["condition"] || "",
        timeout_s: String.to_integer(params["timeout_s"] || "30"),
        fallback: params["fallback"] || ""
      })

      apply(mod, :put, [@routing_table, Map.get(updated, :key, "cs_#{tid}_#{socket.assigns.editing_id}"), updated])
      Refresh.after_publish(tid)
    end

    {:noreply,
     assign(socket,
       rules: load_rules(tid),
       editing_id: nil,
       edit_form: %{},
       saved_flash: "✅ Route rule saved — agents refreshed"
     )}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_rules(tid) do
    mod = Ezagent.RoutingRegistry
    if Code.ensure_loaded?(mod) and function_exported?(mod, :list_all, 1) do
      case apply(mod, :list_all, [@routing_table]) do
        entries when is_list(entries) and entries != [] ->
          entries
          |> Enum.map(fn e ->
            if is_map(e), do: Map.new(e), else: %{}
          end)
          |> Enum.sort_by(&Map.get(&1, :position, 0))

        _ -> default_rules(tid)
      end
    else
      default_rules(tid)
    end
  rescue
    _ -> default_rules(tid)
  end

  defp default_rules(tid) do
    [
      %{id: 1, position: 1, name: "Customer → Fast Agent", condition: "first contact", timeout_s: 5, fallback: "Slow Agent", key: "cs_#{tid}_fast", enabled: true},
      %{id: 2, position: 2, name: "Fast → Slow Agent", condition: "confidence < 0.8 or timeout", timeout_s: 30, fallback: "Operator", key: "cs_#{tid}_slow", enabled: true},
      %{id: 3, position: 3, name: "Slow → Operator", condition: "user requests human or escalation", timeout_s: 0, fallback: nil, key: "cs_#{tid}_operator", enabled: true}
    ]
  end

  defp node_css(1), do: "border-blue-400 bg-blue-50 dark:bg-blue-950"
  defp node_css(2), do: "border-amber-400 bg-amber-50 dark:bg-amber-950"
  defp node_css(3), do: "border-purple-400 bg-purple-50 dark:bg-purple-950"
  defp node_css(4), do: "border-gray-300 bg-gray-50 dark:bg-gray-900"

  defp node_icon(1), do: "💬 Customer Message"
  defp node_icon(2), do: "⚡ Fast Agent"
  defp node_icon(3), do: "🧠 Slow Agent"
  defp node_icon(4), do: "👤 Operator"

  defp node_desc(1), do: "Entry point — any message from customer"
  defp node_desc(2), do: "Quick reply via DeepSeek ACK prompt (5s timeout)"
  defp node_desc(3), do: "Deep thinking via Claude + Soul + Skills + KB (30s timeout)"
  defp node_desc(4), do: "Human takeover — no timeout"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <.admin_sidebar tid={@tid} />
      <main class="flex-1 p-6">
        <div class="max-w-3xl mx-auto">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100 mb-1">🔀 Routeset</h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400 mb-4">
            Customer → Fast → Slow → Operator routing chain. Edit conditions, timeouts, and fallbacks.
          </p>

          <%!-- Saved flash --%>
          <div :if={@saved_flash} class="text-sm text-green-700 dark:text-green-400 bg-green-50 dark:bg-green-950 border border-green-200 rounded-lg px-3 py-2 mb-4">
            {@saved_flash}
          </div>

          <%!-- Route chain --%>
          <div class="space-y-0">
            <%= for {rule, idx} <- Enum.with_index(@rules, 1) do %>
              <div class={["rounded-xl border-2 p-4 transition", node_css(idx)]}>
                <div class="flex items-center justify-between">
                  <div>
                    <div class="font-semibold text-sm text-gray-900 dark:text-zinc-100"><%= node_icon(idx) %></div>
                    <div class="text-xs text-gray-500 mt-0.5"><%= node_desc(idx) %></div>
                    <div class="flex items-center gap-3 mt-1 text-[10px] text-gray-400">
                      <span>Condition: <code class="bg-white dark:bg-zinc-800 px-1 rounded"><%= Map.get(rule, :condition, "—") %></code></span>
                      <span>Timeout: <%= Map.get(rule, :timeout_s, "—") %>s</span>
                      <%= if Map.get(rule, :fallback) do %>
                        <span>→ Fallback: <%= Map.get(rule, :fallback) %></span>
                      <% end %>
                    </div>
                  </div>
                  <button
                    phx-click="edit" phx-value-id={"#{idx}"}
                    class="text-xs border border-gray-300 dark:border-zinc-600 rounded-lg px-3 py-1.5 hover:bg-gray-100 dark:hover:bg-zinc-800 transition shrink-0"
                  >✏️ Edit</button>
                </div>

                <%!-- Inline edit form --%>
                <%= if @editing_id == idx do %>
                  <div class="mt-4 p-3 bg-white dark:bg-zinc-900 rounded-lg border border-gray-200 dark:border-zinc-700">
                    <form phx-submit="save_rule" class="space-y-3 text-sm">
                      <div>
                        <label class="block text-xs font-medium text-gray-500 mb-1">Condition (when to trigger this route)</label>
                        <input type="text" name="condition" value={@edit_form["condition"]}
                          placeholder="e.g., confidence < 0.8 or timeout"
                          class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm bg-white dark:bg-zinc-800 focus:outline-none focus:ring-2 focus:ring-blue-400" />
                      </div>
                      <div class="grid grid-cols-2 gap-3">
                        <div>
                          <label class="block text-xs font-medium text-gray-500 mb-1">Timeout (seconds)</label>
                          <input type="number" name="timeout_s" value={@edit_form["timeout_s"]}
                            class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm bg-white dark:bg-zinc-800 focus:outline-none focus:ring-2 focus:ring-blue-400" />
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-gray-500 mb-1">Fallback route</label>
                          <input type="text" name="fallback" value={@edit_form["fallback"]}
                            placeholder="e.g., Slow Agent"
                            class="w-full rounded-lg border border-gray-300 dark:border-zinc-700 px-3 py-2 text-sm bg-white dark:bg-zinc-800 focus:outline-none focus:ring-2 focus:ring-blue-400" />
                        </div>
                      </div>
                      <div class="flex justify-end gap-2 pt-2">
                        <button type="button" phx-click="cancel_edit"
                          class="px-4 py-1.5 text-sm border border-gray-300 dark:border-zinc-600 rounded-lg hover:bg-gray-100 dark:hover:bg-zinc-800">Cancel</button>
                        <button type="submit"
                          class="px-4 py-1.5 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium">💾 Save Rule</button>
                      </div>
                    </form>
                  </div>
                <% end %>
              </div>

              <%!-- Arrow between nodes --%>
              <%= if idx < length(@rules) do %>
                <div class="flex justify-center py-1">
                  <span class="text-xs text-gray-400">
                    │ <%= Map.get(rule, :fallback, "unresolved →") %>
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
