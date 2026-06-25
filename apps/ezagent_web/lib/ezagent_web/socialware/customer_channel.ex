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

  require Logger

  alias Ezagent.Behavior.Session.{Delivery, Membership}
  alias Ezagent.Session.CustomerDelivery
  alias Ezagent.Socialware.{ChatFeed, CustomerFeed}
  alias EzagentWeb.Socialware.FeedEncoding

  @impl true
  def join("socialware:customer:" <> session_str, _params, socket) do
    session_uri = socket.assigns.session_uri
    token = socket.assigns.token

    # Step 1: subscribe FIRST so no advisory is lost while the snapshot is read.
    with true <- session_str == URI.to_string(session_uri),
         :ok <-
           Phoenix.PubSub.subscribe(EzagentCore.PubSub, CustomerDelivery.topic(session_uri)),
         # Collaborative-whiteboard chat: ALSO subscribe to the canonical session
         # event topic so a NEW chat message (from any participant) re-pushes the
         # snapshot live — the preview chat panel shows everyone's messages, not
         # just committed customer deliveries.
         :ok <-
           Phoenix.PubSub.subscribe(
             EzagentCore.PubSub,
             Delivery.session_events_topic(session_uri)
           ),
         # Steps 2-3: lower-bound capture -> gated snapshot -> replay -> cursor.
         {:ok, %{snapshot: snapshot, cursor: cursor}} <- CustomerFeed.join(session_uri, token) do
      {:ok, %{snapshot: encode_snapshot(snapshot, socket)}, assign(socket, :feed_cursor, cursor)}
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

  # A logged-in viewer self-joins the session so they may post. We provision a
  # narrow `Session.:join` cap (granted_by the session owner — the SAME mechanism
  # the anon flow uses, NO system principal), then dispatch `session.join` AS the
  # viewer through `Ezagent.Invocation.dispatch` (P14 — never a PubSub broadcast
  # to an inbound topic). `mount_participation_caps` then grants the post tier.
  #
  # hello-progress assumption (Allen 2026-06-25): login ⇒ may join the CURRENT
  # session (same-workspace). Cross-workspace join is researched-but-deferred
  # (step 5.6 `:cross_workspace_denied` would block it) — see the cross-workspace
  # research handoff.
  @impl true
  def handle_in("join", _params, socket) do
    session_uri = socket.assigns.session_uri

    case socket.assigns[:viewer_principal] do
      %URI{} = principal ->
        # Bring the viewer's User Kind LIVE + registered first — Session `:join`
        # rejects a member whose Kind is not a live registered target
        # (`:member_not_registered`), e.g. a real user whose Kind went cold after a
        # restart. The chat anon flow does the same `spawn_principal` before joining.
        _ = Ezagent.Entity.spawn_principal(principal)

        # `provision_join_authority/2` is a SELF-join policy gate that denies an
        # arbitrary logged-in user (`:no_authority`). The customer preview vouches
        # for the join at its OWN boundary instead — the session is `public_view`
        # and the viewer is authenticated — so we use the INVITED-join path
        # (`provision_invited_join_authority/3`, "caller already proved invite
        # authority"), granting a narrow per-session join cap via the session
        # owner/admin. This is the "login ⇒ may join the current session"
        # assumption (same-workspace; cross-workspace stays researched-but-deferred).
        with :ok <-
               Membership.provision_invited_join_authority(
                 session_uri,
                 principal,
                 Ezagent.Entity.User.admin_uri()
               ),
             :ok <- dispatch_join(session_uri, principal) do
          _ = Membership.mount_participation_caps(session_uri, principal)
          push_viewer_snapshot(socket)
          {:reply, :ok, socket}
        else
          other ->
            Logger.warning(
              "CustomerChannel: join failed for #{URI.to_string(principal)} on " <>
                "#{URI.to_string(session_uri)}: #{inspect(other)}"
            )

            {:reply, {:error, %{reason: "join_failed"}}, socket}
        end

      _ ->
        {:reply, {:error, %{reason: "not_logged_in"}}, socket}
    end
  end

  # A member posts a chat line that auto-mentions the hello builder, so the
  # message reaches it (== "@hello") with no manual mention. Dispatched AS the
  # member (caller = principal, NO admin cap): CapBAC authorizes from the member's
  # OWN `:caps` slice — a non-member / unconfirmed viewer is denied at dispatch,
  # so this is not a trust boundary, just the affordance. `:cast` fire-and-forget;
  # the builder's reply + regenerated page flow back via the feed advisory.
  @impl true
  def handle_in("post", %{"text" => text}, socket) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      is_nil(socket.assigns[:viewer_principal]) ->
        {:reply, {:error, %{reason: "not_logged_in"}}, socket}

      trimmed == "" ->
        {:reply, {:error, %{reason: "empty"}}, socket}

      true ->
        dispatch_post(socket.assigns.session_uri, socket.assigns.viewer_principal, trimmed)
        {:reply, :ok, socket}
    end
  end

  def handle_in("post", _params, socket),
    do: {:reply, {:error, %{reason: "bad_args"}}, socket}

  @impl true
  def handle_info({:customer_delivery, _payload}, socket) do
    # ADVISORY-ONLY wake-up: replay from the stored lower-bound cursor (never
    # trusting the advisory's payload to carry the delivery). Idempotent: a
    # delivery already covered by the cursor is not re-pushed; the cursor only
    # advances to the max committed_seq actually replayed.
    cursor = Map.get(socket.assigns, :feed_cursor, 0)

    case CustomerFeed.replay(socket.assigns.session_uri, socket.assigns.token, cursor) do
      {:ok, %{snapshot: snapshot, cursor: new_cursor}} ->
        push(socket, "snapshot", encode_snapshot(snapshot, socket))
        {:noreply, assign(socket, :feed_cursor, new_cursor)}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  # Any OTHER subscribed message is a session event (a new chat message from any
  # participant, a membership change, …) — ADVISORY-ONLY: re-read + push the
  # current snapshot so the collaborative chat panel + page update live for every
  # viewer. Mirrors ChatFeedChannel's self-healing advisory model.
  @impl true
  def handle_info(_event, socket) do
    push_viewer_snapshot(socket)
    {:noreply, socket}
  end

  defp encode_snapshot(%{messages: messages, page: page} = snap, socket) do
    # `shell` / `shell_css` carry the page's frame + theme (hybrid HTML shell, or
    # the pure-shadcn AI CSS theme). They MUST ship to the client or the customer
    # SPA renders an unstyled page (PureThemePage/HybridPage need them). `viewer`
    # drives the bottom preview bar's login/join/post state. `chat` is the FULL
    # collaborative conversation (every participant's messages) the preview shows,
    # distinct from `messages` (the committed customer-delivery projection).
    %{
      messages: FeedEncoding.encode_messages(messages),
      chat: full_chat(socket),
      page: page,
      shell: Map.get(snap, :shell),
      shell_css: Map.get(snap, :shell_css),
      viewer: viewer(socket)
    }
  end

  defp full_chat(socket) do
    case CustomerFeed.chat_messages(socket.assigns.session_uri, socket.assigns.token) do
      {:ok, messages} -> FeedEncoding.encode_messages(messages)
      _ -> []
    end
  end

  # The bottom preview bar's identity state. `logged_in` ⇒ a verified viewer_token
  # (ChatFeedAuth) was presented at connect; `member` ⇒ that principal currently
  # passes the session's LIVE membership read, so it may post. Anonymous viewers
  # are `{logged_in: false, member: false}` — read-only by construction.
  defp viewer(socket) do
    case socket.assigns[:viewer_principal] do
      %URI{} = principal ->
        %{logged_in: true, member: member?(socket.assigns.session_uri, principal)}

      _ ->
        %{logged_in: false, member: false}
    end
  end

  # Live membership probe: the gated chat read succeeds iff the caller is an
  # owner/member (the SAME `Membership.authorize/2` predicate the chat feed runs),
  # so a successful snapshot ⇒ member. Self-revoking: an ex-member reads false.
  defp member?(session_uri, %URI{} = principal) do
    match?({:ok, _}, ChatFeed.snapshot(session_uri, principal))
  end

  defp dispatch_join(session_uri, %URI{} = principal) do
    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: Ezagent.URI.with_action(session_uri, :session, :join),
           mode: :call,
           args: %{member: principal},
           ctx: %{caller: principal, reply: :ignore}
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp dispatch_post(session_uri, %URI{} = principal, text) do
    # `mentions` rides the 3rd (opts) arg — NOT the body map. Default visibility is
    # `:customer_visible`, so the member's own line shows back on the customer feed.
    msg =
      Ezagent.Message.new(principal, %{text: text, attachments: []},
        mentions: [builder_uri(session_uri)]
      )

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :send),
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: principal, reply: :ignore}
    })
  end

  # The hello builder agent for this session: `session://<ws>/hello/<name>` ⇒
  # `entity://<ws>/agent/hello_<name>` (mirrors EzagentPluginHello.Generator).
  defp builder_uri(session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    name = session_uri.path |> to_string() |> String.split("/", trim: true) |> List.last()
    Ezagent.URI.entity(ws, :agent, "hello_#{name}")
  end

  # Re-read + push the customer snapshot so the client sees the refreshed `viewer`
  # (e.g. `member: true` right after a successful join), flipping the bar's button.
  defp push_viewer_snapshot(socket) do
    case CustomerFeed.snapshot(socket.assigns.session_uri, socket.assigns.token) do
      {:ok, snapshot} -> push(socket, "snapshot", encode_snapshot(snapshot, socket))
      _ -> :ok
    end
  end
end
