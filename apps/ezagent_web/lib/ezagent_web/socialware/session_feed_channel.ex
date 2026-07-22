defmodule EzagentWeb.Socialware.SessionFeedChannel do
  @moduledoc """
  Adapter-parameterized socialware feed channel.

  The channel resolves a registered `:pull` `Ezagent.ExternalMirror.Adapter`
  from the topic, subscribes to the adapter-declared live topics before the first
  read, then branches on the adapter's delivery discipline:

    * `:snapshot_refresh` re-renders the current snapshot on every advisory and
      stores no cursor.
    * `:cursor_replay` stores a lower-bound cursor and replays from that cursor
      on every advisory.

  PubSub messages are advisory wake-ups only; payloads are never trusted as feed
  content.
  """

  use Phoenix.Channel

  require Logger

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Socialware.{AnonUser, ExternalFeed}
  alias EzagentWeb.Socialware.FeedEncoding

  @adapter Module.concat(["Ezagent", "ExternalMirror", "Adapter"])
  @adapter_registry Module.concat(["Ezagent", "ExternalMirror", "AdapterRegistry"])

  @impl true
  def join(topic, _params, socket) do
    with {:ok, adapter_id, %URI{} = session_uri} <- parse_topic(topic),
         true <- session_uri == socket.assigns.session_uri,
         {:ok, adapter} <- adapter_lookup(adapter_id),
         :ok <- subscribe_live_topics(adapter, session_uri) do
      join_by_discipline(adapter_id, adapter, session_uri, socket.assigns.caller, socket)
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("post", params, socket) do
    case socket.assigns.participation_profile do
      :read_only -> {:reply, {:error, %{reason: "read_only"}}, socket}
      :participatory -> handle_participatory_post(params, socket)
    end
  end

  def handle_in("join", _params, socket) do
    case socket.assigns.participation_profile do
      :read_only -> {:reply, {:error, %{reason: "read_only"}}, socket}
      :participatory -> handle_participatory_join(socket)
    end
  end

  def handle_in("history", _params, socket) do
    case socket.assigns.participation_profile do
      :read_only -> {:reply, {:error, %{reason: "read_only"}}, socket}
      :participatory -> handle_participatory_history(socket)
    end
  end

  @impl true
  def handle_info(_advisory, %{assigns: %{delivery_discipline: :snapshot_refresh}} = socket) do
    refresh_snapshot(socket)
  end

  def handle_info(_advisory, %{assigns: %{delivery_discipline: :cursor_replay}} = socket) do
    replay_from_cursor(socket)
  end

  defp join_by_discipline(adapter_id, adapter, session_uri, caller, socket) do
    discipline = adapter_delivery_discipline(adapter)
    profile = adapter_participation_profile(adapter)

    socket =
      socket
      |> assign(:adapter_id, adapter_id)
      |> assign(:adapter, adapter)
      |> assign(:delivery_discipline, discipline)
      |> assign(:participation_profile, profile)

    case discipline do
      :snapshot_refresh ->
        case adapter.render_authorized(session_uri, caller) do
          {:ok, snapshot} ->
            {:ok, %{snapshot: encode_snapshot(snapshot, socket)}, socket}

          {:error, _} ->
            {:error, %{reason: "unauthorized"}}
        end

      :cursor_replay ->
        case adapter.join_with_cursor(session_uri, caller) do
          {:ok, %{snapshot: snapshot, cursor: cursor}} ->
            {:ok, %{snapshot: encode_snapshot(snapshot, socket)},
             assign(socket, :feed_cursor, cursor)}

          {:error, _} ->
            {:error, %{reason: "unauthorized"}}
        end
    end
  end

  defp refresh_snapshot(socket) do
    case socket.assigns.adapter.render_authorized(
           socket.assigns.session_uri,
           socket.assigns.caller
         ) do
      {:ok, snapshot} ->
        push(socket, "snapshot", encode_snapshot(snapshot, socket))
        {:noreply, socket}

      {:error, :unauthorized} ->
        push(socket, "unauthorized", %{reason: "membership_revoked"})
        {:stop, :shutdown, socket}
    end
  end

  defp replay_from_cursor(socket) do
    cursor = Map.fetch!(socket.assigns, :feed_cursor)

    case socket.assigns.adapter.replay(
           socket.assigns.session_uri,
           socket.assigns.caller,
           cursor
         ) do
      {:ok, %{snapshot: snapshot, cursor: new_cursor}} ->
        push(socket, "snapshot", encode_snapshot(snapshot, socket))
        {:noreply, assign(socket, :feed_cursor, new_cursor)}

      {:error, :unauthorized} ->
        push(socket, "unauthorized", %{reason: "membership_revoked"})
        {:stop, :shutdown, socket}
    end
  end

  defp subscribe_live_topics(adapter, session_uri) do
    Enum.each(adapter.live_topics(session_uri), fn topic ->
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
    end)

    :ok
  end

  defp adapter_lookup(adapter_id), do: apply(@adapter_registry, :lookup, [adapter_id])

  defp adapter_delivery_discipline(adapter),
    do: apply(@adapter, :delivery_discipline_of, [adapter])

  defp adapter_participation_profile(adapter),
    do: apply(@adapter, :participation_profile_of, [adapter])

  defp parse_topic("socialware:feed:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [adapter_id, session_str] when adapter_id != "" ->
        parse_session(adapter_id, session_str)

      _ ->
        :error
    end
  end

  defp parse_topic("socialware:chat_feed:" <> session_str),
    do: parse_session("chat_feed", session_str)

  defp parse_topic("socialware:external:" <> session_str),
    do: parse_session("external_feed", session_str)

  defp parse_topic(_), do: :error

  defp parse_session(adapter_id, session_str) do
    case Ezagent.URI.new!(session_str) do
      %URI{scheme: "session"} = session_uri -> {:ok, adapter_id, session_uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp encode_snapshot(snapshot, %{assigns: %{adapter_id: "external_feed"}} = socket)
       when is_map(snapshot) do
    %{
      messages: FeedEncoding.encode_messages(Map.get(snapshot, :messages, [])),
      chat: full_chat(socket),
      page: Map.get(snapshot, :page),
      shell: Map.get(snapshot, :shell),
      shell_css: Map.get(snapshot, :shell_css),
      viewer: viewer(socket)
    }
  end

  defp encode_snapshot(snapshot, _socket) when is_map(snapshot) do
    Map.update(snapshot, :messages, [], &FeedEncoding.encode_messages/1)
  end

  defp handle_participatory_join(socket) do
    session_uri = socket.assigns.session_uri

    case signed_in_principal(socket) do
      %URI{} = principal ->
        _ = Ezagent.Entity.spawn_principal(principal)

        with :ok <- maybe_adapter_join(socket.assigns.adapter, session_uri, principal),
             :ok <-
               Membership.provision_invited_join_authority(
                 session_uri,
                 principal,
                 Ezagent.Entity.User.admin_uri()
               ),
             :ok <- dispatch_join(session_uri, principal) do
          # D1 join 补发:participation tier + view caps + mount operate keys。
          _ = Ezagent.Socialware.MemberBackfill.backfill(session_uri, principal)
          push_viewer_snapshot(socket)
          {:reply, :ok, socket}
        else
          other ->
            Logger.warning(
              "SessionFeedChannel: external join failed for #{URI.to_string(principal)} on " <>
                "#{URI.to_string(session_uri)}: #{inspect(other)}"
            )

            {:reply, {:error, %{reason: "join_failed"}}, socket}
        end

      _ ->
        {:reply, {:error, %{reason: "not_logged_in"}}, socket}
    end
  end

  defp handle_participatory_post(%{"text" => text}, socket) when is_binary(text) do
    trimmed = String.trim(text)

    case signed_in_principal(socket) do
      %URI{} = principal when trimmed != "" ->
        case maybe_adapter_post(
               socket.assigns.adapter,
               socket.assigns.session_uri,
               principal,
               trimmed
             ) do
          :ok -> {:reply, :ok, socket}
          {:error, reason} -> {:reply, {:error, %{reason: reason_name(reason)}}, socket}
        end

      %URI{} ->
        {:reply, {:error, %{reason: "empty"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "not_logged_in"}}, socket}
    end
  end

  defp handle_participatory_post(_params, socket),
    do: {:reply, {:error, %{reason: "bad_args"}}, socket}

  defp handle_participatory_history(socket) do
    case maybe_adapter_history(
           socket.assigns.adapter,
           socket.assigns.session_uri,
           socket.assigns.caller
         ) do
      {:ok, %{messages: messages}} ->
        {:reply, {:ok, %{messages: FeedEncoding.encode_messages(messages)}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason_name(reason)}}, socket}
    end
  end

  defp maybe_adapter_join(adapter, session_uri, principal) do
    if function_exported?(adapter, :join, 2),
      do: adapter.join(session_uri, principal),
      else: :ok
  end

  defp maybe_adapter_post(adapter, session_uri, principal, text) do
    if function_exported?(adapter, :post, 3),
      do: adapter.post(session_uri, principal, text),
      else: dispatch_post(session_uri, principal, text)
  end

  defp maybe_adapter_history(adapter, session_uri, caller) do
    if function_exported?(adapter, :history, 2),
      do: adapter.history(session_uri, caller),
      else: {:ok, %{messages: []}}
  end

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(reason) when is_binary(reason), do: reason
  defp reason_name(_reason), do: "failed"

  defp full_chat(socket) do
    case ExternalFeed.chat_messages(socket.assigns.session_uri, socket.assigns.caller) do
      {:ok, messages} -> FeedEncoding.encode_messages(messages)
      _ -> []
    end
  end

  defp viewer(socket) do
    case signed_in_principal(socket) do
      %URI{} = principal ->
        %{
          logged_in: true,
          member: member?(socket.assigns.session_uri, principal),
          name: principal_name(principal)
        }

      _ ->
        %{logged_in: false, member: false}
    end
  end

  # The short username the nav shows when logged in (the identity name segment,
  # e.g. entity://system/user/ruihua → "ruihua"); falls back to the full URI.
  defp principal_name(%URI{} = principal) do
    case Ezagent.URI.name(principal) do
      {:ok, name} -> name
      _ -> URI.to_string(principal)
    end
  end

  defp signed_in_principal(socket) do
    case socket.assigns[:caller] do
      %URI{} = caller -> if AnonUser.anon_uri?(caller), do: nil, else: caller
      _ -> nil
    end
  end

  defp member?(session_uri, %URI{} = principal) do
    # STRICT membership — not `snapshot/2`, which now also succeeds for a
    # public_view non-member reader. A non-member must read `member: false` so the
    # surface offers "加入" (join) rather than the "发送" composer.
    ExternalFeed.member?(session_uri, principal)
  end

  defp dispatch_join(session_uri, %URI{} = principal) do
    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: Ezagent.URI.with_action(session_uri, :session, :join),
           mode: :call,
           args: %{member: principal},
           ctx: %{caller: principal, authenticated_principal: principal, reply: :ignore},
           origin: :authenticated_external
         }) do
      {:ok, %{status: status, member: ^principal}}
      when status in [:granted, :already_member] ->
        :ok

      {:ok, %{status: :pending, member: ^principal}} ->
        {:error, :admission_pending}

      other ->
        other
    end
  end

  # EVERY user message goes to the invisible FRONT-DESK (the `hello.front-desk`
  # chat relay agent). It — not this web layer — decides per message, by intent ×
  # identity, whether to dispatch to the page builder (`:rebuild`) or the read-only
  # concierge (`:answer`). The chat fan-out is mention-gated
  # (`Behavior.Session` §:send); `Definition.routing_rules`'
  # `{:always} -> {:role, "front-desk"}` rule is the primary delivery path — this
  # mention is the belt to its suspenders.
  defp dispatch_post(session_uri, %URI{} = principal, text) do
    mentions =
      case EzagentPluginHello.Members.role_uri(session_uri, "front-desk") do
        {:ok, fd_uri} -> [fd_uri]
        :error -> []
      end

    msg = Ezagent.Message.new(principal, %{text: text, attachments: []}, mentions: mentions)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :send),
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: principal, authenticated_principal: principal, reply: :ignore},
      origin: :authenticated_external
    })
  end

  defp push_viewer_snapshot(socket) do
    case ExternalFeed.snapshot(socket.assigns.session_uri, socket.assigns.caller) do
      {:ok, snapshot} -> push(socket, "snapshot", encode_snapshot(snapshot, socket))
      _ -> :ok
    end
  end
end
