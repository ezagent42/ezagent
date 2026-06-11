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

  ## Lower-bound cursor join protocol (over the chat inserted_at cursor)

  On `join/3` the channel subscribes to the chat-feed advisory topic FIRST (so
  no advisory is missed while the snapshot is read), then delegates to
  `ChatFeed.join/3`, which renders the gated snapshot and replays the full
  backlog so a message landing in the join window — even with its advisory
  dropped — is re-included (idempotent: re-rendered, never skipped). The stored
  cursor is the max `inserted_at` actually replayed.

  Every advisory triggers `ChatFeed.replay/3` from the stored cursor (ADVISORY-
  ONLY): losing an advisory cannot lose a message because the next advisory /
  reconnect replays from the unchanged cursor. The replay RE-AUTHORIZES live, so
  a member who LEFT stops receiving pushes immediately.
  """
  use Phoenix.Channel

  alias Ezagent.Socialware.ChatFeed
  alias EzagentWeb.Socialware.FeedEncoding

  @impl true
  def join("socialware:chat_feed:" <> session_str, _params, socket) do
    session_uri = socket.assigns.session_uri
    caller = socket.assigns.caller

    with true <- session_str == URI.to_string(session_uri),
         :ok <- Phoenix.PubSub.subscribe(EzagentCore.PubSub, ChatFeed.topic(session_uri)),
         {:ok, %{snapshot: snapshot, cursor: cursor}} <- ChatFeed.join(session_uri, caller) do
      {:ok, %{snapshot: encode_snapshot(snapshot)}, assign(socket, :feed_cursor, cursor)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:chat_feed_delivery, _payload}, socket) do
    cursor = Map.get(socket.assigns, :feed_cursor, epoch())

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

  defp epoch, do: ~U[1970-01-01 00:00:00.000000Z]
end
