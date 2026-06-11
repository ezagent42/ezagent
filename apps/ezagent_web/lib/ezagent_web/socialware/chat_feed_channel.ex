defmodule EzagentWeb.Socialware.ChatFeedChannel do
  @moduledoc """
  P4 — authenticated transport for a CHAT session's external SPA view, the
  CALLER-owned Phoenix channel that serves the `:pull` `chat_feed`
  `ExternalAdapter`. The chat analogue of `EzagentWeb.Socialware.CustomerChannel`
  (P3-2): it reuses the SAME lower-bound cursor join protocol + advisory replay,
  but over the chat `inserted_at` cursor and gated by LIVE chat membership
  (`ChatFeed`), NOT a customer token.

  Join replies and live pushes are derived exclusively from
  `Ezagent.Socialware.ChatFeed`, so operator-only / raw session content is never
  exposed on this route. The channel owns the per-connection state the stateless
  adapter cannot: the verified caller `%URI{}` (from `ChatFeedAuth`), the
  subscription to the chat-feed advisory, and the lower-bound replay cursor.

  ## Lower-bound cursor join protocol (over the chat composite keyset cursor)

  On `join/3` the channel subscribes to the EXISTING canonical chat event topic
  for the session FIRST (so no event is missed while the snapshot is read), then
  delegates to `ChatFeed.join/3`, which renders the gated snapshot and replays
  the full backlog so a message landing in the join window — even with its
  advisory dropped — is re-included (idempotent: re-rendered, never skipped). The
  stored cursor is the `{inserted_at, message_id}` keyset of the last replayed
  row.

  ## Live advisory source (P4 codex finding 1 — HIGH)

  The channel subscribes to **`esr:session:<session_uri>:events`** — the SAME
  canonical topic the production chat write path already broadcasts to (the
  `:notify` effect in `Ezagent.Behavior.Chat.handle_send/2` emits
  `{:chat_message, session_uri, msg}` there; member join/leave emit membership
  events on the same topic). There is NO bespoke `{:chat_feed_delivery}`
  broadcast in production — reusing the existing topic (reuse > new) is what
  makes the live update fire at all. ANY event on that topic is treated as an
  ADVISORY ONLY: the channel re-reads from the durable composite cursor via
  `ChatFeed.replay/3` and NEVER trusts the event payload as the delivery. Losing
  an event cannot lose a message because the next event / reconnect replays from
  the unchanged cursor. The replay RE-AUTHORIZES live, so a member who LEFT stops
  receiving pushes immediately.
  """
  use Phoenix.Channel

  alias Ezagent.Behavior.Chat.Delivery
  alias Ezagent.Socialware.ChatFeed
  alias EzagentWeb.Socialware.FeedEncoding

  @impl true
  def join("socialware:chat_feed:" <> session_str, _params, socket) do
    session_uri = socket.assigns.session_uri
    caller = socket.assigns.caller

    with true <- session_str == URI.to_string(session_uri),
         :ok <-
           Phoenix.PubSub.subscribe(
             EzagentCore.PubSub,
             Delivery.session_events_topic(session_uri)
           ),
         {:ok, %{snapshot: snapshot, cursor: cursor}} <- ChatFeed.join(session_uri, caller) do
      {:ok, %{snapshot: encode_snapshot(snapshot)}, assign(socket, :feed_cursor, cursor)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # The production chat-message advisory (the canonical event the chat write path
  # broadcasts) — re-read from the durable cursor (ADVISORY ONLY; the payload is
  # never trusted as the delivery).
  @impl true
  def handle_info({:chat_message, _session_uri, _msg}, socket), do: replay_from_cursor(socket)

  # Any OTHER event on the session topic (e.g. membership changes) is ignored —
  # the chat_feed read is message-only.
  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp replay_from_cursor(socket) do
    cursor = Map.get(socket.assigns, :feed_cursor, ChatFeed.epoch_cursor())

    case ChatFeed.replay(socket.assigns.session_uri, socket.assigns.caller, cursor) do
      {:ok, %{snapshot: snapshot, cursor: new_cursor}} ->
        push(socket, "snapshot", encode_snapshot(snapshot))
        {:noreply, assign(socket, :feed_cursor, new_cursor)}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  defp encode_snapshot(%{messages: messages, page: page}) do
    %{messages: FeedEncoding.encode_messages(messages), page: page}
  end
end
