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
      body: Message.Body.body_text(msg.body),
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

  defp system_caps(name) when is_binary(name) do
    name
    |> Ezagent.SystemPrincipal.uri()
    |> Ezagent.SystemPrincipal.caps()
  end
end
