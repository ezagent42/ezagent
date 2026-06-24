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

  @spec dispatch_cross_session_call(URI.t(), Message.t(), URI.t()) :: term()
  def dispatch_cross_session_call(target_session_uri, %Message{} = msg, source_session_uri) do
    # System-principal elimination (#154 甲-4): the ambient
    # `system://chat-router` WILDCARD principal is DELETED. A cross-session
    # forward (Decision-#97 routing) now presents a narrow inline
    # `session.send` cap on the CONCRETE target session, granted_by the
    # SOURCE session (a real entity — the forwarding session is the
    # authorizing party; `granted_by` is provenance-only, the step-5.5
    # authorizer is `granted_via_ctx_caps?`, never routed through Grant).
    #
    # SAME-WORKSPACE GUARD: the only designed cross-session-forward use case
    # is intra-workspace oncall/escalation routing (cross-workspace forward
    # has no designed use case — grep-confirmed clean). Forbidding cross-ws
    # forward is the by-design containment that bounds this minted cap to a
    # trusted blast radius (keeps Decision-#97 honest, defaults-closed).
    if same_workspace?(source_session_uri, target_session_uri) do
      send_target = Ezagent.URI.with_action(target_session_uri, :session, :send)

      Ezagent.Router.dispatch(%Cmd{
        target: send_target,
        action: :send,
        args: %{message: msg},
        ctx: %{
          caller: msg.sender,
          caps: cross_session_send_caps(target_session_uri, source_session_uri),
          reply: :ignore
        }
      })
    else
      Logger.warning(
        "Ezagent.Behavior.Session: refusing cross-WORKSPACE session forward " <>
          "#{URI.to_string(source_session_uri)} -> #{URI.to_string(target_session_uri)} " <>
          "(no designed use case; #154 甲-4 same-workspace guard)"
      )

      {:error, :cross_workspace_forward_forbidden}
    end
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

    # Cold-member revival: an `agent` member (e.g. a hello builder) that has gone
    # cold since the last boot would otherwise never process this fan-out receive
    # — a `reply: :ignore` cast to a non-live Kind lands in PendingDelivery and is
    # never delivered (the session's chat never gets a reply after a restart).
    # Revive it from its snapshot first so the receive reaches a live process.
    # `ensure_live/1` no-ops when already live or when there is no snapshot
    # ({:error, :not_created}); `user` recipients are passive inboxes that do not
    # need a live process, so they are left untouched.
    if receive_prefix == :agent do
      _ = Ezagent.SpawnRegistry.ensure_live(recipient_uri)
    end

    receive_target = Ezagent.URI.with_action(recipient_uri, receive_prefix, :receive)

    result =
      Ezagent.Router.dispatch(%Cmd{
        target: receive_target,
        action: :receive,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          caps: member_receive_caps(recipient_uri),
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

  # System-principal elimination (#154 甲-4) — the receive fan-out presents
  # the RECIPIENT's own narrow `<entity>.receive` cap on its OWN instance
  # instead of borrowing the ambient `system://chat-router` WILDCARD. The
  # grant traces to the member itself (`granted_by: recipient_uri`) — a real
  # entity (#154-ok), the self-consent the member gave by joining the
  # session. Inline = provenance-only, the step-5.5 authorizer
  # (`granted_via_ctx_caps?`), never routed through Grant.
  #
  # `kind`/`behavior: :any`: the needed-cap (kind, behavior) pair for
  # `:receive` varies across the OPEN plugin set — `(:user,
  # Behavior.User.Receive)` for a user, `(:agent, Behavior.Agent.Receive)`
  # for the unified agent, and a per-plugin Kind/Behavior for flavors with
  # their own Kind (echo/np/…). Enumerating that set is exactly what the
  # former `system://chat-router` wildcard avoided; `instance` (THIS one
  # recipient) already uniquely identifies the target entity, so pinning
  # `action: :receive` + `instance` keeps the cap least-privilege (it
  # authorizes ONLY a receive into this exact member, nothing else) without
  # the enumeration — and a literal ref to the cross-app
  # `Behavior.Agent.Receive` would also trip the `undeclared_umbrella_dep_test`
  # gate (allowlist `[]`).
  @spec member_receive_caps(URI.t()) :: MapSet.t()
  defp member_receive_caps(%URI{} = recipient_uri) do
    MapSet.new([
      %Ezagent.Capability{
        Ezagent.Capability.cap(
          :any,
          :any,
          :receive,
          Ezagent.URI.instance(recipient_uri),
          Ezagent.Capability.workspace_of(recipient_uri)
        )
        | granted_by: recipient_uri,
          granted_at: DateTime.utc_now()
      }
    ])
  end

  # System-principal elimination (#154 甲-4) — the cross-session forward
  # presents a narrow `session.send` cap on the CONCRETE target session,
  # granted_by the SOURCE session (a real entity; provenance-only). The
  # behavior axis IS concrete (`Ezagent.Behavior.Session`, the registered
  # `:send` Behavior in THIS app — same as the merged 甲-3 chat-reply
  # pattern) so the cap is least-privilege on every axis: only `session.send`
  # into this exact target session.
  @spec cross_session_send_caps(URI.t(), URI.t()) :: MapSet.t()
  defp cross_session_send_caps(%URI{} = target_session_uri, %URI{} = source_session_uri) do
    MapSet.new([
      %Ezagent.Capability{
        Ezagent.Capability.cap(
          :session,
          Ezagent.Behavior.Session,
          :send,
          Ezagent.URI.instance(target_session_uri),
          Ezagent.Capability.workspace_of(target_session_uri)
        )
        | granted_by: source_session_uri,
          granted_at: DateTime.utc_now()
      }
    ])
  end

  # The cross-session-forward containment guard: a forward is permitted only
  # when source and target sessions share a workspace. `workspace_of/1`
  # normalizes both to their workspace URI; `:any` (unscoped) never matches a
  # concrete workspace, so an unresolvable workspace fails closed.
  @spec same_workspace?(URI.t(), URI.t()) :: boolean()
  defp same_workspace?(%URI{} = source_session_uri, %URI{} = target_session_uri) do
    src = Ezagent.Capability.workspace_of(source_session_uri)
    tgt = Ezagent.Capability.workspace_of(target_session_uri)

    match?(%URI{}, src) and match?(%URI{}, tgt) and
      URI.to_string(src) == URI.to_string(tgt)
  end
end
