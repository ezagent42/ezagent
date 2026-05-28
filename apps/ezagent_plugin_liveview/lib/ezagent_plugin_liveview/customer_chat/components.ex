defmodule EzagentPluginLiveview.CustomerChat.Components do
  @moduledoc """
  Shared HEEx function components for the customer chat surface, plus
  the pure `message_to_row/2` mapper. Used by `CustomerChat.ChatLive`;
  reusable by the operator detail view later.
  """
  use Phoenix.Component

  @type row :: %{
          id: String.t(),
          kind: :customer | :agent | :operator | :other,
          text: String.t(),
          notice?: boolean()
        }

  @spec message_to_row(Ezagent.Message.t(), String.t()) :: row()
  def message_to_row(%Ezagent.Message{} = msg, customer_uri_str) do
    sender_str = URI.to_string(msg.sender)

    %{
      id: msg.id,
      kind: classify(sender_str, customer_uri_str),
      text: body_text(msg.body),
      notice?: takeover_notice?(msg.body)
    }
  end

  defp classify(sender, customer) when sender == customer, do: :customer

  defp classify(sender, _customer) do
    cond do
      String.starts_with?(sender, "entity://agent/") -> :agent
      String.starts_with?(sender, "entity://user/") -> :operator
      true -> :other
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp takeover_notice?(%{is_takeover_notice: true}), do: true
  defp takeover_notice?(%{"is_takeover_notice" => true}), do: true
  defp takeover_notice?(_), do: false

  # ---- components -------------------------------------------------------

  attr :row, :map, required: true

  def bubble(assigns) do
    # Single root element (Phoenix function-component idiom). One of the
    # two inner branches renders depending on @row.notice?.
    ~H"""
    <div class="contents">
      <div :if={@row.notice?} class="text-center my-3">
        <span class="inline-block text-xs px-3 py-1 rounded-full bg-amber-100 text-amber-800">
          {@row.text}
        </span>
      </div>
      <div :if={!@row.notice?} class={[
        "max-w-[80%] px-3 py-2 rounded-2xl text-sm whitespace-pre-wrap break-words mb-2",
        @row.kind == :customer && "ml-auto bg-[var(--cc-primary)] text-white",
        @row.kind == :agent && "mr-auto bg-zinc-100 text-zinc-900",
        @row.kind == :operator && "mr-auto bg-emerald-100 text-emerald-900",
        @row.kind == :other && "mr-auto bg-zinc-50 text-zinc-600"
      ]}>
        <div :if={@row.kind == :operator} class="text-[10px] text-emerald-700 mb-0.5">客服</div>
        {@row.text}
      </div>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :empty?, :boolean, default: false
  attr :welcome, :string, required: true

  def message_list(assigns) do
    # Welcome bubble lives OUTSIDE the phx-update="stream" container: a
    # static child inside a stream container gets misplaced when stream
    # items are inserted (it rendered below the messages). Keep the stream
    # container holding only stream items.
    ~H"""
    <div class="flex flex-col">
      <div :if={@empty?} id="cc-welcome" class="mr-auto max-w-[80%] px-3 py-2 rounded-2xl text-sm bg-zinc-100 text-zinc-900 mb-2">
        {@welcome}
      </div>
      <div id="cc-messages" phx-update="stream" class="flex flex-col">
        <div :for={{dom_id, row} <- @messages} id={dom_id}>
          <.bubble row={row} />
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :placeholder, :string, required: true
  attr :disabled, :boolean, default: false

  def composer(assigns) do
    ~H"""
    <.form for={@form} phx-submit="send" class="flex gap-2 p-3 border-t border-zinc-200 bg-white">
      <input
        type="text"
        name="chat[text]"
        id="cc-input"
        value={@form[:text].value}
        autocomplete="off"
        disabled={@disabled}
        placeholder={@placeholder}
        class="flex-1 px-3 py-2 text-sm border border-zinc-300 rounded-full focus:outline-none focus:ring-2 focus:ring-[var(--cc-primary)] disabled:bg-zinc-100 disabled:cursor-not-allowed"
      />
      <button type="submit" disabled={@disabled} class="px-4 py-2 text-sm rounded-full text-white bg-[var(--cc-primary)] disabled:opacity-50 disabled:cursor-not-allowed">
        Send
      </button>
    </.form>
    """
  end
end
