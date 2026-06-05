defmodule EzagentPluginAutoservice.OperatorLive do
  @moduledoc """
  Operator console — `/autoservice/operator`.

  Lists the customer-service sessions in the operator's workspace
  (`session://cs/<ws>/*`), lets the operator open one, and chat
  directly with the customer (human handoff). Operator messages are
  sent as the operator's own User URI, so they do NOT match the
  customer→fast routing rule (no AI fan-out) — they simply appear in
  the session for the customer as "人工客服".
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias Ezagent.Behavior.Chat
  alias EzagentPluginAutoservice.ChatUI

  require Logger

  @msg_limit 100

  @impl true
  def mount(_params, _session, socket) do
    operator_uri = socket.assigns.current_entity_uri
    workspace_uri = socket.assigns.current_workspace_uri
    caps = Ezagent.Identity.list_caps_for(operator_uri)

    {:ok,
     assign(socket,
       page_title: "客服工作台",
       operator_uri: operator_uri,
       workspace_uri: workspace_uri,
       caps: caps,
       sessions: list_cs_sessions(workspace_uri),
       selected: nil,
       subscribed_topic: nil,
       messages: [],
       compose_nonce: 0
     )}
  end

  @impl true
  def handle_event("select", %{"uri" => uri_str}, socket) do
    session_uri = Ezagent.URI.new!(uri_str)

    # Rehydrate the session Kind if it's dormant (snapshot-backed but not
    # yet referenced this server uptime) so the join below has a live
    # target. Idempotent — a live session returns {:error, already_*}.
    rehydrate_session(session_uri, socket.assigns.workspace_uri)

    socket = resubscribe(socket, session_uri)

    # Join the operator so they are a session member + authorized to
    # send. Idempotent (chat.join is a set-membership no-op).
    join_operator(session_uri, socket.assigns.operator_uri, socket.assigns.caps)

    {:noreply,
     assign(socket,
       selected: session_uri,
       messages: load_messages(session_uri, socket.assigns.operator_uri),
       compose_nonce: socket.assigns.compose_nonce + 1
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, sessions: list_cs_sessions(socket.assigns.workspace_uri))}
  end

  def handle_event("send", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.selected) ->
        {:noreply, socket}

      true ->
        msg = Ezagent.Message.new(socket.assigns.operator_uri, %{text: text, attachments: []})
        target = URI.new!("#{URI.to_string(socket.assigns.selected)}?action=chat.send")

        _ =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :cast,
            args: %{message: msg},
            ctx: %{caller: socket.assigns.operator_uri, caps: socket.assigns.caps, reply: :ignore}
          })

        {:noreply, update(socket, :compose_nonce, &(&1 + 1))}
    end
  end

  @impl true
  def handle_info({:chat_message, session_uri, %Ezagent.Message{} = msg}, socket) do
    if selected_match?(socket.assigns.selected, session_uri) do
      row = ChatUI.row(msg, socket.assigns.operator_uri)
      {:noreply, update(socket, :messages, fn ms -> ms ++ [row] end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- helpers --------------------------------------------------------

  # All customer-service sessions in the workspace — the union of live
  # sessions (KindRegistry) and provisioned-but-dormant ones (snapshots),
  # so the operator sees every customer whether or not they're currently
  # connected. Workspace-scoped (P21) via `list_in_workspace/1`.
  defp list_cs_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    live =
      workspace_uri
      |> EzagentDomainChat.list_sessions()
      |> Enum.map(&URI.to_string/1)

    dormant =
      workspace_uri
      |> Ezagent.Ecto.KindSnapshot.list_in_workspace()
      |> Enum.map(& &1.uri)

    (live ++ dormant)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(&1, "session://cs/"))
    |> Enum.map(fn str ->
      uri = Ezagent.URI.new!(str)
      %{uri: uri, str: str, name: customer_name(uri)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp list_cs_sessions(_), do: []

  defp rehydrate_session(%URI{} = session_uri, %URI{scheme: "workspace"} = workspace_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(session_uri) do
          {:ok, _pid} ->
            _ = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
            :ok

          _ ->
            :ok
        end
    end
  end

  defp rehydrate_session(_, _), do: :ok

  # session://cs/<ws>/<name> → "<name>"
  defp customer_name(%URI{path: path}) do
    path |> String.split("/", trim: true) |> List.last() || "?"
  end

  defp selected_match?(nil, _), do: false
  defp selected_match?(%URI{} = selected, %URI{} = incoming),
    do: URI.to_string(selected) == URI.to_string(incoming)

  defp resubscribe(socket, %URI{} = session_uri) do
    new_topic = Chat.session_events_topic(session_uri)

    if connected?(socket) do
      old = socket.assigns[:subscribed_topic]
      if is_binary(old) and old != new_topic do
        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, old)
      end

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, new_topic)
    end

    assign(socket, subscribed_topic: new_topic)
  end

  defp join_operator(session_uri, operator_uri, caps) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    _ =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{member: operator_uri},
        ctx: %{caller: operator_uri, caps: caps, reply: :ignore}
      })

    :ok
  end

  defp load_messages(session_uri, viewer_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@msg_limit)
    |> Enum.reverse()
    |> Enum.map(&ChatUI.row(&1, viewer_uri))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[calc(100vh-1rem)] m-2 flex gap-2">
      <aside class="w-72 flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 border-b bg-gray-800 text-white flex items-center justify-between">
          <div>
            <h1 class="font-semibold text-sm">客服工作台</h1>
            <p class="text-[11px] opacity-70">{workspace_label(@workspace_uri)}</p>
          </div>
          <button phx-click="refresh" class="text-xs underline opacity-80 hover:opacity-100">刷新</button>
        </header>
        <div class="flex-1 overflow-y-auto">
          <p :if={@sessions == []} class="p-4 text-sm text-gray-400">该工作区暂无客服会话</p>
          <button
            :for={s <- @sessions}
            phx-click="select"
            phx-value-uri={s.str}
            class={[
              "w-full text-left px-4 py-3 border-b hover:bg-gray-50",
              selected_match?(@selected, s.uri) && "bg-blue-50"
            ]}
          >
            <div class="text-sm font-medium text-gray-800">客户:{s.name}</div>
            <div class="text-[11px] text-gray-400 truncate">{s.str}</div>
          </button>
        </div>
      </aside>

      <main class="flex-1 flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden">
        <div :if={is_nil(@selected)} class="flex-1 flex items-center justify-center text-gray-400 text-sm">
          从左侧选择一个客户会话进入
        </div>

        <%= if @selected do %>
          <header class="px-4 py-3 border-b bg-gray-50">
            <h2 class="font-semibold text-sm text-gray-800">客户:{customer_name(@selected)}</h2>
            <p class="text-[11px] text-gray-400">{URI.to_string(@selected)}</p>
          </header>
          <ChatUI.message_list messages={@messages} empty_hint="该会话还没有消息" />
          <ChatUI.composer nonce={@compose_nonce} placeholder="以人工客服身份回复客户…" />
        <% end %>
      </main>
    </div>
    """
  end

  defp workspace_label(%URI{scheme: "workspace", host: name}), do: name
  defp workspace_label(_), do: "—"
end
