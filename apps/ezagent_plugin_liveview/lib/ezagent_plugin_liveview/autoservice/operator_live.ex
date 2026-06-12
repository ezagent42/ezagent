defmodule EzagentPluginLiveview.AutoService.OperatorLive do
  @moduledoc """
  Operator console -- `/autoservice/operator`.

  Lists the customer-service sessions in the operator's workspace
  (`session://cs/<ws>/*`), lets the operator open one, and take over
  the conversation (human handoff) via the **Turn lifecycle**.

  ## Takeover flow (B-minimal — Turn-driven, NO chat.send)

  Operator replies to the customer go ONLY through the Turn so they are
  gated `operator_only` until the operator commits. The operator NEVER
  reaches the customer via `chat.send` (that path broadcasts
  unconditionally and would leak the draft — see CustomerLive).

  1. Operator selects a session, types their reply, clicks **接管 (claim)**:
     `open_turn` → `compose_turn(<the operator's typed reply>)` →
     `claim_turn`. The composed message is held `operator_only` (the Turn's
     `handle_claim` marks it via MessageStore), so `CustomerFeed` does NOT
     show it. AI routing is paused (`disable_session_rule`).
  2. Operator clicks **提交 (settle)**: `settle_turn` flips the reply to
     `customer_visible` and commits the settlement, so `CustomerFeed`
     delivers it (`{:customer_delivery}`). AI routing is resumed.
  3. Operator clicks **取消 (cancel)**: `cancel_turn` — the draft never
     becomes visible. AI routing is resumed.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias Ezagent.Behavior.Chat
  alias EzagentPluginAutoservice.{ChatUI, TurnAdapter}
  alias Ezagent.Socialware.CustomerFeed

  require Logger

  @msg_limit 100
  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

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
       compose_nonce: 0,
       claimed: false,
       claiming: false,
       open_turn_id: nil
     )}
  end

  @impl true
  def handle_event("select", %{"uri" => uri_str}, socket) do
    session_uri = Ezagent.URI.new!(uri_str)

    rehydrate_session(session_uri, socket.assigns.workspace_uri)

    socket = resubscribe(socket, session_uri)

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

  # The operator NEVER sends to the customer via chat.send — that path
  # (`Chat.handle_send`) broadcasts `{:chat_message}` unconditionally with no
  # visibility filter, which would leak an `operator_only` draft to the customer
  # LiveView immediately (gating defeated). The operator's reply to the customer
  # goes ONLY through the Turn (compose `operator_only` → settle
  # `customer_visible` → CustomerFeed). The composer's submit is wired to the
  # "claim" event (接管), so a stray "send" here is a no-op.
  def handle_event("send", %{"text" => _text}, socket), do: {:noreply, socket}

  def handle_event("claim", %{"text" => text}, socket) when is_binary(text) do
    %{selected: session_uri, operator_uri: op_uri} = socket.assigns
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(session_uri) or socket.assigns.claimed or socket.assigns.claiming ->
        {:noreply, socket}

      true ->
        do_claim(session_uri, op_uri, text, assign(socket, claiming: true))
    end
  end

  def handle_event("claim", _params, socket), do: {:noreply, socket}

  def handle_event("settle", _params, socket) do
    %{selected: session_uri, operator_uri: op_uri, open_turn_id: turn_id} = socket.assigns

    if is_nil(session_uri) or is_nil(turn_id) do
      {:noreply, socket}
    else
      # Settle the Turn: this flips the composed operator reply from
      # operator_only -> customer_visible AND commits the settlement, after
      # which CustomerFeed delivers it (`{:customer_delivery}`). No chat.send
      # here — the Turn is the ONLY path the operator reply reaches the customer
      # (a chat.send would broadcast unconditionally and bypass the gate).
      case TurnAdapter.settle_turn(session_uri, turn_id) do
        {:ok, _} ->
          Logger.info(
            "Operator #{URI.to_string(op_uri)} settled turn #{turn_id} on session #{URI.to_string(session_uri)}"
          )

        {:error, reason} ->
          Logger.error("OperatorLive: settle_turn failed for turn #{turn_id}: #{inspect(reason)}")
      end

      # Re-enable the routing rule (restore agent routing).
      _ = enable_session_rule(session_uri)

      {:noreply, assign(socket, claimed: false, claiming: false, open_turn_id: nil)}
    end
  end

  def handle_event("cancel", _params, socket) do
    %{selected: session_uri, operator_uri: op_uri, open_turn_id: turn_id} = socket.assigns

    if is_nil(session_uri) or is_nil(turn_id) do
      {:noreply, socket}
    else
      # 1. Cancel the Turn (transitions to :cancelled)
      case TurnAdapter.cancel_turn(session_uri, turn_id) do
        {:ok, _} ->
          Logger.info(
            "Operator #{URI.to_string(op_uri)} cancelled turn #{turn_id} on session #{URI.to_string(session_uri)}"
          )

        {:error, reason} ->
          Logger.error("OperatorLive: cancel_turn failed: #{inspect(reason)}")
      end

      # 2. Re-enable the routing rule (restore agent routing)
      _ = enable_session_rule(session_uri)

      # 3. Unsubscribe from CustomerFeed topic
      feed_topic = socket.assigns[:subscribed_feed_topic]

      if connected?(socket) and is_binary(feed_topic) do
        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, feed_topic)
      end

      {:noreply,
       assign(socket,
         claimed: false,
         claiming: false,
         open_turn_id: nil,
         subscribed_feed_topic: nil
       )}
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

  # open → compose(operator's REAL reply) → claim. The composed message is the
  # operator's actual answer to the customer; `claim`'s hold_visibility holds it
  # `operator_only`, so it stays hidden from CustomerFeed until "提交" (settle).
  defp do_claim(session_uri, op_uri, text, socket) do
    # 1. Derive the customer trigger (latest customer message or fallback)
    trigger = get_latest_customer_trigger(session_uri, op_uri)

    # 2. Open a real Turn
    case TurnAdapter.open_turn(session_uri, trigger) do
      {:ok, %{turn_id: turn_id}} ->
        # 3. Compose the operator's REAL reply (transition to :composing so
        #    claim is allowed). Written customer_visible at compose-time (turn
        #    mode :auto), then held operator_only by claim's hold_visibility.
        case TurnAdapter.compose_turn(session_uri, turn_id, %{agent_uri: op_uri, text: text}) do
          {:ok, _} ->
            # 4. Claim (transition to :awaiting_human, hold visibility ->
            #    operator_only). The customer cannot see the reply yet.
            case TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri: op_uri}) do
              {:ok, _} ->
                # 5. Disable AI routing
                _ = disable_session_rule(session_uri)

                # 6. Subscribe to CustomerFeed topic for real-time delivery
                feed_topic = CustomerFeed.topic(session_uri)

                if connected?(socket) do
                  Phoenix.PubSub.subscribe(EzagentCore.PubSub, feed_topic)
                end

                Logger.info(
                  "Operator #{URI.to_string(op_uri)} claimed turn #{turn_id} on session #{URI.to_string(session_uri)}"
                )

                {:noreply,
                 assign(socket,
                   subscribed_feed_topic: feed_topic,
                   claimed: true,
                   claiming: false,
                   open_turn_id: turn_id,
                   compose_nonce: socket.assigns.compose_nonce + 1
                 )}

              {:error, claim_reason} ->
                Logger.error(
                  "OperatorLive: claim_turn failed for turn #{turn_id}: #{inspect(claim_reason)}"
                )

                _ = TurnAdapter.cancel_turn(session_uri, turn_id)
                {:noreply, assign(socket, claiming: false)}
            end

          {:error, compose_reason} ->
            Logger.error(
              "OperatorLive: compose_turn failed for turn #{turn_id}: #{inspect(compose_reason)}"
            )

            _ = TurnAdapter.cancel_turn(session_uri, turn_id)
            {:noreply, assign(socket, claiming: false)}
        end

      {:error, open_reason} ->
        Logger.error("OperatorLive: open_turn failed: #{inspect(open_reason)}")
        {:noreply, assign(socket, claiming: false)}
    end
  end

  # Find and disable the MentionRouting rule that routes customer messages
  # in this session to the agent(s). The matcher contains the session URI
  # string as an {:in_session, session_str} term.
  defp disable_session_rule(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(@routing_table)
    |> Enum.filter(fn rule ->
      match?({:and, _}, rule.matcher_data) and
        match_session_in_matcher?(rule.matcher_data, session_str)
    end)
    |> Enum.each(fn rule ->
      _ = Ezagent.Routing.RuleStore.disable(rule.id)
      Logger.info("OperatorLive: disabled routing rule #{rule.id} for session #{session_str}")
    end)

    _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
    :ok
  end

  defp enable_session_rule(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(@routing_table)
    |> Enum.filter(fn rule ->
      not rule.enabled and
        match?({:and, _}, rule.matcher_data) and
        match_session_in_matcher?(rule.matcher_data, session_str)
    end)
    |> Enum.each(fn rule ->
      _ = Ezagent.Routing.RuleStore.enable(rule.id)
      Logger.info("OperatorLive: enabled routing rule #{rule.id} for session #{session_str}")
    end)

    _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
    :ok
  end

  defp match_session_in_matcher?({:and, clauses}, session_str) when is_list(clauses) do
    Enum.any?(clauses, fn
      {:in_session, ^session_str} -> true
      _ -> false
    end)
  end

  defp match_session_in_matcher?(_matcher, _session_str), do: false

  defp list_cs_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    live =
      workspace_uri
      |> EzagentDomainInstanceMessage.list_sessions()
      |> Enum.map(&URI.to_string/1)

    dormant =
      workspace_uri
      |> Ezagent.Ecto.KindSnapshot.list_in_workspace()
      |> Enum.map(& &1.uri)

    (live ++ dormant)
    |> Enum.uniq()
    |> Enum.filter(&String.contains?(&1, "/cs/"))
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

  defp get_latest_customer_trigger(session_uri, operator_uri) do
    operator_str = URI.to_string(operator_uri)

    session_uri
    |> Ezagent.MessageStore.recent_in_session(@msg_limit)
    |> Enum.find(fn msg -> URI.to_string(msg.sender) != operator_str end)
    |> case do
      %Ezagent.Message{sender: cu, body: body} ->
        %{customer_uri: cu, text: body[:text] || body["text"] || ""}

      nil ->
        %{customer_uri: operator_uri, text: "operator 主动发起对话"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[calc(100vh-1rem)] m-2 flex gap-2">
      <aside class="w-72 flex flex-col rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-950 overflow-hidden">
        <header class="px-4 py-3 border-b border-zinc-700 dark:border-zinc-600 bg-zinc-800 dark:bg-zinc-700 text-white flex items-center justify-between">
          <div>
            <h1 class="font-semibold text-sm">客服工作台</h1>
            <p class="text-[11px] opacity-70">{workspace_label(@workspace_uri)}</p>
          </div>
          <button phx-click="refresh" class="text-xs underline opacity-80 hover:opacity-100">
            刷新
          </button>
        </header>
        <div class="flex-1 overflow-y-auto">
          <p :if={@sessions == []} class="p-4 text-sm text-zinc-400 dark:text-zinc-500">该工作区暂无客服会话</p>
          <button
            :for={s <- @sessions}
            phx-click="select"
            phx-value-uri={s.str}
            class={[
              "w-full text-left px-4 py-3 border-b border-zinc-100 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-800",
              selected_match?(@selected, s.uri) && "bg-blue-50 dark:bg-blue-950/30"
            ]}
          >
            <div class="text-sm font-medium text-zinc-800 dark:text-zinc-200">客户:{s.name}</div>
            <div class="text-[11px] text-zinc-400 dark:text-zinc-500 truncate">{s.str}</div>
          </button>
        </div>
      </aside>

      <main class="flex-1 flex flex-col rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-950 overflow-hidden">
        <div
          :if={is_nil(@selected)}
          class="flex-1 flex items-center justify-center text-zinc-400 dark:text-zinc-500 text-sm"
        >
          从左侧选择一个客户会话进入
        </div>

        <%= if @selected do %>
          <header class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900">
            <h2 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200">
              客户:{customer_name(@selected)}
            </h2>
            <p class="text-[11px] text-zinc-400 dark:text-zinc-500">{URI.to_string(@selected)}</p>
          </header>
          <ChatUI.message_list messages={@messages} empty_hint="该会话还没有消息" />
          <div
            :if={!@claimed}
            class="px-4 py-2 border-t border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900"
          >
            <span class="text-xs text-zinc-400 dark:text-zinc-500">
              输入回复并点击「接管」，回复会先作为草稿(对客户不可见)，点击「提交」后才发送给客户。接管期间 AI 自动回复暂停。
            </span>
          </div>
          <div
            :if={@claimed}
            class="px-4 py-2 border-t border-zinc-200 dark:border-zinc-700 bg-amber-50 dark:bg-amber-950/30"
          >
            <span class="text-sm font-medium text-amber-800 dark:text-amber-200 mr-3">
              🔒 已接管 — 回复为草稿(客户不可见),提交后发送
            </span>
            <button
              phx-click="settle"
              class="rounded-lg bg-emerald-600 text-white px-3 py-1.5 text-sm font-medium hover:bg-emerald-700"
            >
              提交(发送给客户)
            </button>
            <button
              phx-click="cancel"
              class="rounded-lg bg-red-500 text-white px-3 py-1.5 text-sm font-medium hover:bg-red-600 ml-2"
            >
              取消接管
            </button>
          </div>
          <ChatUI.composer
            nonce={@compose_nonce}
            placeholder="输入回复客户的内容…"
            submit_event="claim"
            submit_label="接管"
            disabled={@claimed || @claiming}
          />
        <% end %>
      </main>
    </div>
    """
  end

  defp workspace_label(%URI{scheme: "workspace", host: name}), do: name
  defp workspace_label(_), do: "—"
end
