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
    receive_target = Ezagent.URI.with_action(recipient_uri, :session, :receive)

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
  Runs in the same Agent Kind process as the handler; returns `:ok`
  (the handler emits its own `{:ok, %{}, []}`).
  """
  @spec deliver_agent_receive(Message.t(), map()) :: :ok
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
      "session" => source_session
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
    _ =
      case resolve_agent_flavor_from_ctx(ctx) do
        {:ok, flavor} ->
          Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, flavor)

        :none ->
          Ezagent.AgentBridge.deliver_ensuring(ctx[:self_uri], payload)
      end

    :ok
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
