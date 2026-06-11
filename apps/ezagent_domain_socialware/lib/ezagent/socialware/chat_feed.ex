defmodule Ezagent.Socialware.ChatFeed do
  @moduledoc """
  P4 — a CHAT session's external SPA view, served over the SAME `:pull`
  adapter + Phoenix-channel + json-render SPA machinery P3-2 built for the
  socialware customer feed (`CustomerFeed`), but projecting the **chat message
  slice** over the **chat message ordering** (`inserted_at`) instead of the
  socialware committed-delivery cursor (chat has NO settlement model).

  This proves the substrate's "ANY session → external SPA" generalization: P3
  built the adapter + surface for socialware; P4 reuses it for chat with NO
  chat-specific surface code. The internal chat operator LiveView
  (`ConversationView`) is UNCHANGED — this is purely an additive external read.

  ## What is the SAME as `CustomerFeed` (reused)

    * the `:pull` adapter shape (`ChatFeedAdapter` — a bare-module `render/2` +
      cap-only `.Allow`, mirroring `CustomerFeedAdapter`);
    * the json-render output shape (`%{type: "container", ...}` — `chat_tree/1`
      mirrors `Surface.customer_tree` over chat messages);
    * the lower-bound cursor JOIN protocol (`join/3` captures `lower` BEFORE the
      content read, renders the snapshot, then replays from `lower`, so a commit
      landing in the join window — even with its advisory dropped — is never
      skipped; replay is idempotent so a row may be re-rendered but never lost);
    * the SPA (`customer_app.js` / `json_render.mjs`) + Channel framework.

  ## What is DIFFERENT (the only P4-specific code)

    * the cursor is the chat message ordering — `inserted_at` (per Spec 5 P5-D8,
      `id` is NOT monotonic so the chat cursor is `inserted_at`). The replay
      primitive is `MessageStore.chat_visible_since/2`, mirroring
      `committed_deliveries_since/2` but over `inserted_at`;
    * the read authority is **chat membership** (a chat session has no
      "customer" / settlement token): the SAME live, fail-closed owner/member
      predicate P3-3 specified, extracted into the shared
      `Ezagent.Socialware.ChatMembership` so the chat_feed authz and
      `SocialwarePublisherRead` stay byte-equivalent on the security boundary;
    * per-message visibility — only `:customer_visible` messages are projected
      (an `:operator_only` chat message is dropped from the external read).
  """

  alias Ezagent.MessageStore
  alias Ezagent.Socialware.ChatMembership
  alias Ezagent.URI, as: EzURI

  @history_limit 200

  # The chat cursor is `inserted_at` (a DateTime). The lower bound for a session
  # with NO messages is the epoch — strictly older than any real message, so the
  # first replay covers the full backlog (mirrors CustomerFeed's integer 0).
  @epoch ~U[1970-01-01 00:00:00.000000Z]

  # ----- P4-1: the PURE chat → customer_tree projection ----------------------

  @doc """
  Project a list of chat `%Message{}`s into the json-render `customer_tree`
  shape the customer SPA renders: a `stack` container whose children are one
  `text` node per `:customer_visible` message (in input order). `:operator_only`
  messages are filtered out (per-message visibility — they never leak to the
  external read). Pure + deterministic.
  """
  @spec chat_tree([Ezagent.Message.t()]) :: map()
  def chat_tree(messages) when is_list(messages) do
    children =
      messages
      |> Enum.filter(&customer_visible?/1)
      |> Enum.map(&text_node/1)

    %{type: "container", props: %{layout: "stack"}, children: children}
  end

  defp customer_visible?(%{visibility: :operator_only}), do: false
  defp customer_visible?(_message), do: true

  defp text_node(message) do
    %{type: "text", key: message.id, props: %{text: message_text(message)}}
  end

  defp message_text(%{body: body}) when is_map(body) do
    Map.get(body, "text") || Map.get(body, :text) || ""
  end

  defp message_text(_message), do: ""

  @doc "Snapshot recency-window size (most-recent N customer-visible messages)."
  @spec history_limit() :: pos_integer()
  def history_limit, do: @history_limit

  # ----- P4-2: the lower-bound cursor join protocol (over inserted_at) -------

  @doc "PubSub topic for the chat-feed advisory wake-up (per session)."
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:chat_feed:" <> URI.to_string(session_uri)

  @doc """
  The gated chat snapshot for `caller` (an owner/member of `session_uri`'s live
  `:chat` slice). Returns `{:ok, %{messages, page}}` where `messages` is the
  recency window of `:customer_visible` chat messages (ascending) and `page` is
  the `chat_tree/1` json-render projection of them. `{:error, :unauthorized}`
  fail-closed on a non-member / nil / malformed caller (the LIVE chat membership
  check — the SAME predicate as P3-3, via `ChatMembership`).
  """
  @spec snapshot(URI.t(), URI.t() | term()) ::
          {:ok, %{messages: [Ezagent.Message.t()], page: map()}} | {:error, :unauthorized}
  def snapshot(%URI{} = session_uri, caller) do
    with :ok <- authorize(session_uri, caller) do
      messages = MessageStore.chat_visible_recent(session_uri, @history_limit)
      {:ok, %{messages: messages, page: chat_tree(messages)}}
    end
  end

  @doc """
  The highest `inserted_at` among `session_uri`'s `:customer_visible` chat
  messages (the chat-cursor analogue of `CustomerFeed.latest_cursor/1`).
  Returns `@epoch` when the session has no visible messages, so the first replay
  covers the full backlog.
  """
  @spec latest_cursor(URI.t()) :: DateTime.t()
  def latest_cursor(%URI{} = session_uri) do
    case MessageStore.chat_visible_recent(session_uri, 1) do
      [%{inserted_at: %DateTime{} = at}] -> at
      _ -> @epoch
    end
  end

  @doc """
  P4-2 — the LOWER-BOUND cursor JOIN protocol (P3-2's, over the chat
  `inserted_at` cursor). The CALLER's channel subscribes to the chat-feed
  advisory topic FIRST; this function then:

    1. authorizes + reads the gated snapshot;
    2. (test seam) `opts[:before_replay]` fires AFTER the content read and
       BEFORE the replay — used to inject a message + drop its advisory in the
       exact join-race window;
    3. replays `chat_visible_since(@epoch)` (the FULL backlog) and re-renders so
       the snapshot includes EVERY replayed message, then advances the cursor to
       the max replayed `inserted_at`.

  Replaying from `@epoch` (not from `latest_cursor`) means the recency-windowed
  snapshot can never strand older messages: the cursor only ever checkpoints a
  message the snapshot actually renders (no skip), and a message landing in the
  join window — even with its advisory dropped — is re-included (never lost).

  Returns `{:ok, %{snapshot: %{messages, page}, messages: [...], cursor:
  DateTime}}` (`cursor` = max replayed `inserted_at`, or the snapshot's max when
  the replay is empty). `{:error, :unauthorized}` fail-closed.
  """
  @spec join(URI.t(), URI.t() | term(), keyword()) ::
          {:ok, %{snapshot: map(), messages: [Ezagent.Message.t()], cursor: DateTime.t()}}
          | {:error, :unauthorized}
  def join(%URI{} = session_uri, caller, opts \\ []) when is_list(opts) do
    case snapshot(session_uri, caller) do
      {:ok, snapshot0} ->
        run_before_replay(opts[:before_replay])
        messages = MessageStore.chat_visible_since(session_uri, @epoch)
        replayed_result(session_uri, caller, snapshot0, messages)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  P4-2 — cursor replay for an ESTABLISHED connection, triggered by every
  advisory (or a reconnect). Re-authorizes (fail-closed LIVE re-check — an
  ex-member who LEFT is denied here), replays `chat_visible_since(cursor)`, and
  returns the refreshed snapshot. The cursor advances ONLY to the max replayed
  `inserted_at` (unchanged when the replay is empty — idempotent).
  """
  @spec replay(URI.t(), URI.t() | term(), DateTime.t()) ::
          {:ok, %{snapshot: map(), messages: [Ezagent.Message.t()], cursor: DateTime.t()}}
          | {:error, :unauthorized}
  def replay(%URI{} = session_uri, caller, %DateTime{} = cursor) do
    case snapshot(session_uri, caller) do
      {:ok, snapshot0} ->
        messages = MessageStore.chat_visible_since(session_uri, cursor)
        replayed_result(session_uri, caller, snapshot0, messages, cursor)

      {:error, _} = err ->
        err
    end
  end

  # Empty replay: nothing strictly-after the cursor — return the already-read
  # snapshot, cursor unchanged (idempotent).
  defp replayed_result(_session_uri, _caller, snapshot0, [], base_cursor) do
    {:ok, %{snapshot: snapshot0, messages: [], cursor: base_cursor}}
  end

  # Non-empty replay (with an explicit base cursor — the `replay/3` path).
  defp replayed_result(session_uri, caller, snapshot0, messages, _base_cursor) do
    finalize_replay(session_uri, caller, snapshot0, messages)
  end

  # The `join/3` path: the base cursor is the snapshot's max (or @epoch when the
  # backlog is empty), so the cursor never sits below a rendered message.
  defp replayed_result(_session_uri, _caller, snapshot0, []) do
    {:ok, %{snapshot: snapshot0, messages: [], cursor: snapshot_max(snapshot0)}}
  end

  defp replayed_result(session_uri, caller, snapshot0, messages) do
    finalize_replay(session_uri, caller, snapshot0, messages)
  end

  # Re-render so the snapshot includes EVERY replayed message (even ones outside
  # the recency window), RE-AUTHORIZING (fail-closed: an ex-member who left
  # between the first read and now is denied — no stale push, no cursor advance),
  # THEN advance the cursor to the max replayed inserted_at.
  defp finalize_replay(session_uri, caller, _snapshot0, messages) do
    case snapshot(session_uri, caller) do
      {:ok, %{messages: base}} ->
        merged = merge_messages(base, messages)

        {:ok,
         %{
           snapshot: %{messages: merged, page: chat_tree(merged)},
           messages: messages,
           cursor: max_inserted_at(messages)
         }}

      {:error, _} = err ->
        err
    end
  end

  # Union base (recency window) + replayed messages, dedup by id, ascending by
  # inserted_at. So the rendered snapshot reflects every message the cursor will
  # account for — even a >recency-window backlog the latest-N window omitted.
  defp merge_messages(base, replayed) do
    (base ++ replayed)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp max_inserted_at(messages) do
    messages |> Enum.map(& &1.inserted_at) |> Enum.max(DateTime)
  end

  defp snapshot_max(%{messages: []}), do: @epoch
  defp snapshot_max(%{messages: messages}), do: max_inserted_at(messages)

  defp run_before_replay(nil), do: :ok
  defp run_before_replay(fun) when is_function(fun, 0), do: fun.()

  # ----- P4-3: the LIVE, fail-closed chat membership authorization -----------
  #
  # Read the session's LIVE `:chat` slice and delegate to the SHARED
  # ChatMembership predicate (the SAME one SocialwarePublisherRead uses — P4
  # extracted it so the two read paths stay byte-equivalent on the security
  # boundary). A non-member / nil / malformed / crafted caller is denied; an
  # ex-member (post-LEAVE) is denied because the slice is re-read live on every
  # call; a missing/unreadable slice fails closed.
  defp authorize(session_uri, caller) do
    ChatMembership.authorize(chat_slice(session_uri), caller)
  end

  defp chat_slice(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, slice} -> slice
      _ -> nil
    end
  end

  @doc false
  def workspace(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, workspace_str} -> {:ok, EzURI.new!(workspace_str)}
      {:error, _} -> {:error, :unbound_session}
    end
  end
end
