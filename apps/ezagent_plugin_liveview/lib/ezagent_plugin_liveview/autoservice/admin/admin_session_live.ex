defmodule EzagentPluginLiveview.AutoService.Admin.AdminSessionLive do
  @moduledoc """
  Admin Session — chat-based admin interface at `/admin/autoservice/agent`.

  Reuses ChatUI components for a conversational admin experience.
  Renders admin cards (CR status, publish results) inline with the
  chat history. Dispatches commands to `Ezagent.Behavior.AdminAgent`.

  Chat messages are kept in-process (no persistence) — this is a
  stateless admin tool session.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginAutoservice.ChatUI

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin Agent",
       messages: [
         %{
           id: "welcome",
           mine?: false,
           label: "Admin Agent",
           text: "你好，我是 Admin Agent。你可以用自然语言命令来管理租户。\n\n试试：\n- \"发布 CR for tenant my-tenant\"\n- \"检查状态 my-tenant\"",
           at: DateTime.utc_now()
         }
       ],
       compose_nonce: 0,
       cards: [],
       error: nil
     )}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      # Add user message
      user_msg = %{
        id: "user-#{System.unique_integer([:positive])}",
        mine?: true,
        label: "我",
        text: text,
        at: DateTime.utc_now()
      }

      # Dispatch to AdminAgent behavior
      {reply_text, cards} = process_admin_command(text)

      # Add agent reply
      agent_msg = %{
        id: "agent-#{System.unique_integer([:positive])}",
        mine?: false,
        label: "Admin Agent",
        text: reply_text,
        at: DateTime.utc_now()
      }

      {:noreply,
       socket
       |> update(:messages, fn ms -> ms ++ [user_msg, agent_msg] end)
       |> assign(:cards, cards)
       |> update(:compose_nonce, &(&1 + 1))}
    end
  end

  defp process_admin_command(text) do
    if Code.ensure_loaded?(Ezagent.Behavior.AdminAgent) do
      case Ezagent.Behavior.AdminAgent.handle_process_command(%{text: text}, %{}) do
        {:ok, %{reply: reply} = result, _effects} ->
          cards = build_result_cards(result)
          {reply, cards}

        _ ->
          {"命令处理出错，请重试。", []}
      end
    else
      # Fallback when AdminAgent behavior is not loaded
      cond do
        String.contains?(text, "发布") ->
          {"CR 发布命令已接收 (离线模式: AdminAgent Behavior 未加载)。", [
            %{title: "CR Publish", status: "pending", detail: text}
          ]}

        String.contains?(text, "检查") ->
          {"状态检查命令已接收 (离线模式: AdminAgent Behavior 未加载)。", [
            %{title: "CR Status", status: "pending", detail: text}
          ]}

        true ->
          {"命令未识别: #{text}\n\n支持的命令：\n- 包含 \"发布\" → 发布 CR\n- 包含 \"检查\" → 检查状态", []}
      end
    end
  end

  defp build_result_cards(%{action: action} = result) do
    case action do
      :publish_cr ->
        tid = Map.get(result, :tid, "unknown")
        success? = String.contains?(Map.get(result, :reply, ""), "成功")

        [
          %{
            title: "CR Publish",
            status: if(success?, do: "success", else: "failed"),
            tid: tid,
            detail: Map.get(result, :reply, "")
          }
        ]

      :check_status ->
        tid = Map.get(result, :tid, "unknown")

        [
          %{
            title: "CR Status",
            status: "info",
            tid: tid,
            detail: Map.get(result, :reply, "")
          }
        ]

      _ ->
        []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl h-[calc(100vh-2rem)] my-4 flex flex-col rounded-xl border border-zinc-200 dark:border-zinc-700 shadow-sm overflow-hidden bg-white dark:bg-zinc-950">
      <header class="px-4 py-3 border-b border-purple-700 bg-purple-600 text-white flex items-center justify-between">
        <div>
          <h1 class="font-semibold">Admin Agent</h1>
          <p class="text-xs opacity-80">自然语言管理命令</p>
        </div>
        <a
          href="/admin/autoservice"
          class="text-xs bg-white/20 hover:bg-white/30 text-white rounded px-2 py-1 transition-colors"
        >
          &larr; Dashboard
        </a>
      </header>

      <%!-- Admin cards --%>
      <%= if @cards != [] do %>
        <div class="px-4 py-3 bg-gray-50 dark:bg-zinc-900 border-b border-gray-200 dark:border-zinc-800 space-y-2">
          <%= for card <- @cards do %>
            <div class={[
              "rounded-lg border px-3 py-2 text-sm",
              card_status_border(card.status)
            ]}>
              <div class="flex items-center gap-2">
                <span class={["text-xs font-medium rounded px-1.5 py-0.5", card_status_badge(card.status)]}>
                  {card.title}
                </span>
                <span :if={Map.has_key?(card, :tid)} class="text-xs text-gray-400 dark:text-zinc-500 font-mono">
                  {card.tid}
                </span>
              </div>
              <p class="text-xs text-gray-600 dark:text-zinc-400 mt-1">{card.detail}</p>
            </div>
          <% end %>
        </div>
      <% end %>

      <ChatUI.message_list messages={@messages} empty_hint="输入命令开始..." />
      <ChatUI.composer nonce={@compose_nonce} placeholder="输入管理命令，如: 发布 CR for my-tenant..." />
    </div>
    """
  end

  # --- card styling helpers ---

  defp card_status_border("success"), do: "border-green-300 dark:border-green-700 bg-green-50 dark:bg-green-950/30"
  defp card_status_border("failed"), do: "border-red-300 dark:border-red-700 bg-red-50 dark:bg-red-950/30"
  defp card_status_border("pending"), do: "border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/30"
  defp card_status_border("info"), do: "border-blue-300 dark:border-blue-700 bg-blue-50 dark:bg-blue-950/30"
  defp card_status_border(_), do: "border-gray-200 dark:border-zinc-700 bg-white dark:bg-zinc-900"

  defp card_status_badge("success"), do: "bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-300"
  defp card_status_badge("failed"), do: "bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-300"
  defp card_status_badge("pending"), do: "bg-amber-100 dark:bg-amber-900 text-amber-700 dark:text-amber-300"
  defp card_status_badge("info"), do: "bg-blue-100 dark:bg-blue-900 text-blue-700 dark:text-blue-300"
  defp card_status_badge(_), do: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400"
end
