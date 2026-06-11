defmodule Ezagent.Socialware.ChatFeedJoinProtocolTest do
  @moduledoc """
  P4-2 — the lower-bound cursor JOIN protocol + idempotent replay for the
  chat_feed `:pull` adapter, exercised at the `ChatFeed` source layer (where the
  channel's join/advisory handlers delegate). This mirrors
  `CustomerFeedJoinProtocolTest` but over the **chat `inserted_at` cursor**
  (chat has no settlement model) instead of the committed-delivery cursor.

  Correctness invariant (same as P3-2): a chat message may be re-rendered
  (harmless, idempotent — the projection keys text nodes by message id) but is
  NEVER skipped — even when the advisory PubSub event is dropped and a message
  lands in the narrow window BETWEEN the snapshot CONTENT read and the first
  replay. The join cursor never checkpoints past a message the snapshot omits.

  Authorization is the LIVE chat membership predicate (P4-3): the caller is an
  owner/member of the live `:chat` slice. The session is a real chat `Session`
  Kind so `Ezagent.Kind.get_slice(session, :chat)` reflects join/leave live.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.ChatFeed

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

  # Write a customer-visible chat message at a controlled inserted_at (monotonic
  # so the cursor ordering is deterministic across the test).
  defp post(session, text, at) do
    msg =
      Message.new(@sender, %{text: text, attachments: []},
        visibility: :customer_visible,
        inserted_at: at
      )

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  defp rendered_texts(%{snapshot: %{page: page}}) do
    page.children |> Enum.map(& &1.props.text)
  end

  describe "lower-bound cursor join protocol (over the chat inserted_at cursor)" do
    test "a pre-join message is in the snapshot; the cursor starts at its {inserted_at, id}",
         ctx do
      at = ~U[2026-06-10 00:00:01.000000Z]
      m1 = post(ctx.session, "first", at)

      {:ok, result} = ChatFeed.join(ctx.session, @owner, [])

      assert "first" in rendered_texts(result)
      assert result.cursor == {at, m1.id}
    end

    test "JOIN-RACE: a message posted BETWEEN content read and first replay, advisory DROPPED, is STILL rendered",
         ctx do
      _before = post(ctx.session, "before-join", ~U[2026-06-10 00:00:01.000000Z])
      pid = self()

      before_replay = fn ->
        raced = post(ctx.session, "raced-in", ~U[2026-06-10 00:00:05.000000Z])
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

      late = post(ctx.session, "wake-up-lost", ~U[2026-06-10 00:00:10.000000Z])

      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, join.cursor)
      assert "wake-up-lost" in rendered_texts(replay)
      assert replay.cursor == {late.inserted_at, late.id}
      assert Enum.any?(replay.snapshot.page.children, &(&1.key == late.id))
    end

    test "IDEMPOTENT replay: re-replaying from a cursor that already covers a message is a no-op",
         ctx do
      m1 = post(ctx.session, "once", ~U[2026-06-10 00:00:01.000000Z])

      {:ok, r1} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())
      assert r1.cursor == {m1.inserted_at, m1.id}
      assert Enum.map(r1.messages, & &1.id) == [m1.id]

      {:ok, r2} = ChatFeed.replay(ctx.session, @owner, r1.cursor)
      assert r2.messages == []
      assert r2.cursor == r1.cursor
    end

    test "cursor only advances to the {inserted_at, id} keyset of the last replayed row", ctx do
      _ = post(ctx.session, "d1", ~U[2026-06-10 00:00:01.000000Z])
      m2 = post(ctx.session, "d2", ~U[2026-06-10 00:00:02.000000Z])

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())
      assert Enum.map(r.messages, & &1.id) |> length() == 2
      assert r.cursor == {m2.inserted_at, m2.id}
    end

    test "unauthorized caller fails the join closed (non-member denied)", ctx do
      stranger = Ezagent.URI.entity(:team_alpha, :user, "not-a-member")
      assert {:error, :unauthorized} = ChatFeed.join(ctx.session, stranger, [])

      assert {:error, :unauthorized} =
               ChatFeed.replay(ctx.session, stranger, ChatFeed.epoch_cursor())
    end

    test ">recency-window batch: every replayed message is rendered; the cursor matches", ctx do
      t0 = ~U[2026-06-10 00:00:00.000000Z]
      n = ChatFeed.history_limit() + 5
      msgs = for i <- 1..n, do: post(ctx.session, "batch-#{i}", DateTime.add(t0, i, :second))

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ChatFeed.epoch_cursor())

      last = List.last(msgs)
      assert r.cursor == {last.inserted_at, last.id}

      replayed_ids = MapSet.new(r.messages, & &1.id)
      rendered_ids = MapSet.new(r.snapshot.page.children, & &1.key)

      assert MapSet.subset?(replayed_ids, rendered_ids),
             "every replayed message must be in the rendered snapshot — the cursor must " <>
               "not advance past a message omitted by the recency window"
    end
  end

  describe "composite {inserted_at, message_id} cursor (P4 codex finding 2 — no tied-row skip)" do
    test "TIED inserted_at: BOTH messages delivered across join+replay; neither skipped", ctx do
      at = ~U[2026-06-10 00:00:05.000000Z]
      a = post(ctx.session, "tied-a", at)
      b = post(ctx.session, "tied-b", at)
      [lo, hi] = Enum.sort_by([a, b], & &1.id)

      # Join checkpoints to the HIGHER-id tied row (the keyset max), so both are
      # rendered and the cursor sits exactly on the last-rendered tuple.
      {:ok, join} = ChatFeed.join(ctx.session, @owner, [])
      join_ids = MapSet.new(join.snapshot.page.children, & &1.key)
      assert MapSet.member?(join_ids, lo.id)
      assert MapSet.member?(join_ids, hi.id)
      assert join.cursor == {at, hi.id}

      # A replay sitting on the LOWER-id tied row must still surface the higher
      # tied sibling — the old inserted_at-only `> ts` predicate would have
      # excluded it forever once the cursor reached that timestamp.
      {:ok, replay} = ChatFeed.replay(ctx.session, @owner, {at, lo.id})
      assert Enum.map(replay.messages, & &1.id) == [hi.id]
      assert replay.cursor == {at, hi.id}
    end

    test "cap-boundary: >replay_cap rows SHARING one inserted_at lose nothing across replays",
         ctx do
      at = ~U[2026-06-10 00:00:05.000000Z]
      # @replay_cap is 1000 in MessageStore; exceed it with rows that ALL share
      # the same inserted_at, so the ONLY total-order discriminator is message_id.
      n = 1005
      ids = for i <- 1..n, do: post(ctx.session, "same-ts-#{i}", at).id |> then(& &1)
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
  end

  # Repeatedly replay from `cursor`, accumulating delivered ids, until a replay
  # returns no new messages. Proves the composite cursor never strands a row even
  # when >replay_cap rows share one inserted_at.
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
