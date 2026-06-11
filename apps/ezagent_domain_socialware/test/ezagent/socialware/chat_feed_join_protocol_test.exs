defmodule Ezagent.Socialware.ChatFeedJoinProtocolTest do
  @moduledoc """
  P4-2 — the lower-bound cursor JOIN protocol + idempotent replay for the
  chat_feed `:pull` adapter, exercised at the `ChatFeed` source layer (where the
  channel's join/advisory handlers delegate). This mirrors
  `CustomerFeedJoinProtocolTest` but over the **chat `routed_at` cursor**
  (the per-session ROUTE time — P4 codex r4 HIGH — NOT `messages.inserted_at`;
  chat has no settlement model) instead of the committed-delivery cursor.

  Correctness invariant (same as P3-2): a chat message may be re-rendered
  (harmless, idempotent — the projection keys text nodes by message id) but is
  NEVER skipped — even when the advisory PubSub event is dropped and a message
  lands in the narrow window BETWEEN the snapshot CONTENT read and the first
  replay. The join cursor never checkpoints past a message the snapshot omits.

  Authorization is the LIVE chat membership predicate (P4-3): the caller is an
  owner/member of the live `:chat` slice. The session is a real chat `Session`
  Kind so `Ezagent.Kind.get_slice(session, :chat)` reflects join/leave live.

  ## Controlling order

  The chat cursor is `routed_at` (a FRESH `now` captured per
  `MessageStore.write/2`), so these tests control ordering by WRITE ORDER —
  sequential `post/2` calls give strictly-increasing route timestamps, exactly
  how a real feed orders. Cursors are read off the protocol's own results (which
  surface `routed_at`), NOT crafted from `inserted_at`. Forced TIED-`routed_at`
  coverage inserts the `message_routings` rows DIRECTLY with a shared
  `routed_at`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageRouting, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.ChatFeed
  alias EzagentCore.Repo

  @owner Ezagent.URI.entity(:team_alpha, :user, "chat-owner")
  @sender Ezagent.URI.entity(:team_alpha, :agent, "chat-bot")

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "chatfeed-#{System.unique_integer([:positive])}")
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session, owner_uri: @owner})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace}
  end

  # Write a customer-visible chat message. routed_at is captured fresh at write,
  # so sequential posts are strictly ordered — the deterministic cursor driver
  # (NOT msg.inserted_at).
  defp post(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :customer_visible)

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  # The {routed_at, id} cursor keyset for a message id, read off a chat query
  # (which surfaces routed_at). write/2's return value has no routed_at.
  defp keyset_of(session, id) do
    row = session |> MessageStore.chat_visible_recent(1000) |> Enum.find(&(&1.id == id))
    {row.routed_at, row.id}
  end

  # Force a TIED routed_at by inserting message + routing rows DIRECTLY.
  defp insert_tied(session, workspace, text, routed_at) do
    id = "tied-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"

    {:ok, m} =
      Repo.insert(%Message{
        id: id,
        sender: @sender,
        body: %{"text" => text, "attachments" => []},
        visibility: :customer_visible,
        session_uri: session,
        workspace_uri: URI.to_string(workspace),
        inserted_at: DateTime.utc_now()
      })

    {:ok, _} =
      Repo.insert(%MessageRouting{
        message_id: m.id,
        session_uri: URI.to_string(session),
        inserted_at: m.inserted_at,
        routed_at: routed_at
      })

    m.id
  end

  defp rendered_texts(%{snapshot: %{page: page}}) do
    page.children |> Enum.map(& &1.props.text)
  end

  describe "lower-bound cursor join protocol (over the chat routed_at cursor)" do
    test "a pre-join message is in the snapshot; the cursor starts at its {routed_at, id}",
         ctx do
      m1 = post(ctx.session, "first")

      {:ok, result} = ChatFeed.join(ctx.session, @owner, [])

      assert "first" in rendered_texts(result)
      assert result.cursor == keyset_of(ctx.session, m1.id)
    end

    test "JOIN-RACE: a message posted BETWEEN content read and first replay, advisory DROPPED, is STILL rendered",
         ctx do
      _before = post(ctx.session, "before-join")
      pid = self()

      before_replay = fn ->
        raced = post(ctx.session, "raced-in")
        send(pid, {:raced, raced.id})
        :ok
      end

      {:ok, result} = ChatFeed.join(ctx.session, @owner, before_replay: before_replay)

      raced_id =
        receive do
          {:raced, id} -> id
        after
          1000 -> flunk("seam never fired")
        end

      # The raced-in message — whose advisory was DROPPED — is STILL rendered in
      # the snapshot the caller pushes, because lower was captured before the
      # content read and the replay re-includes it. NEVER skipped.
      assert "raced-in" in rendered_texts(result),
             "lower-bound replay must re-include a message that landed in the join window"

      assert Enum.any?(result.snapshot.page.children, &(&1.key == raced_id))
    end

    test "WAKE-UP-LOSS: dropping the advisory does not lose a message — next replay catches it",
         ctx do
      {:ok, join} = ChatFeed.join(ctx.session, @owner, [])

      late = post(ctx.session, "wake-up-lost")

      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, join.cursor)
      assert "wake-up-lost" in rendered_texts(replay)
      assert replay.cursor == keyset_of(ctx.session, late.id)
      assert Enum.any?(replay.snapshot.page.children, &(&1.key == late.id))
    end

    test "IDEMPOTENT replay: re-replaying from a cursor that already covers a message is a no-op",
         ctx do
      m1 = post(ctx.session, "once")

      {:ok, r1} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())
      assert r1.cursor == keyset_of(ctx.session, m1.id)
      assert Enum.map(r1.messages, & &1.id) == [m1.id]

      {:ok, r2} = ChatFeed.replay(ctx.session, @owner, r1.cursor)
      assert r2.messages == []
      assert r2.cursor == r1.cursor
    end

    test "cursor only advances to the {routed_at, id} keyset of the last replayed row", ctx do
      _ = post(ctx.session, "d1")
      m2 = post(ctx.session, "d2")

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())
      assert Enum.map(r.messages, & &1.id) |> length() == 2
      assert r.cursor == keyset_of(ctx.session, m2.id)
    end

    test "unauthorized caller fails the join closed (non-member denied)", ctx do
      stranger = Ezagent.URI.entity(:team_alpha, :user, "not-a-member")
      assert {:error, :unauthorized} = ChatFeed.join(ctx.session, stranger, [])

      assert {:error, :unauthorized} =
               ChatFeed.replay(ctx.session, stranger, ChatFeed.epoch_cursor())
    end

    test ">recency-window batch: every replayed message is rendered; the cursor matches", ctx do
      n = ChatFeed.history_limit() + 5
      msgs = for i <- 1..n, do: post(ctx.session, "batch-#{i}")

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())

      last = List.last(msgs)
      assert r.cursor == keyset_of(ctx.session, last.id)

      replayed_ids = MapSet.new(r.messages, & &1.id)
      rendered_ids = MapSet.new(r.snapshot.page.children, & &1.key)

      assert MapSet.subset?(replayed_ids, rendered_ids),
             "every replayed message must be in the rendered snapshot — the cursor must " <>
               "not advance past a message omitted by the recency window"
    end
  end

  describe "cross-session relay regression (P4 codex r4 HIGH — relayed message not stranded)" do
    test "a message relayed into THIS session AFTER the cursor advanced is DELIVERED, not stranded",
         ctx do
      # 1. Establish session B (= ctx.session) with its own message and advance
      #    B's chat-feed cursor PAST `now` by joining/replaying.
      _b_native = post(ctx.session, "native-in-B")
      {:ok, join} = ChatFeed.join(ctx.session, @owner, [])
      cursor_after_join = join.cursor

      # 2. Build a message CREATED EARLIER in another session A (OLD inserted_at).
      #    This is the %Message{} the cross-session relay routes — same id, OLD
      #    inserted_at, UNMUTATED.
      old_inserted_at = ~U[2026-01-01 00:00:00.000000Z]

      relayed =
        Message.new(@sender, %{text: "relayed-from-A", attachments: []},
          visibility: :customer_visible,
          inserted_at: old_inserted_at
        )

      session_a =
        Ezagent.URI.session(:team_alpha, :default, "src-#{System.unique_integer([:positive])}")

      :ok = Ezagent.WorkspaceRegistry.bind(session_a, ctx.workspace)
      {:ok, _} = MessageStore.write(relayed, session_a)

      # 3. Route the SAME %Message{} (same id, OLD inserted_at) into session B via
      #    the realistic write path — exactly what handle_send/MessageStore.write
      #    does on the relay. routed_at is captured fresh (≈ now), AFTER the
      #    cursor advanced.
      {:ok, _} = MessageStore.write(relayed, ctx.session)

      # 4. ASSERT: B's routing row for the relayed id has routed_at ≈ now (NOT the
      #    OLD inserted_at).
      relayed_row =
        ctx.session
        |> MessageStore.chat_visible_recent(1000)
        |> Enum.find(&(&1.id == relayed.id))

      assert relayed_row, "the relayed message must be present in session B's chat feed"
      assert relayed_row.inserted_at == old_inserted_at, "message creation time is unchanged"

      assert DateTime.compare(relayed_row.routed_at, old_inserted_at) == :gt,
             "routed_at must be the fresh route-into-B time, NOT the old creation time"

      {at_after_join, _id_after_join} = cursor_after_join

      assert DateTime.compare(relayed_row.routed_at, at_after_join) in [:gt, :eq],
             "the relayed message's route time must sort AT/AFTER B's advanced cursor"

      # 5. THE REGRESSION: replaying from B's PRIOR cursor (advanced past `now`
      #    before the relay) DELIVERS the relayed message — it is NOT stranded
      #    behind the cursor (the old inserted_at-keyed cursor would have placed
      #    it at the OLD creation time, far behind the cursor, dropping it
      #    forever until a full reconnect/epoch join).
      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, cursor_after_join)

      assert relayed.id in Enum.map(replay.messages, & &1.id),
             "the relayed message MUST be delivered by replay from the prior cursor — " <>
               "this is the codex r4 stranding regression"

      assert "relayed-from-A" in rendered_texts(replay)
    end
  end

  describe "composite {routed_at, message_id} cursor (P4 codex finding 2 — no tied-row skip)" do
    test "TIED routed_at: BOTH messages delivered across join+replay; neither skipped", ctx do
      # Force a shared routed_at via direct routing inserts (sequential post/2
      # can never tie).
      at = ~U[2026-06-10 00:00:05.000000Z]
      id_a = insert_tied(ctx.session, ctx.workspace, "tied-a", at)
      id_b = insert_tied(ctx.session, ctx.workspace, "tied-b", at)
      [lo, hi] = Enum.sort([id_a, id_b])

      # Join checkpoints to the HIGHER-id tied row (the keyset max), so both are
      # rendered and the cursor sits exactly on the last-rendered tuple.
      {:ok, join} = ChatFeed.join(ctx.session, @owner, [])
      join_ids = MapSet.new(join.snapshot.page.children, & &1.key)
      assert MapSet.member?(join_ids, lo)
      assert MapSet.member?(join_ids, hi)
      assert join.cursor == {at, hi}

      # A replay sitting on the LOWER-id tied row must still surface the higher
      # tied sibling — the old routed_at-only `> ts` predicate would have
      # excluded it forever once the cursor reached that timestamp.
      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, {at, lo})
      assert Enum.map(replay.messages, & &1.id) == [hi]
      assert replay.cursor == {at, hi}
    end

    test "cap-boundary: >replay_cap rows SHARING one routed_at lose nothing across replays",
         ctx do
      at = ~U[2026-06-10 00:00:05.000000Z]
      # @replay_cap is 1000 in MessageStore; exceed it with rows that ALL share
      # the same routed_at, so the ONLY total-order discriminator is message_id.
      n = 1005
      ids = for i <- 1..n, do: insert_tied(ctx.session, ctx.workspace, "same-ts-#{i}", at)
      all = MapSet.new(ids)

      # Drain the full set across capped replays starting from the epoch. Each
      # replay advances the cursor to its last-rendered keyset; the composite
      # cursor guarantees the next replay resumes strictly after it (no row tied
      # at the cap boundary is dropped).
      collected = drain_all(ctx.session, ChatFeed.epoch_cursor(), MapSet.new())

      assert MapSet.equal?(collected, all),
             "every tied-timestamp row must be delivered across capped replays — " <>
               "missing: #{inspect(MapSet.difference(all, collected) |> MapSet.to_list())}"
    end

    @tag timeout: 120_000
    test "JOIN drains the FULL backlog beyond a single replay cap — no middle-stranding (codex P4 r3 HIGH)",
         ctx do
      cap = MessageStore.chat_replay_cap()
      window = ChatFeed.history_limit()
      # > cap + window: with the old single-replay join (oldest cap-batch +
      # newest window) the MIDDLE range was rendered by neither and the cursor
      # advanced past it. Include a tied-`routed_at` cluster around the cap
      # boundary so the drain's keyset batch-boundary is exercised under ties.
      total = cap + window + 5
      base = ~U[2026-01-01 00:00:00.000000Z]

      posted =
        for i <- 1..total do
          routed_at =
            if i in (cap - 4)..(cap + 5),
              do: DateTime.add(base, cap, :microsecond),
              else: DateTime.add(base, i, :microsecond)

          id = insert_tied(ctx.session, ctx.workspace, "m#{i}", routed_at)
          %{id: id}
        end

      {:ok, result} = ChatFeed.join(ctx.session, @owner, [])

      rendered = MapSet.new(result.snapshot.messages, & &1.id)
      posted_ids = MapSet.new(posted, & &1.id)

      assert MapSet.subset?(posted_ids, rendered),
             "join must render the COMPLETE backlog (drained in cap-sized batches), " <>
               "not just oldest-cap + newest-window — missing: " <>
               "#{inspect(MapSet.difference(posted_ids, rendered) |> MapSet.to_list() |> Enum.take(5))}"

      # The cursor checkpointed the true max keyset, so a replay from it is a no-op.
      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, result.cursor)
      assert replay.messages == []
    end
  end

  # Repeatedly replay from `cursor`, accumulating delivered ids, until a replay
  # returns no new messages. Proves the composite cursor never strands a row even
  # when >replay_cap rows share one routed_at.
  defp drain_all(session, cursor, acc) do
    {:ok, r} = ChatFeed.replay(session, @owner, cursor)

    case r.messages do
      [] ->
        acc

      msgs ->
        acc2 = Enum.reduce(msgs, acc, fn m, a -> MapSet.put(a, m.id) end)
        drain_all(session, r.cursor, acc2)
    end
  end
end
