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
    test "a pre-join message is in the snapshot; the cursor starts at its inserted_at", ctx do
      at = ~U[2026-06-10 00:00:01.000000Z]
      _m1 = post(ctx.session, "first", at)

      {:ok, result} = ChatFeed.join(ctx.session, @owner, [])

      assert "first" in rendered_texts(result)
      assert result.cursor == at
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
      assert replay.cursor == late.inserted_at
      assert Enum.any?(replay.snapshot.page.children, &(&1.key == late.id))
    end

    test "IDEMPOTENT replay: re-replaying from a cursor that already covers a message is a no-op",
         ctx do
      m1 = post(ctx.session, "once", ~U[2026-06-10 00:00:01.000000Z])

      {:ok, r1} = ChatFeed.replay(ctx.session, @owner, ~U[1970-01-01 00:00:00.000000Z])
      assert r1.cursor == m1.inserted_at
      assert Enum.map(r1.messages, & &1.id) == [m1.id]

      {:ok, r2} = ChatFeed.replay(ctx.session, @owner, r1.cursor)
      assert r2.messages == []
      assert r2.cursor == r1.cursor
    end

    test "cursor only advances to the max inserted_at actually replayed", ctx do
      _ = post(ctx.session, "d1", ~U[2026-06-10 00:00:01.000000Z])
      m2 = post(ctx.session, "d2", ~U[2026-06-10 00:00:02.000000Z])

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ~U[1970-01-01 00:00:00.000000Z])
      assert Enum.map(r.messages, & &1.id) |> length() == 2
      assert r.cursor == m2.inserted_at
    end

    test "unauthorized caller fails the join closed (non-member denied)", ctx do
      stranger = Ezagent.URI.entity(:team_alpha, :user, "not-a-member")
      assert {:error, :unauthorized} = ChatFeed.join(ctx.session, stranger, [])

      assert {:error, :unauthorized} =
               ChatFeed.replay(ctx.session, stranger, ~U[1970-01-01 00:00:00.000000Z])
    end

    test ">recency-window batch: every replayed message is rendered; the cursor matches", ctx do
      t0 = ~U[2026-06-10 00:00:00.000000Z]
      n = ChatFeed.history_limit() + 5
      msgs = for i <- 1..n, do: post(ctx.session, "batch-#{i}", DateTime.add(t0, i, :second))

      {:ok, r} = ChatFeed.replay(ctx.session, @owner, ~U[1970-01-01 00:00:00.000000Z])

      last = List.last(msgs)
      assert r.cursor == last.inserted_at

      replayed_ids = MapSet.new(r.messages, & &1.id)
      rendered_ids = MapSet.new(r.snapshot.page.children, & &1.key)

      assert MapSet.subset?(replayed_ids, rendered_ids),
             "every replayed message must be in the rendered snapshot — the cursor must " <>
               "not advance past a message omitted by the recency window"
    end
  end
end
