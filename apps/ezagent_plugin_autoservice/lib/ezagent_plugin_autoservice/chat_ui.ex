defmodule EzagentPluginAutoservice.ChatUI do
  @moduledoc """
  Shared function components for the customer + operator chat surfaces.

  A "row" is a precomputed map (built relative to the viewer) so the
  template stays logic-free:

      %{id: String.t(), mine?: boolean(), label: String.t(),
        text: String.t(), at: DateTime.t()}
  """
  use Phoenix.Component

  @doc "Build a render row from a Message, relative to the viewing entity."
  @spec row(Ezagent.Message.t(), URI.t()) :: map()
  def row(%Ezagent.Message{} = m, %URI{} = viewer_uri) do
    mine? = URI.to_string(m.sender) == URI.to_string(viewer_uri)

    %{
      id: m.id,
      mine?: mine?,
      label: label_for(m.sender, mine?),
      text: m.body["text"] || m.body[:text] || "",
      at: m.inserted_at
    }
  end

  defp label_for(_sender, true), do: "我"
  defp label_for(%URI{scheme: "entity", host: "agent"}, _), do: "AI 客服"
  defp label_for(%URI{scheme: "system"}, _), do: "AI 客服"
  defp label_for(%URI{scheme: "entity", host: "user"}, _), do: "人工客服"
  defp label_for(_sender, _), do: "系统"

  attr :messages, :list, required: true
  attr :empty_hint, :string, default: "暂无消息"

  def message_list(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-4 space-y-3 bg-gray-50">
      <p :if={@messages == []} class="text-center text-sm text-gray-400 mt-8">{@empty_hint}</p>
      <div :for={m <- @messages} class={["flex", (m.mine? && "justify-end") || "justify-start"]}>
        <div class={["max-w-[72%] rounded-2xl px-3 py-2 text-sm shadow-sm", bubble_class(m)]}>
          <div class="text-[11px] opacity-60 mb-0.5">{m.label}</div>
          <div class="whitespace-pre-wrap break-words">{m.text}</div>
        </div>
      </div>
    </div>
    """
  end

  defp bubble_class(%{mine?: true}), do: "bg-blue-600 text-white"
  defp bubble_class(%{label: "AI 客服"}), do: "bg-white border border-gray-200 text-gray-800"
  defp bubble_class(%{label: "人工客服"}), do: "bg-emerald-100 text-emerald-900"
  defp bubble_class(_), do: "bg-gray-200 text-gray-700"

  attr :placeholder, :string, default: "输入消息…"
  attr :nonce, :integer, default: 0
  attr :disabled, :boolean, default: false

  def composer(assigns) do
    ~H"""
    <form id={"autoservice-composer-#{@nonce}"} phx-submit="send" class="flex gap-2 p-3 border-t bg-white">
      <input
        type="text"
        name="text"
        value=""
        placeholder={@placeholder}
        autocomplete="off"
        disabled={@disabled}
        class="flex-1 rounded-lg border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100"
      />
      <button
        type="submit"
        disabled={@disabled}
        class="rounded-lg bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700 disabled:opacity-50"
      >
        发送
      </button>
    </form>
    """
  end
end
