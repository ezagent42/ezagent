defmodule EzagentPluginAutoservice.CustomerLive do
  @moduledoc """
  Customer-facing chat — `/autoservice`.

  The customer lands here after login (`current_entity_uri` is their
  User URI), is joined to their own service session
  (`session://cs/<ws>/<name>`), and chats with the fast (DeepSeek)
  agent. They see the opening greeting on load. Operator messages
  (human handoff) appear inline as "人工客服".
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias Ezagent.Behavior.Chat
  alias EzagentPluginAutoservice.{ChatUI, CustomerSession}

  require Logger

  @msg_limit 100

  @impl true
  def mount(_params, _session, socket) do
    customer_uri = socket.assigns.current_entity_uri

    case CustomerSession.ensure_joined(customer_uri) do
      {:ok, session_uri} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))
        end

        caps = Ezagent.Identity.list_caps_for(customer_uri)
        messages = load_messages(session_uri, customer_uri)

        {:ok,
         assign(socket,
           page_title: "在线客服",
           customer_uri: customer_uri,
           session_uri: session_uri,
           caps: caps,
           messages: messages,
           compose_nonce: 0,
           error: nil
         )}

      {:error, reason} ->
        Logger.warning(
          "CustomerLive: ensure_joined failed for #{URI.to_string(customer_uri)}: #{inspect(reason)}"
        )

        {:ok,
         assign(socket,
           page_title: "在线客服",
           customer_uri: customer_uri,
           session_uri: nil,
           caps: MapSet.new(),
           messages: [],
           compose_nonce: 0,
           error: "暂时无法进入会话,请联系管理员先为你开通客服会话。"
         )}
    end
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.session_uri) ->
        {:noreply, socket}

      true ->
        msg = Ezagent.Message.new(socket.assigns.customer_uri, %{text: text, attachments: []})
        target = URI.new!("#{URI.to_string(socket.assigns.session_uri)}?action=chat.send")

        _ =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :cast,
            args: %{message: msg},
            ctx: %{caller: socket.assigns.customer_uri, caps: socket.assigns.caps, reply: :ignore}
          })

        # The message comes back via the session-events broadcast (which
        # we subscribe to), so we don't append optimistically — just
        # reset the composer input by bumping its nonce.
        {:noreply, update(socket, :compose_nonce, &(&1 + 1))}
    end
  end

  @impl true
  def handle_info({:chat_message, _session_uri, %Ezagent.Message{} = msg}, socket) do
    row = ChatUI.row(msg, socket.assigns.customer_uri)
    {:noreply, update(socket, :messages, fn ms -> ms ++ [row] end)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_messages(session_uri, viewer_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@msg_limit)
    |> Enum.reverse()
    |> Enum.map(&ChatUI.row(&1, viewer_uri))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl h-[calc(100vh-2rem)] my-4 flex flex-col rounded-xl border border-gray-200 shadow-sm overflow-hidden bg-white">
      <header class="px-4 py-3 border-b bg-blue-600 text-white">
        <h1 class="font-semibold">在线客服</h1>
        <p class="text-xs opacity-80">{URI.to_string(@customer_uri)}</p>
      </header>

      <p :if={@error} class="m-4 rounded bg-amber-50 border border-amber-200 px-3 py-2 text-sm text-amber-800">
        {@error}
      </p>

      <ChatUI.message_list :if={!@error} messages={@messages} empty_hint="正在为你接入客服…" />
      <ChatUI.composer :if={!@error} nonce={@compose_nonce} placeholder="输入你的问题…" />
    </div>
    """
  end
end
