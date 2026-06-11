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
  alias Ezagent.{Message, MessageRouting}
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

    now = msg.inserted_at || DateTime.utc_now()

    # Two-step write: messages (upsert) + message_routings (insert).
    # Wrapped in a transaction so we don't end up with messages row
    # but missing routing, or vice versa.
    Repo.transaction(fn ->
      case Repo.insert(msg_with_session, on_conflict: :nothing, conflict_target: :id) do
        {:ok, _} ->
          routing = %MessageRouting{
            message_id: msg.id,
            session_uri: URI.to_string(session_uri),
            inserted_at: now
          }

          case Repo.insert(routing,
                 on_conflict: :nothing,
                 conflict_target: [:message_id, :session_uri]
               ) do
            {:ok, _} ->
              # PR-EM-6-PRE codex r2 HIGH (2026-05-25) — return the
              # ACTUALLY-PERSISTED row, not the caller-built struct.
              # With `on_conflict: :nothing, conflict_target: :id`,
              # `Repo.insert/2` returns `{:ok, _}` even when an earlier
              # row with the same id already existed; the returned
              # struct in that case is the caller's input, NOT the
              # persisted row. Downstream consumers (PR-EM-6-PRE
              # external mirror via SliceChange.new_slice.last_message)
              # depend on this being the row in `messages`, otherwise
              # a misbehaving client that reuses an id with a different
              # body could cause mirrors to publish content that never
              # made it to durable storage.
              #
              # Re-fetch by id inside the same transaction so we hand
              # back the authoritative row. The row MUST exist at this
              # point (we just :ok-ed either an insert or a conflict on
              # the same id), so `nil` here is a let-it-crash bug, not
              # a normal control-flow signal.
              case Repo.get(Message, msg.id) do
                %Message{} = persisted -> persisted
                nil -> Repo.rollback({:persisted_row_missing, msg.id})
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
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
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where:
        r.session_uri == ^session_str and r.inserted_at > ^since and
          m.workspace_uri == ^workspace_str,
      order_by: [asc: r.inserted_at],
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
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where: r.session_uri == ^session_str and m.workspace_uri == ^workspace_str,
      order_by: [desc: r.inserted_at],
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
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where:
        r.session_uri == ^session_str and r.inserted_at < ^cursor and
          m.workspace_uri == ^workspace_str,
      order_by: [desc: r.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Customer-visible messages whose owning socialware turn has committed.

  This is the route-level customer query primitive for socialware. It
  intentionally does not make raw feeds customer-safe; operator/admin
  reads continue to use the full internal feeds.
  """
  @spec committed_customer_visible(URI.t(), pos_integer()) :: [Message.t()]
  def committed_customer_visible(%URI{} = session_uri, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: r in MessageRouting,
      on: r.message_id == m.id,
      join: sm in "socialware_settlement_messages",
      on: sm.message_id == m.id,
      join: s in "socialware_settlements",
      on: s.turn_id == sm.turn_id,
      where:
        r.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :customer_visible and s.status == "committed" and
          s.session_uri == ^session_str and s.workspace_uri == ^workspace_str,
      order_by: [desc: r.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Customer-visible, committed messages restricted to a fixed id set (within the
  session). Same gating as `committed_customer_visible/2` (customer_visible +
  committed settlement + session/workspace match) but selected by id rather than
  windowed by recency — so a caller replaying committed deliveries can render the
  delivered messages even when they fall outside the latest-N recency window
  (P3-2: keeps the customer feed's render-cursor consistent with the delivery
  cursor). Returns `[]` for an empty id list.
  """
  @spec committed_customer_visible_by_ids(URI.t(), [String.t()]) :: [Message.t()]
  def committed_customer_visible_by_ids(%URI{} = _session_uri, []), do: []

  def committed_customer_visible_by_ids(%URI{} = session_uri, ids) when is_list(ids) do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: r in MessageRouting,
      on: r.message_id == m.id,
      join: sm in "socialware_settlement_messages",
      on: sm.message_id == m.id,
      join: s in "socialware_settlements",
      on: s.turn_id == sm.turn_id,
      where:
        r.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :customer_visible and s.status == "committed" and
          s.session_uri == ^session_str and s.workspace_uri == ^workspace_str and
          m.id in ^ids,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  P4-2 — the N most-recent `:customer_visible` messages in `session_uri`,
  ASCENDING (oldest→newest). The CHAT external-SPA snapshot window: chat has NO
  settlement model, so unlike `committed_customer_visible/2` there is no
  settlement join — the gate is per-message `visibility == :customer_visible`
  (an `:operator_only` chat message never leaks to the external read) plus
  session + workspace scoping (defense-in-depth, mirroring the other chat
  queries).

  Queried descending+`limit` (so the latest N are kept) then reversed to
  ascending — the same shape the LV "load older" path uses — so the chat_feed
  projection renders oldest→newest. Ordered by the composite
  `{inserted_at, message_id}` keyset (P4 codex finding 2) so tied timestamps get
  a deterministic total order that matches `chat_visible_since/2`'s cursor.
  """
  @spec chat_visible_recent(URI.t(), pos_integer()) :: [Message.t()]
  def chat_visible_recent(%URI{} = session_uri, limit)
      when is_integer(limit) and limit > 0 do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where:
        r.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :customer_visible,
      order_by: [desc: r.inserted_at, desc: r.message_id],
      limit: ^limit,
      # Surface the ROUTING timestamp so the chat-feed cursor checkpoints on the
      # SAME column this query orders on (P4 codex r2 HIGH).
      select_merge: %{routed_at: r.inserted_at}
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  P4-2 — `:customer_visible` messages in `session_uri` strictly after the
  **composite `{inserted_at, message_id}` keyset cursor** (ascending). The CHAT
  external-SPA REPLAY primitive, mirroring `committed_deliveries_since/2` but
  over the chat message ordering.

  ## Why a composite keyset (P4 codex finding 2 — HIGH)

  `inserted_at` alone is NOT a total order: two messages can share an
  `inserted_at` (millisecond/microsecond collisions, batch writes). With the old
  `inserted_at > ^since`, once the chat-feed cursor reached a tied timestamp the
  later tied row was excluded FOREVER (and the `@replay_cap` bound could lose
  rows when >cap share a timestamp). The composite cursor `{ts, id}` restores a
  total order:

      inserted_at > ts  OR  (inserted_at == ts AND message_id > id)

  ordered by `[asc: inserted_at, asc: message_id]`. `MessageRouting`'s PK is
  `(message_id, session_uri)` so `message_id` is the deterministic tie-break.
  The epoch lower bound is `{~U[1970-01-01 ...], ""}` (`""` sorts before any
  UUID, so the full backlog is covered). Per-message visibility gate +
  session/workspace scoping as `chat_visible_recent/2`. Bounded to `@replay_cap`.
  """
  @spec chat_visible_since(URI.t(), {DateTime.t(), String.t()}) :: [Message.t()]
  def chat_visible_since(%URI{} = session_uri, {%DateTime{} = since_at, since_id})
      when is_binary(since_id) do
    session_str = URI.to_string(session_uri)
    workspace_str = Ezagent.Persistence.workspace_uri_for!(session_uri)

    from(m in Message,
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where:
        r.session_uri == ^session_str and m.workspace_uri == ^workspace_str and
          m.visibility == :customer_visible and
          (r.inserted_at > ^since_at or
             (r.inserted_at == ^since_at and r.message_id > ^since_id)),
      order_by: [asc: r.inserted_at, asc: r.message_id],
      limit: @replay_cap,
      # Cursor checkpoints on the ROUTING timestamp, not messages.inserted_at
      # (P4 codex r2 HIGH).
      select_merge: %{routed_at: r.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  Idempotently set visibility for a fixed message-id set.
  """
  @spec mark_visibility([String.t()], :customer_visible | :operator_only) ::
          {:ok, non_neg_integer()}
  def mark_visibility(message_ids, visibility)
      when is_list(message_ids) and visibility in [:customer_visible, :operator_only] do
    {count, _} =
      from(m in Message, where: m.id in ^message_ids)
      |> Repo.update_all(set: [visibility: visibility])

    {:ok, count}
  end

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
  List all session URIs this message has been routed into.

  Phase 3 multi-session helper — for D8 ref/session_uris consistency
  check in `Ezagent.Behavior.Chat.handle_kind_message/3`.
  """
  @spec sessions_for_message(String.t()) :: [String.t()]
  def sessions_for_message(message_id) when is_binary(message_id) do
    from(r in MessageRouting,
      where: r.message_id == ^message_id,
      select: r.session_uri
    )
    |> Repo.all()
  end
end
