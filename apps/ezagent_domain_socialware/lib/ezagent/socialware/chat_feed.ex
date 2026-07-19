defmodule Ezagent.Socialware.ChatFeed do
  @moduledoc """
  P4 — a CHAT session's external SPA view, served over the SAME `:pull`
  adapter + Phoenix-channel + json-render SPA machinery P3-2 built for the
  socialware customer feed (`ExternalFeed`), but projecting the **chat message
  slice** with a **windowed snapshot-refresh** read model.

  ## Why snapshot-refresh (NOT a delta cursor)

  The customer feed genuinely needs a durable, replayable, exactly-once DELTA
  cursor — its settlement/outbox model requires it. **Chat does NOT.** A chat
  live view just needs to show the latest N messages and refresh on any change,
  exactly how LiveView and ordinary chat UIs work. P4 therefore drops the
  lower-bound `{routed_at, message_id}` keyset cursor (and its replay/drain/merge
  machinery) entirely in favour of re-reading the current latest-N snapshot on
  every advisory. This DELETES a whole class of fragility (tie-break → routed_at
  → clock skew → NULL stranding) that the cursor introduced.

  ## The read model — windowed snapshot-refresh

    * **join**: the channel subscribes to the canonical chat event topic FIRST,
      THEN calls `snapshot/2` (authorize → read latest-N → render) and pushes.
      NO cursor is stored.
    * **advisory** (any event on that topic): call `snapshot/2` again — re-read
      the CURRENT latest-N state and push. NO cursor, NO replay, NO drain.
    * **reconnect**: the channel re-joins → re-reads the current snapshot.

  Correctness (no miss): subscribe-FIRST means any message arriving after the
  subscribe triggers an advisory whose re-read shows current state; a message
  present at join is already in the snapshot. A dropped advisory is
  self-healing — the next advisory re-reads current state. The live view is
  ALWAYS the current latest-N; older history is a separate paging concern (out
  of scope here).

  ## What is the SAME as `ExternalFeed` (reused)

    * the `:pull` adapter shape (`ChatFeedAdapter` — a bare-module `render/2` +
      cap-only `.Allow`, mirroring the retired customer-feed adapter);
    * the json-render output shape (`%{type: "container", ...}` — `chat_tree/1`
      mirrors `Surface.external_tree` over chat messages);
    * the SPA (`viewer_app.js` / `catalog_render.mjs`) + Channel framework.

  ## What is DIFFERENT (the only P4-specific code)

    * the snapshot is the chat recency window (`MessageStore.chat_visible_recent/2`
      — routed through the `SessionReads` chokepoint's `:chat_feed` view,
      ordered by `routed_at` so a cross-session-relayed message windows at its
      route-into-session position) — there is NO delta cursor;
    * the read authority is **chat membership** (a chat session has no
      "customer" / settlement token): the SAME live, fail-closed owner/member
      predicate P3-3 specified — now enforced INSIDE the `SessionReads`
      chokepoint (which delegates to the shared `Ezagent.Session.Membership`),
      so the chat_feed authz and `SocialwarePublisherRead` stay byte-equivalent
      on the security boundary;
    * per-message visibility — only `:external_visible` messages are projected
      (an `:internal` chat message is dropped from the external read).
  """

  alias Ezagent.Socialware.SessionReads

  @history_limit 200

  # ----- P4-1: the PURE chat → external_tree projection ----------------------

  @doc """
  Project a list of chat `%Message{}`s into the json-render `external_tree`
  shape the customer SPA renders: a `stack` container whose children are one
  `text` node per `:external_visible` message (in input order). `:internal`
  messages are filtered out (per-message visibility — they never leak to the
  external read). Pure + deterministic.
  """
  @spec chat_tree([Ezagent.Message.t()]) :: map()
  def chat_tree(messages) when is_list(messages) do
    children =
      messages
      |> Enum.filter(&external_visible?/1)
      |> Enum.map(&text_node/1)

    %{type: "container", props: %{layout: "stack"}, children: children}
  end

  defp external_visible?(%{visibility: :internal}), do: false
  defp external_visible?(_message), do: true

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

  # ----- P4-2: the windowed snapshot-refresh read ----------------------------

  @doc "PubSub topic for the chat-feed advisory wake-up (per session)."
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:chat_feed:" <> URI.to_string(session_uri)

  @doc """
  The gated chat snapshot for `caller` (an owner/member of `session_uri`'s live
  `:chat` slice). Returns `{:ok, %{messages, page}}` where `messages` is the
  recency window of `:external_visible` chat messages (ascending) and `page` is
  the `chat_tree/1` json-render projection of them. `{:error, :unauthorized}`
  fail-closed on a non-member / nil / malformed caller (the LIVE chat membership
  check — the SAME predicate as P3-3, via `ChatMembership`).

  This is the ONLY read path. The channel calls it on join AND on every advisory
  (re-authorizing each time so an ex-member who left is denied live), each call
  returning the CURRENT latest-N state. There is no cursor — a dropped advisory
  is self-healing because the next call re-reads current state.
  """
  @spec snapshot(URI.t(), URI.t() | term()) ::
          {:ok, %{messages: [Ezagent.Message.t()], page: map()}} | {:error, :unauthorized}
  def snapshot(%URI{} = session_uri, caller) do
    # The read routes through the SessionReads chokepoint (:chat_feed view):
    # authorized FIRST (the SAME live, fail-closed owner/member predicate —
    # A2.3/R1.1, an ex-member is denied even with a stale roster entry), only
    # then the store read. Byte-identical output for an authorized caller.
    with {:ok, messages} <-
           SessionReads.messages(caller, session_uri, :chat_feed, %{limit: @history_limit}) do
      {:ok, %{messages: messages, page: chat_tree(messages)}}
    end
  end
end
