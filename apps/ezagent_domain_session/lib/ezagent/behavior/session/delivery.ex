defmodule Ezagent.ActionSet.Session.Delivery do
  @moduledoc false

  require Logger

  alias Ezagent.{Cmd, Message, MessageStore}

  @doc """
  Fan ONE recipient's delivery OFF the `handle_send` hot path
  (send-echo-decouple, 2026-07-08; per-recipient serialization per codex
  HIGH-1 rework).

  Enqueues the delivery into `Ezagent.Session.DeliveryQueue`, keyed by the
  recipient's instance URI (for a cross-session forward the recipient IS the
  target session URI — same key derivation). The queue runs ONE job per key at
  a time, FIFO, each in an unlinked Task under
  `Ezagent.Session.DeliverySupervisor`:

  - **Sender echo (Prong A)** — the Session Kind emits its
    `{:notify, :chat_message}` feed broadcast the moment `handle_send` returns;
    delivery never runs in-handler, so the echo is fast even when a member is
    dead.
  - **Per-recipient ORDER (codex HIGH-1)** — the Session Kind processes sends
    serially and enqueues in that order; one-in-flight-per-key means a
    recipient observes messages in exactly send order (`last_received` /
    `recent_messages` / ReadMarker's monotonic cursor / agent-bridge pushes
    all stay msg1-before-msg2).
  - **Dead-member isolation (Prong B)** — each recipient's FULL delivery
    (cold-member `ensure_live` revival + the `:receive`/cross-session dispatch
    + the ReadMarker) runs under its OWN key; a dead/slow member backs up its
    own queue only and can never delay a sibling, the pipeline, or the next
    send. A crashing delivery cannot touch the Session Kind.

  ## Delivery contract — at-most-once, loudly attributed (codex MED-2)

  Fire-and-forget: `handle_send` already emitted its effects, so a delivery can
  return nothing to anyone. There is NO retry: a job that raises is logged with
  full attribution (recipient + message id + session) plus a best-effort
  `Ezagent.Routing.Trace` `delivery_failed` row, then its key advances (one
  poisoned message never wedges its recipient's queue). Queued jobs are held in
  memory — a node restart drops them; message durability is `MessageStore`
  (history / replay-on-join), exactly the pre-decouple contract.

  A delivery job can OUTLIVE its source session (session destroyed while the
  job waits/runs). Safe by construction: `:receive` authorization is the
  recipient's OWN held member-cap checked in-handler at delivery time, so a
  destroyed session's revoked members simply fail authorization.
  """
  @spec deliver_async(URI.t(), map() | nil, Message.t(), map(), URI.t()) :: :ok
  def deliver_async(
        %URI{} = recipient,
        rule_ctx,
        %Message{} = msg,
        prompt_templates,
        %URI{} = session_uri
      )
      when is_map(prompt_templates) do
    key = URI.to_string(recipient)

    Ezagent.Session.DeliveryQueue.enqueue(key, fn ->
      try do
        deliver_now(recipient, rule_ctx, msg, prompt_templates, session_uri)
      catch
        kind, reason ->
          # codex MED-2 — a background delivery failure is post-success (the
          # sender already saw the message land), so it MUST be loudly
          # attributable: recipient + message + session, plus a routing-trace
          # row so `Trace.journey(msg.id)` shows the drop.
          Logger.error(
            "Ezagent.ActionSet.Session.Delivery: delivery FAILED (at-most-once, no retry) " <>
              "recipient=#{key} message_id=#{msg.id} " <>
              "session=#{URI.to_string(session_uri)} " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          record_delivery_failed_trace(msg, key, session_uri, {kind, reason})
      end
    end)
  end

  # Best-effort `routing_traces` row for a failed background delivery (codex
  # MED-2). Never raises — the Logger.error above is the guaranteed signal.
  defp record_delivery_failed_trace(%Message{} = msg, recipient_str, session_uri, failure) do
    workspace_uri =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, uri} -> uri
        :error -> nil
      end

    _ =
      Ezagent.Routing.Trace.record(%{
        message_id: msg.id,
        workspace_uri: workspace_uri,
        rule_id: "delivery_failed",
        receivers: [recipient_str],
        hop: msg.hops,
        drop_reason: inspect(failure)
      })

    :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Deliver a single already-routed recipient SYNCHRONOUSLY (cross-session forward
  or per-recipient `:receive` fan-out with the §3.4 Path-A render). Normally run
  inside a `deliver_async/5` Task; exposed for direct/testing use.
  """
  @spec deliver_now(URI.t(), map() | nil, Message.t(), map(), URI.t()) :: term()
  def deliver_now(
        %URI{} = recipient,
        rule_ctx,
        %Message{} = msg,
        prompt_templates,
        %URI{} = session_uri
      )
      when is_map(prompt_templates) do
    if recipient.scheme == "session" do
      dispatch_cross_session_call(recipient, msg, session_uri)
    else
      # Path-A delivery transform (§3.4): render the matched rule's prompt
      # template into THIS recipient's message (no template → unchanged).
      # Applies to agent + user recipients alike.
      delivered = render_for_delivery(msg, rule_ctx, prompt_templates, session_uri)
      dispatch_receive_call(recipient, delivered, session_uri)
    end
  end

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
              "Ezagent.ActionSet.Session: notify mention_failed raised for " <>
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
        "Ezagent.ActionSet.Session: refusing cross-WORKSPACE session forward " <>
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
      _ = Ezagent.Domain.Agent.ensure_deliverable(recipient_uri)
    end

    receive_target = Ezagent.URI.with_action(recipient_uri, receive_prefix, :receive)

    result =
      Ezagent.Router.dispatch(%Cmd{
        target: receive_target,
        action: :receive,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          # Membership-cap unification A2.2 (spec R1.1) — delivery presents NO
          # receive cap. `:members` is a staleness-tolerant delivery ROSTER, not
          # authority; receive AUTHORIZATION is the recipient's OWN held member-cap,
          # checked in-handler via `MemberReceive.authorize/1`. The ephemeral
          # `member_receive_caps/1` bearer token (a stale copy authorized whoever
          # presented it — the R1.1 bug) is DELETED.
          caps: MapSet.new(),
          reply: :ignore
        }
      })

    case result do
      :ok ->
        _ = Ezagent.Session.ReadMarker.mark(session_uri, recipient_uri, msg.id, :delivered)

      {:error, :buffer_full} ->
        # PR #1259 codex review item 2 — the recipient is `:not_ready` (e.g. a
        # py member cold-provisioning its subprocess) and its PendingDelivery
        # buffer is at cap: the message was DROPPED at dispatch, which now
        # surfaces `{:error, :buffer_full}` instead of a silent `:ok`. Do NOT
        # mark it delivered (the `:ok`-gate above); make the drop loudly
        # attributable here too — recipient + message + session — and record a
        # `routing_traces` row so `Trace.journey(msg.id)` shows the drop.
        Logger.error(
          "Ezagent.ActionSet.Session.Delivery: receive fan-out DROPPED " <>
            "(PendingDelivery buffer full on a not-ready member; at-most-once, no retry) " <>
            "recipient=#{URI.to_string(recipient_uri)} message_id=#{msg.id} " <>
            "session=#{URI.to_string(session_uri)}"
        )

        record_delivery_dropped_trace(msg, recipient_uri, session_uri, :buffer_full)

      _other ->
        :ok
    end

    result
  end

  # Best-effort `routing_traces` row for a message DROPPED pre-delivery (the
  # PendingDelivery overflow path). Never raises — the Logger.error above is
  # the guaranteed signal. Mirrors `record_delivery_failed_trace/4`.
  defp record_delivery_dropped_trace(%Message{} = msg, recipient_uri, session_uri, reason) do
    workspace_uri =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, uri} -> uri
        :error -> nil
      end

    _ =
      Ezagent.Routing.Trace.record(%{
        message_id: msg.id,
        workspace_uri: workspace_uri,
        rule_id: "delivery_dropped",
        # `Trace.record/1` stringifies receivers itself (`to_trace_string/1`)
        # — passing the %URI{} keeps this site out of the uri_query scan's
        # `uri_string_key` category.
        receivers: [recipient_uri],
        hop: msg.hops,
        drop_reason: reason
      })

    :ok
  catch
    _, _ -> :ok
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

  # System-principal elimination (#154 甲-4) — the cross-session forward
  # presents a narrow `session.send` cap on the CONCRETE target session,
  # granted_by the SOURCE session (a real entity; provenance-only). The
  # behavior axis IS concrete (`Ezagent.ActionSet.Session`, the registered
  # `:send` Behavior in THIS app — same as the merged 甲-3 chat-reply
  # pattern) so the cap is least-privilege on every axis: only `session.send`
  # into this exact target session.
  @spec cross_session_send_caps(URI.t(), URI.t()) :: MapSet.t()
  defp cross_session_send_caps(%URI{} = target_session_uri, %URI{} = source_session_uri) do
    MapSet.new([
      %Ezagent.Capability{
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
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
