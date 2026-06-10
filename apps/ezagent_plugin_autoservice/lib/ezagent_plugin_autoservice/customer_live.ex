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

  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAutoservice.{ChatUI, CustomerSession}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    customer_uri = socket.assigns.current_entity_uri

    case CustomerSession.ensure_joined(customer_uri) do
      {:ok, session_uri} ->
        # Live wiring (Stage 1): lazily ensure the per-session CS turn
        # adapter on THIS server node — the deterministic prod starter
        # (a seed BEAM's adapter dies with the seed). Cheap + idempotent:
        # a registry hit returns the running pid. Best-effort — a legacy
        # (non-socialware) session simply has no turns for it to drive.
        _ = EzagentPluginAutoservice.SocialwareCS.ensure_adapter(session_uri, customer_uri)

        # DD5-b: the customer's ONLY message source is the visibility-gated
        # CustomerFeed (settled, `customer_visible` messages). The raw
        # `Chat.session_events_topic` broadcast is NOT subscribed — it carries
        # `operator_only` drafts unfiltered, which must never reach the customer.
        workspace_uri = Ezagent.Capability.workspace_of(session_uri)
        feed_token = CustomerAuth.issue_token(session_uri, workspace_uri)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(EzagentCore.PubSub, CustomerFeed.topic(session_uri))
        end

        caps = Ezagent.Identity.list_caps_for(customer_uri)
        messages = load_customer_messages(session_uri, feed_token, customer_uri)

        {:ok,
         assign(socket,
           page_title: "在线客服",
           customer_uri: customer_uri,
           session_uri: session_uri,
           feed_token: feed_token,
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
           feed_token: nil,
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

        # The customer's own message surfaces back through the gated
        # CustomerFeed (DD5-b) once its turn settles, so we don't append
        # optimistically — just reset the composer input by bumping its nonce.
        {:noreply, update(socket, :compose_nonce, &(&1 + 1))}
    end
  end

  @impl true
  def handle_info({:customer_delivery, _payload}, socket) do
    # A settlement committed new customer-visible messages. Re-snapshot the
    # gated feed (single source of truth) rather than trusting the payload —
    # the snapshot already applies visibility filtering.
    messages =
      load_customer_messages(
        socket.assigns.session_uri,
        socket.assigns.feed_token,
        socket.assigns.customer_uri
      )

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @doc """
  Load the customer-visible chat rows for `session_uri` from the gated
  `CustomerFeed` (DD5-b). This is the customer surface's SOLE message source —
  `CustomerFeed.snapshot/2` returns only settled, `customer_visible` messages,
  so `operator_only` drafts never reach the customer. Returns `[]` on an
  unauthorized/invalid token (fail closed).
  """
  @spec load_customer_messages(URI.t(), String.t(), URI.t()) :: [map()]
  def load_customer_messages(%URI{} = session_uri, token, %URI{} = viewer_uri)
      when is_binary(token) do
    case CustomerFeed.snapshot(session_uri, token) do
      {:ok, %{messages: messages}} ->
        messages
        |> Enum.reverse()
        |> Enum.map(&ChatUI.row(&1, viewer_uri))

      {:error, _reason} ->
        []
    end
  end

  def load_customer_messages(_session_uri, _token, _viewer_uri), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl h-[calc(100vh-2rem)] my-4 flex flex-col rounded-xl border border-gray-200 shadow-sm overflow-hidden bg-white">
      <header class="px-4 py-3 border-b bg-blue-600 text-white">
        <h1 class="font-semibold">在线客服</h1>
        <p class="text-xs opacity-80">{URI.to_string(@customer_uri)}</p>
      </header>

      <p
        :if={@error}
        class="m-4 rounded bg-amber-50 border border-amber-200 px-3 py-2 text-sm text-amber-800"
      >
        {@error}
      </p>

      <ChatUI.message_list
        :if={!@error}
        messages={@messages}
        empty_hint="正在为你接入客服…"
      />
      <ChatUI.composer :if={!@error} nonce={@compose_nonce} placeholder="输入你的问题…" />
    </div>
    """
  end
end
