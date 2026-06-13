defmodule Ezagent.Behavior.Session.Delivery do
  @moduledoc false

  require Logger

  alias Ezagent.{Cmd, Message, MessageStore}

  @doc "PubSub topic for in-session events (chat stream feed)."
  @spec session_events_topic(URI.t() | String.t()) :: String.t()
  def session_events_topic(%URI{} = uri), do: session_events_topic(URI.to_string(uri))
  def session_events_topic(uri_str) when is_binary(uri_str), do: "esr:session:#{uri_str}:events"

  @doc "PubSub topic for a User's personal receive notifications."
  @spec user_events_topic(URI.t() | String.t()) :: String.t()
  def user_events_topic(%URI{} = uri), do: user_events_topic(URI.to_string(uri))
  def user_events_topic(uri_str) when is_binary(uri_str), do: "esr:user:#{uri_str}:events"

  @spec notify_dropped_mentions(Message.t(), [URI.t()], URI.t(), map(), module()) :: :ok
  def notify_dropped_mentions(%Message{} = msg, recipients, session_uri, _ctx, source_module) do
    mention_uris = msg.mentions || []

    if mention_uris == [] do
      :ok
    else
      recipients = MapSet.new(recipients, &Ezagent.URI.instance/1)

      dropped =
        mention_uris
        |> Enum.map(&to_uri_struct/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn uri -> MapSet.member?(recipients, Ezagent.URI.instance(uri)) end)

      Enum.each(dropped, fn dropped_uri ->
        try do
          Ezagent.Notifications.notify(
            msg.sender,
            %{
              type: :mention_failed,
              body: %{
                message: "Your @-mention was not delivered (target is not a session member).",
                mentioned_uri: URI.to_string(dropped_uri),
                session_uri: URI.to_string(session_uri)
              },
              source: source_module
            }
          )
        rescue
          e ->
            Logger.warning(
              "Ezagent.Behavior.Session: notify mention_failed raised for " <>
                "#{URI.to_string(dropped_uri)}: #{Exception.message(e)}"
            )
        end
      end)

      :ok
    end
  end

  defp to_uri_struct(%URI{} = uri), do: uri

  defp to_uri_struct(s) when is_binary(s) do
    Ezagent.URI.new!(s)
  rescue
    _ -> nil
  end

  defp to_uri_struct(_), do: nil

  @spec dispatch_cross_session_call(URI.t(), Message.t()) :: term()
  def dispatch_cross_session_call(target_session_uri, %Message{} = msg) do
    send_target = Ezagent.URI.with_action(target_session_uri, :session, :send)

    Ezagent.Router.dispatch(%Cmd{
      target: send_target,
      action: :send,
      args: %{message: msg},
      ctx: %{
        caller: msg.sender,
        caps: system_caps("chat-router"),
        reply: :ignore
      }
    })
  end

  @spec render_for_delivery(Message.t(), map() | nil, map(), URI.t()) :: Message.t()
  def render_for_delivery(%Message{} = msg, ctx, templates, %URI{} = session_uri)
      when is_map(templates) do
    ref = ctx && Map.get(ctx, :prompt_template_ref)

    case ref && Map.get(templates, ref) do
      template when is_binary(template) ->
        rendered =
          Ezagent.Routing.PromptTemplate.render(template, message_vars(msg, session_uri))

        %{msg | body: put_rendered_text(msg.body, rendered)}

      _ ->
        msg
    end
  end

  @spec message_vars(Message.t(), URI.t()) :: map()
  def message_vars(%Message{} = msg, %URI{} = session_uri) do
    %{
      sender: msg.sender && URI.to_string(msg.sender),
      body: body_text(msg.body),
      session: URI.to_string(session_uri),
      sent_at: msg.inserted_at && DateTime.to_iso8601(msg.inserted_at),
      flavor: ""
    }
  end

  defp put_rendered_text(%{text: _} = body, text), do: %{body | text: text}
  defp put_rendered_text(%{"text" => _} = body, text), do: Map.put(body, "text", text)
  defp put_rendered_text(body, text) when is_map(body), do: Map.put(body, :text, text)
  defp put_rendered_text(_body, text), do: %{text: text}

  @spec dispatch_receive_call(URI.t(), Message.t(), URI.t()) :: term()
  def dispatch_receive_call(recipient_uri, %Message{} = msg, session_uri) do
    session_uri = Ezagent.URI.new!(URI.to_string(session_uri))
    # PR-2 (im/session/agent decomposition §3.3) — spell the behavior
    # prefix `<entity>.receive` (`user.receive` / `agent.receive`) per the
    # recipient's Kind. The prefix is TELEMETRY-ONLY: dispatch routes on
    # the action atom `:receive` + the recipient Kind via the
    # BehaviorRegistry (which now resolves `{User, :receive}` →
    # `Behavior.User.Receive` and `{Agent, :receive}` → `Behavior.Agent.Receive`).
    # A user URI → `user.receive`; everything else (agent + plugin agent
    # flavors, all `agent`-typed) → `agent.receive`.
    receive_prefix = receive_behavior_prefix(recipient_uri)
    receive_target = Ezagent.URI.with_action(recipient_uri, receive_prefix, :receive)

    result =
      Ezagent.Router.dispatch(%Cmd{
        target: receive_target,
        action: :receive,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          caps: system_caps("chat-router"),
          reply: :ignore
        }
      })

    if result == :ok do
      _ = Ezagent.Session.ReadMarker.mark(session_uri, recipient_uri, msg.id, :delivered)
    end

    result
  end

  # PR-2 — derive the `<entity>.receive` behavior-prefix atom for the
  # `:receive` dispatch telemetry from the recipient URI's type axis. A
  # `user`-typed recipient → `:user`; any other entity type (`agent` and
  # all plugin agent flavors, which are `agent`-typed) → `:agent`. Falls
  # back to `:agent` when the type can't be resolved (best-effort
  # telemetry; routing is unaffected — it keys on the action atom + Kind).
  @spec receive_behavior_prefix(URI.t()) :: :user | :agent
  defp receive_behavior_prefix(%URI{} = recipient_uri) do
    case Ezagent.URI.type(recipient_uri) do
      {:ok, "user"} -> :user
      _ -> :agent
    end
  end

  @spec replay_messages_since(URI.t(), URI.t(), map()) :: :ok
  def replay_messages_since(_session_uri, _member_uri, last_seen) when last_seen == %{}, do: :ok

  def replay_messages_since(session_uri, member_uri, last_seen) do
    case Map.get(last_seen, member_uri) do
      nil ->
        :ok

      last_seen_at ->
        for msg <- MessageStore.in_session_since(session_uri, last_seen_at) do
          dispatch_receive_call(member_uri, msg, session_uri)
        end

        :ok
    end
  end

  @spec broadcast_membership_effects(URI.t(), term()) :: [term()]
  def broadcast_membership_effects(session_uri, event) do
    [
      {:notify, session_events_topic(session_uri), event},
      {:notify, "esr:session_membership:changes",
       {:session_membership_change, session_uri, event}}
    ]
  end

  @spec broadcast_membership_direct(URI.t(), term()) :: :ok
  def broadcast_membership_direct(_session_uri, _event), do: :ok

  @spec pop_monitor_ref(map(), URI.t()) :: {reference() | nil, map()}
  def pop_monitor_ref(monitors, member_uri) do
    Enum.reduce(monitors, {nil, %{}}, fn
      {ref, ^member_uri}, {nil, acc} -> {ref, acc}
      {ref, uri}, {found_ref, acc} -> {found_ref, Map.put(acc, ref, uri)}
    end)
  end

  def body_text(%{text: t}) when is_binary(t), do: t
  def body_text(%{"text" => t}) when is_binary(t), do: t
  def body_text(_), do: ""

  def body_attachments(%{attachments: list}) when is_list(list), do: list
  def body_attachments(%{"attachments" => list}) when is_list(list), do: list
  def body_attachments(_), do: []

  def first_attachment_path([]), do: nil

  def first_attachment_path([att | _]) do
    case att[:local_path] || att["local_path"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  def first_attachment_path(_), do: nil

  @doc """
  Agent-branch `:receive` delivery (extracted VERBATIM from
  `Ezagent.Behavior.Session.handle_receive/2`, PR-3R). Builds a
  flavor-neutral `Ezagent.AgentBridge.Payload` from the message + ctx and
  delivers it via `Ezagent.AgentBridge`, self-healing a vanished bridge.
  Runs in the same Agent Kind process as the handler.

  Returns a CLASS-TAGGED result so the caller stays flavor-blind:

    * `:subprocess_ws` flavors (cc / codex) → `:ok` REGARDLESS of the
      delivery outcome (the agent's reply is ASYNC, back through the bridge
      → `session.send`; a missing bridge is best-effort, already logged by
      AgentBridge). The caller emits no further effects.
    * `:in_process_sync` flavors (curl, PR-6) → `{:sync, result}` where
      `result` is the adapter's `{:ok, _}` / `{:error, _}` round-trip
      outcome. The caller (`Agent.Receive`) re-dispatches that result into
      the flavor's `:sync_result` Behavior so the Behavior persists it (the
      adapter is transport-only). The `{:sync, _}` tag — NOT the raw return
      shape — is what distinguishes the two classes, so a `:subprocess_ws`
      `{:error, :no_bridge}` is never mistaken for a sync result.
  """
  @spec deliver_agent_receive(Message.t(), map()) ::
          :ok | {:sync, {:ok, term()} | {:error, term()}}
  def deliver_agent_receive(%Message{} = msg, ctx) do
    # AgentBridge PR-D: keep chat receive flavor-neutral. The
    # bridge domain resolves the bound channel and adapter for the
    # agent URI; missing bridge/adapter remains best-effort for
    # this cast receive path but is logged by AgentBridge.deliver/2.
    source_session =
      case Map.get(ctx, :caller) do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
        _ -> ""
      end

    attachments = body_attachments(msg.body)
    attachment_hint = attachment_hint_text(attachments)

    text_with_hint =
      case {body_text(msg.body), attachment_hint} do
        {"", ""} -> ""
        {t, ""} -> t
        {"", hint} -> hint
        {t, hint} -> t <> "\n" <> hint
      end

    base_meta = %{
      "sender" => Ezagent.URI.stable_key(msg.sender),
      "message_id" => msg.id,
      "session" => source_session,
      # PR-6 — the recipient agent's OWN URI, so an `:in_process_sync`
      # adapter (curl) can read the agent's persisted slices from the
      # snapshot store to assemble its request (deadlock-safe; the adapter
      # runs inside the agent Kind's dispatch process so a live
      # `Kind.get_slice` self-call would deadlock).
      "agent_uri" => agent_uri_meta(ctx)
    }

    meta =
      case first_attachment_path(attachments) do
        nil -> base_meta
        path -> Map.put(base_meta, "file_path", path)
      end

    session_uri =
      case msg.session_uri do
        %URI{} = uri -> uri
        s when is_binary(s) and s != "" -> Ezagent.URI.new!(s)
        _ when source_session != "" -> Ezagent.URI.new!(source_session)
        _ -> nil
      end

    payload = %Ezagent.AgentBridge.Payload{
      message_id: msg.id,
      session_uri: session_uri,
      sender_uri: msg.sender,
      text: text_with_hint,
      event_type: :chat_send,
      attachments: attachments,
      meta: meta
    }

    # PR-DR (blocker #1): self-heal a vanished bridge before dropping. If
    # the agent's claude/python subprocess exited (its WS Channel.terminate
    # unbound the Registry row), `deliver_ensuring/2` relaunches it
    # (snapshot-sourced, flavor-neutral) + awaits the rebind, then retries
    # once — instead of silently `:no_bridge`-dropping the routed message.
    #
    # PR-6 — the delivery is dispatched per the agent's transport class and
    # the result is CLASS-TAGGED. `:subprocess_ws` → `:ok` (async reply, even
    # on a best-effort drop); `:in_process_sync` → `{:sync, result}` the
    # caller re-dispatches into the flavor's `:sync_result` Behavior.
    #
    # Flavor resolution: prefer the in-process ctx-sandbox flavor (no
    # `Kind.get_slice` self-call), but FALL BACK to the durable flavor query
    # `AgentBridge.deliver` itself uses (`AgentFlavorAttributes` → sandbox).
    # The curl flavor lives in `AgentFlavorAttributes` (O-2, a stored slice
    # field), NOT the sandbox template_class, so the ctx-sandbox path returns
    # `:none` for curl — without this fallback the in-process-sync result
    # would be silently discarded down the `:subprocess_ws` async branch.
    flavor = resolve_delivery_flavor(ctx)

    if in_process_sync?(flavor) do
      {:ok, fl} = flavor
      {:sync, Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, fl)}
    else
      _ =
        case flavor do
          {:ok, fl} ->
            Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, fl)

          :none ->
            Ezagent.AgentBridge.deliver_ensuring(ctx[:self_uri], payload)
        end

      :ok
    end
  end

  # Resolve the delivery flavor: ctx-sandbox first (deadlock-safe in-process
  # read), then the durable `:flavor` query (covers the curl stored flavor
  # attribute) so the transport-class decision matches `AgentBridge.deliver`.
  defp resolve_delivery_flavor(ctx) do
    case resolve_agent_flavor_from_ctx(ctx) do
      {:ok, _} = ok ->
        ok

      :none ->
        # Read the STORED flavor attribute ONLY (an ETS lookup — deadlock-safe
        # inside the agent's own dispatch process). NOT the full
        # `UriQuery.resolve(:flavor, _)`, whose sandbox-slice fallback would be
        # a `Kind.get_slice(self_uri)` self-call deadlock. The curl flavor
        # lives in this attribute; cc/codex resolve via the ctx-sandbox path
        # above and never reach here.
        case Map.get(ctx, :self_uri) do
          %URI{} = uri ->
            case Ezagent.AgentFlavorAttributes.get(uri) do
              {:ok, flavor} when is_binary(flavor) and flavor != "" -> {:ok, flavor}
              _ -> :none
            end

          _ ->
            :none
        end
    end
  end

  # The transport class is `:in_process_sync` ONLY when the agent's flavor
  # resolved AND its registered adapter declares that class. A `:none` flavor
  # or a `:subprocess_ws` adapter (or no adapter yet) is NOT sync.
  defp in_process_sync?({:ok, flavor}) when is_binary(flavor) do
    Ezagent.AgentBridge.AdapterRegistry.transport_class(flavor) == :in_process_sync
  end

  defp in_process_sync?(_), do: false

  defp agent_uri_meta(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp resolve_agent_flavor_from_ctx(ctx) do
    ctx
    |> get_in([:siblings, :sandbox])
    |> EzagentDomainInstanceMessage.UriQueryResolvers.resolve_flavor_from_sandbox()
  end

  def attachment_hint_text([]), do: ""

  def attachment_hint_text(list) do
    parts =
      Enum.map(list, fn att ->
        type = att[:type] || att["type"] || "unknown"
        name = att[:name] || att["name"] || "?"
        "[attachment: type=#{type} name=#{name}]"
      end)

    Enum.join(parts, " ")
  end

  defp system_caps(name) when is_binary(name) do
    name
    |> Ezagent.SystemPrincipal.uri()
    |> Ezagent.SystemPrincipal.caps()
  end
end
