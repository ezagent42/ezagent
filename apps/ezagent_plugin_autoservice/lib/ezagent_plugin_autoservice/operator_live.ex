defmodule EzagentPluginAutoservice.OperatorLive do
  @moduledoc """
  Operator console — `/autoservice/operator`.

  Lists customer-service sessions in the operator's workspace
  (`session://cs/<ws>/*`), lets the operator open one, view ALL messages
  (including `operator_only` drafts — via `MessageStore.recent_in_session`),
  and drive operator takeover through the CS Orchestrator.

  ## Takeover flow

  1. Operator selects a session → loads messages + derives orchestrator URI.
  2. Operator types a reply and clicks "接管" → dispatches orchestrator
     `operator_claim(turn_id, operator_text, operator_uri)`.
     The orchestrator: compose(operator_text) → claim (turn becomes
     :awaiting_human, draft held :operator_only).
  3. Operator clicks "提交" → dispatches orchestrator `operator_settle(turn_id)`.
     The orchestrator: settle → draft flips customer_visible → CustomerFeed updates.

  ## Why dispatch goes to the orchestrator, NOT TurnDriver directly

  P22 / invariant #1: operator_claim/settle go through the orchestrator so
  `operator_active` gates fan-out correctly. Calling TurnDriver directly would
  bypass the gate and leave fan-out running during human takeover.

  ## open_turn_id read (Phase-B shortcut)

  `Assembly.open_turn_id/1` reads the orchestrator Kind's live state via
  `:sys.get_state` — acceptable for Phase B as documented there. The real
  solution (Stage F) is a sanctioned CapBAC-gated read action on the orchestrator.

  ## NP-1/2/3 (§11 naming lint)

  Module: `EzagentPluginAutoservice.OperatorLive` — plugin tier,
  names operator-console responsibility, matches its CS-session scope.
  """

  use Phoenix.LiveView
  import Phoenix.Component

  alias Ezagent.Socialware.CustomerFeed
  alias EzagentPluginAutoservice.{Assembly, ChatUI}

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
       # The open turn_id for the currently selected session (Phase-B shortcut).
       open_turn_id: nil,
       # The orchestrator URI for the currently selected session.
       orchestrator_uri: nil,
       # Tracks whether an operator_claim has been sent (controls "提交" button).
       claimed?: false,
       compose_nonce: 0
     )}
  end

  @impl true
  def handle_event("select", %{"uri" => uri_str}, socket) do
    session_uri = Ezagent.URI.new!(uri_str)

    rehydrate_session(session_uri, socket.assigns.workspace_uri)
    socket = resubscribe(socket, session_uri)

    # Join the operator so they are a session member + authorized to query messages.
    join_operator(session_uri, socket.assigns.operator_uri, socket.assigns.caps)

    {orch_uri, open_turn_id} = derive_orch_and_turn(session_uri, socket.assigns.workspace_uri)

    {:noreply,
     assign(socket,
       selected: session_uri,
       orchestrator_uri: orch_uri,
       open_turn_id: open_turn_id,
       claimed?: false,
       messages: load_messages(session_uri, socket.assigns.operator_uri),
       compose_nonce: socket.assigns.compose_nonce + 1
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, sessions: list_cs_sessions(socket.assigns.workspace_uri))}
  end

  # "接管" — operator sends claim with their reply text
  def handle_event("claim", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    with false <- text == "",
         %URI{} = session_uri <- socket.assigns.selected,
         %URI{} = orch_uri <- socket.assigns.orchestrator_uri,
         turn_id when is_binary(turn_id) <- socket.assigns.open_turn_id do
      operator_uri_str = URI.to_string(socket.assigns.operator_uri)
      orch_action = URI.to_string(orch_uri) <> "?action=cs_orchestrator.operator_claim"
      target = Ezagent.URI.new!(orch_action)

      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{turn_id: turn_id, operator_text: text, operator_uri: operator_uri_str},
          ctx: %{
            caller: socket.assigns.operator_uri,
            caps: socket.assigns.caps,
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        {:ok, %{ok: true}} ->
          {:noreply,
           assign(socket, claimed?: true, compose_nonce: socket.assigns.compose_nonce + 1)}

        {:ok, %{ok: false}} ->
          Logger.warning(
            "OperatorLive operator_claim returned ok: false, " <>
              "session=#{URI.to_string(session_uri)} turn_id=#{turn_id}"
          )

          {:noreply, socket}

        {:error, reason} ->
          Logger.error("OperatorLive operator_claim dispatch error: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      _ ->
        # No turn open, no session selected, or blank text — no-op.
        {:noreply, socket}
    end
  end

  # "提交" — settle the claimed turn
  def handle_event("settle", _params, socket) do
    with %URI{} = orch_uri <- socket.assigns.orchestrator_uri,
         turn_id when is_binary(turn_id) <- socket.assigns.open_turn_id do
      orch_action = URI.to_string(orch_uri) <> "?action=cs_orchestrator.operator_settle"
      target = Ezagent.URI.new!(orch_action)

      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{turn_id: turn_id},
          ctx: %{
            caller: socket.assigns.operator_uri,
            caps: socket.assigns.caps,
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        {:ok, %{ok: true}} ->
          {:noreply, assign(socket, claimed?: false, open_turn_id: nil)}

        _ ->
          Logger.warning("OperatorLive operator_settle result: #{inspect(result)}")
          {:noreply, socket}
      end
    else
      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:customer_delivery, _payload}, socket) do
    # CustomerFeed settled — refresh messages (operator sees all via MessageStore).
    messages =
      if socket.assigns.selected do
        load_messages(socket.assigns.selected, socket.assigns.operator_uri)
      else
        socket.assigns.messages
      end

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # All customer-service sessions in the workspace — union of live + dormant.
  # CS session URIs are `session://<ws>/cs/<customer>` (the workspace is the
  # host; `cs` is the first PATH segment), so filter on the `/cs/` path segment,
  # NOT a `session://cs/` prefix (that prefix never matches — the ws segment
  # sits between `session://` and `/cs/`). `list_in_workspace` already scopes to
  # this workspace.
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
    |> Enum.filter(fn str ->
      case Ezagent.URI.parse(str) do
        {:ok, %URI{scheme: "session", path: "/cs/" <> _}} -> true
        _ -> false
      end
    end)
    |> Enum.map(fn str ->
      uri = Ezagent.URI.new!(str)
      %{uri: uri, str: str, name: customer_name(uri)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp list_cs_sessions(_), do: []

  # Rehydrate a dormant session Kind (snapshot-backed but not yet alive
  # this server uptime). Idempotent.
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

  # session://<ws>/cs/<name> → orchestrator URI + open_turn_id.
  # Orchestrator URI is deterministic: entity://<ws>/agent/orch-cs-<customer>
  # (MUST match Assembly.provision_session/3 which builds orch_uri as:
  #   Ezagent.URI.agent(tid, "orch-cs-" <> customer_name))
  defp derive_orch_and_turn(%URI{} = session_uri, %URI{} = workspace_uri) do
    {:ok, tid} = Ezagent.URI.workspace_name(workspace_uri)
    customer = customer_name(session_uri)
    orch_uri = Ezagent.URI.agent(tid, "orch-cs-" <> customer)

    open_turn_id = Assembly.open_turn_id(orch_uri)
    {orch_uri, open_turn_id}
  end

  # Resubscribe to CustomerFeed topic for the new session (NOT Chat raw events —
  # rule: no PubSub.broadcast on inbound, CustomerFeed.topic OK for operator refresh).
  defp resubscribe(socket, %URI{} = session_uri) do
    new_topic = CustomerFeed.topic(session_uri)

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

  # Operator sees ALL messages (incl. operator_only drafts) — full MessageStore,
  # NOT the gated CustomerFeed.
  defp load_messages(%URI{} = session_uri, viewer_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@msg_limit)
    |> Enum.reverse()
    |> Enum.map(&ChatUI.row(&1, viewer_uri))
  end

  defp load_messages(nil, _), do: []

  # session://<ws>/cs/<name> → "<name>" (last path segment)
  defp customer_name(%URI{path: path}) do
    path |> String.split("/", trim: true) |> List.last() || "?"
  end

  defp selected_match?(nil, _), do: false

  defp selected_match?(%URI{} = selected, %URI{} = incoming),
    do: URI.to_string(selected) == URI.to_string(incoming)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[calc(100vh-1rem)] m-2 flex gap-2">
      <!-- Session list sidebar -->
      <aside class="w-72 flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 border-b bg-gray-800 text-white flex items-center justify-between">
          <div>
            <h1 class="font-semibold text-sm">客服工作台</h1>
            <p class="text-[11px] opacity-70">{workspace_label(@workspace_uri)}</p>
          </div>
          <button phx-click="refresh" class="text-xs underline opacity-80 hover:opacity-100">
            刷新
          </button>
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
      
    <!-- Chat + operator panel -->
      <main class="flex-1 flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden">
        <div
          :if={is_nil(@selected)}
          class="flex-1 flex items-center justify-center text-gray-400 text-sm"
        >
          从左侧选择一个客户会话进入
        </div>

        <%= if @selected do %>
          <header class="px-4 py-3 border-b bg-gray-50 flex items-center justify-between">
            <div>
              <h2 class="font-semibold text-sm text-gray-800">客户:{customer_name(@selected)}</h2>
              <p class="text-[11px] text-gray-400">{URI.to_string(@selected)}</p>
            </div>
            <div class="flex gap-2 text-xs">
              <span
                :if={@open_turn_id}
                class="rounded bg-amber-100 px-2 py-1 text-amber-800"
              >
                turn: {@open_turn_id}
              </span>
              <span :if={@claimed?} class="rounded bg-green-100 px-2 py-1 text-green-800">
                已接管
              </span>
            </div>
          </header>

          <ChatUI.message_list messages={@messages} empty_hint="该会话还没有消息" />
          
    <!-- Operator action bar: claim composer + settle button -->
          <div class="border-t bg-gray-50">
            <!-- Claim form: type reply + click 接管 -->
            <form
              id={"op-claim-#{@compose_nonce}"}
              phx-submit="claim"
              class="flex gap-2 p-3"
            >
              <input
                type="text"
                name="text"
                value=""
                placeholder={if @open_turn_id, do: "输入人工回复后点击「接管」…", else: "暂无开放 turn，等待客户消息"}
                autocomplete="off"
                disabled={is_nil(@open_turn_id) || @claimed?}
                class="flex-1 rounded-lg border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-400 disabled:bg-gray-100"
              />
              <button
                type="submit"
                disabled={is_nil(@open_turn_id) || @claimed?}
                class="rounded-lg bg-amber-500 text-white px-4 py-2 text-sm font-medium hover:bg-amber-600 disabled:opacity-50"
              >
                接管
              </button>
            </form>
            <!-- Settle button (visible after claim) -->
            <div :if={@claimed?} class="px-3 pb-3">
              <button
                phx-click="settle"
                class="w-full rounded-lg bg-emerald-600 text-white py-2 text-sm font-medium hover:bg-emerald-700"
              >
                提交（发送给客户）
              </button>
            </div>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  defp workspace_label(%URI{host: name}), do: name
  defp workspace_label(_), do: "—"
end
