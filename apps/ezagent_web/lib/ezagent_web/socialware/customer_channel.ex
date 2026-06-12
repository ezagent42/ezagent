defmodule EzagentWeb.Socialware.CustomerChannel do
  @moduledoc """
  Authenticated transport for the gated socialware customer projection — the
  CALLER-owned Phoenix channel that serves the `:pull` `customer_feed`
  `ExternalAdapter` (P3-2).

  Join replies and live pushes are derived exclusively from
  `Ezagent.Socialware.CustomerFeed`, so operator-only / raw session content is
  never exposed on this customer route. The channel owns the per-connection
  state the stateless adapter cannot: `CustomerAuth`, the subscription to the
  `{:customer_delivery}` advisory, and the LOWER-BOUND replay cursor.

  ## Lower-bound cursor join protocol (codex P3 rev1 HIGH-3 + rev2 HIGH-1)

  On `join/3` the channel:

    1. subscribes to the `{:customer_delivery}` topic FIRST (so no advisory is
       missed while the snapshot is read);
    2. delegates to `CustomerFeed.join/3`, which captures `lower =
       latest_cursor` BEFORE the snapshot content read, takes the gated
       snapshot, then replays `committed_deliveries_since(lower)`;
    3. stores the returned cursor (the max `committed_seq` actually replayed).

  Because `lower` is captured before the content read, a commit landing in the
  narrow window between the content read and the replay — even with its advisory
  dropped — is re-included by the replay. Replay is idempotent by
  `committed_seq`, so a row may be re-delivered (harmless) but is NEVER skipped.

  Every advisory `{:customer_delivery}` (treated as ADVISORY-ONLY) triggers
  `CustomerFeed.replay/3` from the stored cursor: losing an advisory cannot lose
  a delivery, because the next advisory / reconnect replays from the unchanged
  cursor and catches it.
  """
  use Phoenix.Channel

  alias Ezagent.Session.CustomerDelivery
  alias Ezagent.Socialware.CustomerFeed
  alias EzagentWeb.Socialware.FeedEncoding

  @impl true
  def join("socialware:customer:" <> session_str, _params, socket) do
    session_uri = socket.assigns.session_uri
    token = socket.assigns.token

    # Step 1: subscribe FIRST so no advisory is lost while the snapshot is read.
    with true <- session_str == URI.to_string(session_uri),
         :ok <-
           Phoenix.PubSub.subscribe(EzagentCore.PubSub, CustomerDelivery.topic(session_uri)),
         # Steps 2-3: lower-bound capture -> gated snapshot -> replay -> cursor.
         {:ok, %{snapshot: snapshot, cursor: cursor}} <- CustomerFeed.join(session_uri, token) do
      {:ok, %{snapshot: encode_snapshot(snapshot)}, assign(socket, :feed_cursor, cursor)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("history", _params, socket) do
    case CustomerFeed.history(socket.assigns.session_uri, socket.assigns.token) do
      {:ok, %{messages: messages}} ->
        {:reply, {:ok, %{messages: FeedEncoding.encode_messages(messages)}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_info({:customer_delivery, _payload}, socket) do
    # ADVISORY-ONLY wake-up: replay from the stored lower-bound cursor (never
    # trusting the advisory's payload to carry the delivery). Idempotent: a
    # delivery already covered by the cursor is not re-pushed; the cursor only
    # advances to the max committed_seq actually replayed.
    cursor = Map.get(socket.assigns, :feed_cursor, 0)

    case CustomerFeed.replay(socket.assigns.session_uri, socket.assigns.token, cursor) do
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
