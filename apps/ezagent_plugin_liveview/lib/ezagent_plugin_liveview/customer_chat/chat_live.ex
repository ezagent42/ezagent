defmodule EzagentPluginLiveview.CustomerChat.ChatLive do
  @moduledoc """
  Public customer chat page at `/chat/:tenant`. No login. The customer
  is a synthetic `entity://user/<tenant>/customer_<id>`.

  Read path: subscribe to the session events topic.
  Write path: dispatch `chat.send` via Bootstrap (mention-synthesized
  to the cc agent). Operator takeover messages + the takeover notice
  arrive on the SAME topic (no SSE 120 s window — this is the C3-tension
  fix).

  Heavy bootstrap (cc spawn + EagerBridge) runs only after `connected?`
  via a self-sent `:bootstrap` message, so the dead render is instant.
  """
  use Phoenix.LiveView
  import EzagentPluginLiveview.CustomerChat.Components
  alias EzagentPluginLiveview.CustomerChat.{Bootstrap, Components, Theme}
  require Logger

  @message_limit 50

  @impl true
  def mount(%{"tenant" => tenant} = params, _session, socket) do
    embed? = Map.get(params, "embed") == "1"
    customer_id = Map.get(params, "cid") || rand_customer_id()
    conv_id = Map.get(params, "conv") || Bootstrap.generate_conv_id()

    session_uri = Bootstrap.session_uri_for(tenant, conv_id)
    session_uri_str = URI.to_string(session_uri)
    customer_uri = Bootstrap.customer_uri_for(tenant, customer_id)
    theme = Theme.for_tenant(tenant)

    socket =
      socket
      |> assign(:tenant, tenant)
      |> assign(:embed?, embed?)
      |> assign(:theme, theme)
      |> assign(:customer_id, customer_id)
      |> assign(:conv_id, conv_id)
      |> assign(:session_uri, session_uri)
      |> assign(:session_uri_str, session_uri_str)
      |> assign(:customer_uri_str, URI.to_string(customer_uri))
      |> assign(:mode, :auto)
      |> assign(:status, :connecting)
      |> assign(:error, nil)
      |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
      |> assign(:page_title, theme.title)

    if connected?(socket) do
      topic = Ezagent.Behavior.Chat.session_events_topic(session_uri)
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      send(self(), :bootstrap)

      history = load_history(session_uri, URI.to_string(customer_uri))

      {:ok,
       socket
       |> stream(:messages, history)
       |> assign(:messages_empty?, history == [])}
    else
      {:ok,
       socket
       |> stream(:messages, [])
       |> assign(:messages_empty?, true)}
    end
  end

  @impl true
  def handle_info(:bootstrap, socket) do
    %{tenant: tenant, conv_id: conv_id, session_uri: session_uri} = socket.assigns
    :ok = Bootstrap.ensure_session(tenant, conv_id)

    case Bootstrap.ensure_cc_for_conv(tenant, conv_id, session_uri) do
      {:ok, agent_uri} ->
        # Read the current mode now that the session is ensured. Done
        # here (async) rather than in mount so a slow/blocking dispatch
        # never stalls the first render. Resumed sessions mid-takeover
        # surface their real mode; fresh sessions read :auto.
        {:noreply,
         socket
         |> assign(:status, :ready)
         |> assign(:mode, lookup_mode(session_uri))
         |> assign(:cc_agent_uri, agent_uri)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> assign(:error, "Could not reach the assistant. Please try again.")
         |> tap(fn _ -> Logger.warning("ChatLive bootstrap failed: #{inspect(reason)}") end)}
    end
  end

  def handle_info({:chat_message, src, %Ezagent.Message{} = msg}, socket) do
    if URI.to_string(src) == socket.assigns.session_uri_str do
      row = Components.message_to_row(msg, socket.assigns.customer_uri_str)
      mode = if row.notice?, do: :takeover, else: socket.assigns.mode

      {:noreply,
       socket
       |> assign(:messages_empty?, false)
       |> assign(:mode, mode)
       |> stream_insert(:messages, row, at: -1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send", %{"chat" => %{"text" => text}}, socket)
      when is_binary(text) and text != "" do
    case socket.assigns do
      %{status: :ready, cc_agent_uri: agent_uri} ->
        customer_uri = URI.parse(socket.assigns.customer_uri_str)
        msg = Bootstrap.customer_message(customer_uri, String.trim(text), agent_uri)
        Bootstrap.dispatch_chat_send(socket.assigns.session_uri, msg)

        # optimistically echo my own message (broadcast also delivers it,
        # but stream dedups by dom id from msg.id)
        row = Components.message_to_row(msg, socket.assigns.customer_uri_str)

        {:noreply,
         socket
         |> assign(:messages_empty?, false)
         |> stream_insert(:messages, row, at: -1)
         |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))}

      _not_ready ->
        {:noreply, socket}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class={["flex flex-col", @embed? && "h-screen bg-transparent" || "h-screen max-w-lg mx-auto border-x border-zinc-200"]}
      style={"--cc-primary: #{@theme.primary_color};"}
    >
      <header :if={!@embed?} class="flex items-center gap-2 px-4 py-3 border-b border-zinc-200 bg-white">
        <img :if={@theme.logo_url} src={@theme.logo_url} class="h-6 w-6 rounded" />
        <span class="font-semibold text-zinc-900">{@theme.title}</span>
        <span :if={@mode == :takeover} class="ml-auto text-xs px-2 py-0.5 rounded-full bg-amber-100 text-amber-800">
          客服已接管
        </span>
      </header>

      <div class="flex-1 overflow-y-auto px-4 py-3 bg-zinc-50">
        <.message_list messages={@streams.messages} empty?={@messages_empty?} welcome={@theme.welcome_message} />
        <p :if={@status == :connecting} class="text-center text-xs text-zinc-400 mt-2">connecting…</p>
        <p :if={@status == :error} class="text-center text-xs text-rose-500 mt-2">{@error}</p>
      </div>

      <.composer form={@compose_form} placeholder={@theme.placeholder} disabled={@status != :ready} />
    </div>
    """
  end

  # ---- helpers ----------------------------------------------------------

  defp load_history(session_uri, customer_uri_str) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
    |> Enum.map(&Components.message_to_row(&1, customer_uri_str))
  end

  defp lookup_mode(session_uri) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=mode.get")
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: admin_uri, caps: admin_caps, reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, %{mode: mode}} -> mode
      _ -> :auto
    end
  end

  defp rand_customer_id do
    "anon_" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
  end
end
