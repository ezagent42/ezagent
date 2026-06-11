defmodule EzagentWeb.Socialware.ChatFeedChannel do
  @moduledoc """
  P4 — authenticated transport for a CHAT session's external SPA view, the
  CALLER-owned Phoenix channel that serves the `:pull` `chat_feed`
  `ExternalAdapter`. The chat analogue of `EzagentWeb.Socialware.CustomerChannel`
  (P3-2), but with a **windowed snapshot-refresh** read model instead of the
  customer feed's delta cursor: every read returns the CURRENT latest-N chat
  snapshot, gated by LIVE chat membership (`ChatFeed`), NOT a customer token.

  Join replies and live pushes are derived exclusively from
  `Ezagent.Socialware.ChatFeed.snapshot/2`, so operator-only / raw session
  content is never exposed on this route. The channel owns the per-connection
  state the stateless adapter cannot: the verified caller `%URI{}` (from
  `ChatFeedAuth`) and the subscription to the chat event topic. There is NO
  cursor in `socket.assigns`.

  ## Snapshot-refresh join protocol

  On `join/3` the channel subscribes to the EXISTING canonical chat event topic
  for the session FIRST (so no event is missed while the snapshot is read), THEN
  calls `ChatFeed.snapshot/2`, which authorizes + renders the current latest-N
  snapshot. Subscribe-first means a message landing in the join window triggers
  an advisory whose re-read shows current state; a message present at join is
  already in the snapshot.

  ## Live advisory source (P4 codex finding 1 — HIGH)

  The channel subscribes to **`esr:session:<session_uri>:events`** — the SAME
  canonical topic the production chat write path already broadcasts to (the
  `:notify` effect in `Ezagent.Behavior.Chat.handle_send/2` emits
  `{:chat_message, session_uri, msg}` there; member join/leave emit membership
  events on the same topic). There is NO bespoke `{:chat_feed_delivery}`
  broadcast in production — reusing the existing topic (reuse > new) is what
  makes the live update fire at all. ANY event on that topic is treated as an
  ADVISORY ONLY: the channel re-reads the CURRENT snapshot via
  `ChatFeed.snapshot/2` and NEVER trusts the event payload as the delivery.
  Losing an advisory cannot lose a message — it is self-healing: the next
  advisory / reconnect re-reads current state. The re-read RE-AUTHORIZES live,
  so a member who LEFT stops receiving pushes immediately.
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
         {:ok, snapshot} <- ChatFeed.snapshot(session_uri, caller) do
      {:ok, %{snapshot: encode_snapshot(snapshot)}, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # The production chat-message advisory (the canonical event the chat write path
  # broadcasts) — re-read the CURRENT snapshot (ADVISORY ONLY; the payload is
  # never trusted as the delivery).
  @impl true
  def handle_info({:chat_message, _session_uri, _msg}, socket), do: refresh_snapshot(socket)

  # Any OTHER event on the session topic (e.g. membership changes) is ignored —
  # the chat_feed read is message-only.
  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp refresh_snapshot(socket) do
    case ChatFeed.snapshot(socket.assigns.session_uri, socket.assigns.caller) do
      {:ok, snapshot} ->
        push(socket, "snapshot", encode_snapshot(snapshot))
        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  defp encode_snapshot(%{messages: messages, page: page}) do
    %{messages: FeedEncoding.encode_messages(messages), page: page}
  end
end
