defmodule Ezagent.MessageStore do
  @moduledoc """
  Persistent chat history per ARCHITECTURE §10.4 + Decision P2-D3.

  Single source of truth for Message stream — Session.Chat state only
  tracks ephemeral in-flight membership (members / online / last_seen /
  monitors); historical data lives here. On member rejoin,
  `in_session_since/2` derives the replay set; no duplicate pending
  queue is maintained (memory `feedback_converge_to_uri_list`).

  ## Phase 3 multi-session persist (#P1-4 fix)

  Phase 2 wrote `messages` table with `session_uri` column directly.
  Phase 3 D8 (reply to multiple sessions) needs same `message_id` to
  appear in multiple sessions, but `messages.id` is PK (Decision #40
  identity invariant). Resolution:

  - `messages` table: still 1 row per `message_id`. `session_uri`
    column kept (set on first write only) for Phase 2 backward compat;
    queries in Phase 3 use the join table instead.
  - `message_routings` table (new): one row per `(message_id, session_uri)`
    — the canonical per-session presence record.
  - `write/2` upserts messages (on_conflict: :nothing) + always inserts
    a fresh message_routings row.
  - `recent_in_session/2` + `in_session_since/2`: JOIN message_routings → messages.

  ## API surface

  - `write/2(message, session_uri)` — persist Message in a session
    context. Synchronous (Phase 2 messages are first-class; write
    failure means caller's send fails, no silent degrade per
    DECISIONS impl-time §write-failure). Idempotent on (message_id,
    session_uri) pair via upsert + unique index.
  - `in_session_since/2(session_uri, since)` — messages in this
    session strictly after `since`. Ascending order. Used by
    `Session.Chat.invoke(:join, ...)` on rejoin to replay. Bounded
    via SQL `LIMIT 1000` per DECISIONS P2-D3 failure mode (4)
  - `recent_in_session/2(session_uri, limit)` — N most recent
    messages, descending. LV /admin mount uses this to render history
  - `by_id/1(message_id)` — single Message lookup for `ref_id` chain
    following / debugging (renamed from `by_uri/1` in PR #149)

  All functions wrap `EzagentCore.Repo` calls. Custom Ecto.URI type
  handles URI struct ↔ string at column boundary.
  """

  import Ecto.Query
  alias Ezagent.Message
  alias Ezagent.Session.MessageSequence
  alias EzagentCore.Repo

  @replay_cap 1000

  @doc """
  Persist a Message in the given session context.

  Phase 3:
  - First-time write: insert `messages` row (with messages.session_uri
    set to this session) + insert `message_routings` row
  - Subsequent writes of same `message_id` to a different session:
    upsert messages = noop (PK conflict on `:nothing`) + add
    `message_routings` row (different session_uri makes composite PK
    unique)

  Returns `{:ok, message}` on success or `{:error, _}` on failure.
  """
  @spec write(Message.t(), URI.t()) :: {:ok, Message.t()} | {:error, term()}
  def write(%Message{} = msg, %URI{} = session_uri) do
    # Phase 9 PR-6 (SPEC v3 §7) — derive the workspace from the session
    # binding (invariant 4). `workspace_uri_for!/1` raises if the session
    # is unbound, which means a Template Class skipped
    # `WorkspaceRegistry.bind/2` after spawn — the proper fix is at the
    # spawn site, not a silent default here.
    workspace_uri_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    msg_with_session =
      msg
      |> Map.put(:session_uri, session_uri)
      |> Map.put(:workspace_uri, workspace_uri_str)

    # Message session-scoping (2026-06-21): one `messages` row per session (the
    # vestigial `message_routings` multi-routing was removed — cross-session
    # forwarding copies a NEW message into the target session, per the copy+ref
    # model). `routed_at` = the ROUTE-INTO-THIS-SESSION time, a FRESH timestamp at
    # write (NOT `msg.inserted_at`): the chat-feed snapshot orders on it so a
    # forwarded copy windows at its arrival here; `inserted_at` stays the CREATION
    # time for pagination + the external feed.
    msg_with_session = Map.put(msg_with_session, :routed_at, DateTime.utc_now())

    # Cursor allocation and message insertion are one durable transaction. The
    # counter row is updated before it is read; the database serializes
    # competing writers on that row, so two writes can never observe the same
    # position. Consumed gaps from idempotent duplicate IDs are harmless: the
    # replay contract is monotonic, not dense.
    Repo.transaction(fn ->
      with {:ok, session_seq} <- allocate_session_sequence(session_uri),
           msg_with_sequence <- Map.put(msg_with_session, :session_seq, session_seq),
           {:ok, _} <-
             Repo.insert(msg_with_sequence,
               on_conflict: :nothing,
               conflict_target: :id
             ) do
        case Repo.get(Message, msg.id) do
          %Message{} = persisted -> persisted
          nil -> Repo.rollback({:persisted_row_missing, msg.id})
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Message{} = persisted} -> {:ok, persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the latest durable message position for a session."
  @spec current_session_sequence(URI.t()) :: non_neg_integer()
  def current_session_sequence(%URI{} = session_uri) do
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(s in MessageSequence,
      where: s.session_uri == ^session_uri and s.workspace_uri == ^workspace_uri,
      select: s.last_seq
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Messages strictly after a durable per-session sequence, in send order."
  @spec in_session_after_sequence(URI.t(), non_neg_integer()) :: [Message.t()]
  def in_session_after_sequence(%URI{} = session_uri, sequence)
      when is_integer(sequence) and sequence >= 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.session_seq > ^sequence and
          m.workspace_uri == ^workspace_str,
      order_by: [asc: m.session_seq],
      limit: @replay_cap
    )
    |> Repo.all()
  end

  defp allocate_session_sequence(session_uri) do
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    case Repo.insert(
           %MessageSequence{
             session_uri: session_uri,
             workspace_uri: workspace_uri,
             last_seq: 0
           },
           on_conflict: :nothing,
           conflict_target: :session_uri
         ) do
      {:ok, _} ->
        {1, _} =
          from(s in MessageSequence,
            where: s.session_uri == ^session_uri and s.workspace_uri == ^workspace_uri
          )
          |> Repo.update_all(inc: [last_seq: 1])

        {:ok, current_session_sequence(session_uri)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Messages in `session_uri` strictly after `since` (timestamp comparison).
  Ascending order. Used for rejoin replay.

  JOINs message_routings → messages. Bounded to `@replay_cap` rows.

  Phase 9 PR-6 — adds explicit `workspace_uri` filter derived from the
  session's binding (invariant 4). Defense in depth: the existing
  `session_uri` filter already partitions, but this filter pins the
  workspace dimension so an accidental session-uri collision across
  workspaces can never leak.
  """
  @spec in_session_since(URI.t(), DateTime.t()) :: [Message.t()]
  def in_session_since(%URI{} = session_uri, %DateTime{} = since) do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.inserted_at > ^since and
          m.workspace_uri == ^workspace_str,
      order_by: [asc: m.inserted_at],
      limit: @replay_cap
    )
    |> Repo.all()
  end

  @doc """
  N most-recent messages in `session_uri`, descending.

  JOINs message_routings → messages. Returns at most `limit`.

  Phase 9 PR-6 — adds explicit `workspace_uri` filter (see
  `in_session_since/2` moduledoc).
  """
  @spec recent_in_session(URI.t(), pos_integer()) :: [Message.t()]
  def recent_in_session(%URI{} = session_uri, limit) when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where: m.session_uri == ^session_str and m.workspace_uri == ^workspace_str,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  N most-recent external-visible messages in `session_uri`, descending.

  This is the fail-closed read for callers that do not hold the socialware
  management `:read_unfiltered` cap.
  """
  @spec recent_visible_in_session(URI.t(), pos_integer()) :: [Message.t()]
  def recent_visible_in_session(%URI{} = session_uri, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :external_visible,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Messages in `session_uri` strictly older than `cursor` (inserted_at).

  Descending order (newest of the older-than-cursor batch first), bounded
  by `limit`. Phase 5 PR 5: backs the LV "↑ Load older" button — caller
  passes the current oldest-visible inserted_at as cursor and `Enum.reverse`s
  the result to prepend ascending into the stream.

  Per Spec 5 P5-D8: cursor is `inserted_at` (not `id`); `id` isn't
  guaranteed monotonic across nodes.
  """
  @spec older_than(URI.t(), DateTime.t(), pos_integer()) :: [Message.t()]
  def older_than(%URI{} = session_uri, %DateTime{} = cursor, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.inserted_at < ^cursor and
          m.workspace_uri == ^workspace_str,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  External-visible messages in `session_uri` strictly older than `cursor`.

  Descending order, bounded by `limit`. This is the paginated companion to
  `recent_visible_in_session/2` for non-`read_unfiltered` callers.
  """
  @spec older_visible_than(URI.t(), DateTime.t(), pos_integer()) :: [Message.t()]
  def older_visible_than(%URI{} = session_uri, %DateTime{} = cursor, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.inserted_at < ^cursor and
          m.workspace_uri == ^workspace_str and m.visibility == :external_visible,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  External-visible messages whose owning socialware turn has committed.

  This is the route-level external-read query primitive for socialware. It
  intentionally does not make raw feeds external-safe; operator/admin
  reads continue to use the full internal feeds.
  """
  @spec committed_external_visible(URI.t(), pos_integer()) :: [Message.t()]
  def committed_external_visible(%URI{} = session_uri, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: sm in "socialware_settlement_messages",
      on: sm.message_id == m.id,
      join: s in "socialware_settlements",
      on: s.turn_id == sm.turn_id,
      where:
        m.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :external_visible and s.status == "committed" and
          s.session_uri == ^session_str and s.workspace_uri == ^workspace_str,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  External-visible, committed messages restricted to a fixed id set (within the
  session). Same gating as `committed_external_visible/2` (external_visible +
  committed settlement + session/workspace match) but selected by id rather than
  windowed by recency — so a caller replaying committed deliveries can render the
  delivered messages even when they fall outside the latest-N recency window
  (P3-2: keeps the external feed's render-cursor consistent with the delivery
  cursor). Returns `[]` for an empty id list.
  """
  @spec committed_external_visible_by_ids(URI.t(), [String.t()]) :: [Message.t()]
  def committed_external_visible_by_ids(%URI{} = _session_uri, []), do: []

  def committed_external_visible_by_ids(%URI{} = session_uri, ids) when is_list(ids) do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: sm in "socialware_settlement_messages",
      on: sm.message_id == m.id,
      join: s in "socialware_settlements",
      on: s.turn_id == sm.turn_id,
      where:
        m.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :external_visible and s.status == "committed" and
          s.session_uri == ^session_str and s.workspace_uri == ^workspace_str and
          m.id in ^ids,
      order_by: [desc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  P4-2 — the N most-recent `:external_visible` messages in `session_uri`,
  ASCENDING (oldest→newest). The CHAT external-SPA snapshot window: chat has NO
  settlement model, so unlike `committed_external_visible/2` there is no
  settlement join — the gate is per-message `visibility == :external_visible`
  (an `:internal` chat message never leaks to the external read) plus
  session + workspace scoping (defense-in-depth, mirroring the other chat
  queries).

  Queried descending+`limit` (so the latest N are kept) then reversed to
  ascending — the same shape the LV "load older" path uses — so the chat_feed
  projection renders oldest→newest. Ordered by `routed_at` (with `message_id` as
  a deterministic tie-break) so a cross-session-relayed message windows at its
  route-into-session position.

  ## `routed_at`, not `inserted_at`

  This windowed snapshot read is the ONLY chat-feed read path — there is no
  delta cursor (the external feed needs one; chat does not — see
  `Ezagent.Socialware.ChatFeed`). It orders on `message_routings.routed_at` —
  the per-session ROUTE-INTO-THIS-SESSION time — NOT `inserted_at` (the message
  CREATION time): the cross-session relay path routes the SAME `%Message{}` with
  its original, OLD `inserted_at`, so ordering on `routed_at` windows the relayed
  message at the position it actually entered THIS session. (Without a cursor to
  strand on, any `routed_at` tie is now harmless — a tie only reorders within the
  snapshot, never drops a row.) `inserted_at` is left for the production
  pagination + external feed.
  """
  @spec chat_visible_recent(URI.t(), pos_integer()) :: [Message.t()]
  def chat_visible_recent(%URI{} = session_uri, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      where:
        m.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :external_visible,
      order_by: [desc: m.routed_at, desc: m.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Idempotently set visibility for a fixed message-id set.
  """
  @spec mark_visibility([String.t()], :external_visible | :internal) ::
          {:ok, non_neg_integer()}
  def mark_visibility(message_ids, visibility)
      when is_list(message_ids) and visibility in [:external_visible, :internal] do
    {count, _} =
      from(m in Message, where: m.id in ^message_ids)
      |> Repo.update_all(set: [visibility: visibility])

    {:ok, count}
  end

  @doc """
  Relabel one identity's message references inside a single session.

  This is the sanctioned anon→login mutation path after message session-scoping:
  only rows owned by `session_uri` are considered, and both `sender` and
  `mentions` are rewritten from `from_uri` to `to_uri`. Authorization belongs to
  the merge orchestrator; this function is only the scoped storage primitive.
  """
  @spec relabel_identity(URI.t(), URI.t(), URI.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def relabel_identity(%URI{} = session_uri, %URI{} = from_uri, %URI{} = to_uri) do
    from_str = URI.to_string(from_uri)

    if from_str == URI.to_string(to_uri) do
      {:ok, 0}
    else
      session_str = URI.to_string(session_uri)
      workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

      Repo.transaction(fn ->
        from(m in Message,
          where: m.session_uri == ^session_str and m.workspace_uri == ^workspace_str
        )
        |> Repo.all()
        |> Enum.reduce(0, fn %Message{} = message, count ->
          case relabel_attrs(message, from_str, to_uri) do
            [] ->
              count

            attrs ->
              message
              |> Ecto.Changeset.change(attrs)
              |> Repo.update!()

              count + 1
          end
        end)
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp relabel_attrs(%Message{} = message, from_str, %URI{} = to_uri) do
    []
    |> maybe_relabel_sender(message, from_str, to_uri)
    |> maybe_relabel_mentions(message, from_str, to_uri)
  end

  defp maybe_relabel_sender(attrs, %Message{} = message, from_str, %URI{} = to_uri) do
    if uri_string(message.sender) == from_str do
      Keyword.put(attrs, :sender, to_uri)
    else
      attrs
    end
  end

  defp maybe_relabel_mentions(attrs, %Message{} = message, from_str, %URI{} = to_uri) do
    mentions = message.mentions || []

    relabelled =
      Enum.map(mentions, fn mention ->
        if uri_string(mention) == from_str, do: to_uri, else: mention
      end)

    if Enum.map(relabelled, &uri_string/1) == Enum.map(mentions, &uri_string/1) do
      attrs
    else
      Keyword.put(attrs, :mentions, relabelled)
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri

  @doc """
  Single Message lookup by id. Returns `{:ok, message}` or `:error`.

  Used for `ref_id` chain following — if `msg.ref_id == "<id>"` and
  a consumer wants the original referenced message, this is the lookup.
  Returns the message with its **first-written** session_uri (Phase 2
  semantics) — for Phase 3 multi-session presence, query
  `message_routings` directly.

  PR #149 (SPEC v2 §5.13): renamed from `by_uri/1`. Message ids are
  plain UUID strings, not URIs.
  """
  @spec by_id(String.t()) :: {:ok, Message.t()} | :error
  def by_id(message_id) when is_binary(message_id) do
    case Repo.get(Message, message_id) do
      nil -> :error
      %Message{} = m -> {:ok, m}
    end
  end

  @doc """
  The session URI(s) this message belongs to.

  Post message-session-scoping (2026-06-21): a message belongs to exactly ONE
  session, so this returns a 0- or 1-element list of the session-URI string
  (preserving the prior `[String.t()]` contract for callers like the uploads
  download-auth flow). Cross-session forwarding creates a NEW message in the
  target session, so there is never more than one.
  """
  @spec sessions_for_message(String.t()) :: [String.t()]
  def sessions_for_message(message_id) when is_binary(message_id) do
    case Repo.get(Message, message_id) do
      %Message{session_uri: %URI{} = s} -> [URI.to_string(s)]
      %Message{session_uri: s} when is_binary(s) -> [s]
      _ -> []
    end
  end
end
