defmodule Ezagent.Socialware.CustomerFeedJoinProtocolTest do
  @moduledoc """
  P3-2 — the LOWER-BOUND cursor join protocol (codex P3 rev1 HIGH-3 + rev2
  HIGH-1) and its idempotent cursor replay, exercised at the `CustomerFeed`
  source layer (where the channel's join/advisory handlers delegate).

  Correctness invariant: a committed delivery may be re-delivered (harmless,
  idempotent by committed_seq) but is NEVER skipped — even when the advisory
  `{:customer_delivery}` PubSub event is dropped and a commit lands in the
  narrow window BETWEEN the snapshot CONTENT read and the first replay.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed, CustomerOutbox, Settlement}
  alias EzagentCore.Repo

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "join-proto-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)
    %{session: session, workspace: workspace, token: token}
  end

  # Write a customer-visible message, commit it via a settlement (so it appears
  # in the gated snapshot), AND emit a committed CustomerOutbox row carrying its
  # id (so it becomes a cursor-addressable delivery the replay observes). The
  # committed_seq is assigned by `mark_committed_for_test` (the real commit
  # boundary), mirroring the direct-outbox pattern in
  # customer_delivery_cursor_test.exs.
  defp commit_delivery(ctx, text, turn_id) do
    msg = Message.new(sender_uri(), %{text: text, attachments: []}, visibility: :customer_visible)
    {:ok, written} = MessageStore.write(msg, ctx.session)

    {:ok, _} =
      Settlement.begin(%{
        turn_id: turn_id,
        session_uri: ctx.session,
        workspace_uri: ctx.workspace,
        target_message_ids: [written.id],
        target_surface_version: nil,
        expected_prior_approved: nil
      })

    {:ok, _} =
      Repo.insert(%CustomerOutbox{
        turn_id: turn_id,
        session_uri: URI.to_string(ctx.session),
        workspace_uri: URI.to_string(ctx.workspace),
        message_ids: [written.id],
        surface_version: nil,
        committed_seq: nil,
        emitted_at: DateTime.utc_now()
      })

    {:ok, _} = Settlement.mark_committed_for_test(turn_id)
    written
  end

  defp delivery_message_ids(%{deliveries: deliveries}) do
    deliveries |> Enum.flat_map(& &1.message_ids) |> MapSet.new()
  end

  describe "lower-bound cursor join protocol" do
    test "join captures lower; a pre-join delivery is in the snapshot and the cursor starts at lower",
         ctx do
      m1 = commit_delivery(ctx, "first", "turn-jp-1")

      {:ok, result} = CustomerFeed.join(ctx.session, ctx.token, [])

      # A delivery committed BEFORE join is rendered via the snapshot content;
      # the lower-bound cursor starts at its committed_seq so subsequent replays
      # begin strictly after it (no duplicate of an already-rendered row).
      assert Enum.any?(result.snapshot.messages, &(&1.id == m1.id))
      assert result.cursor == 1
    end

    test "JOIN-RACE: a commit injected BETWEEN content read and first replay, with the advisory DROPPED, is STILL rendered (not lost)",
         ctx do
      # A delivery already present at join.
      _m1 = commit_delivery(ctx, "before-join", "turn-jp-race-1")

      # The seam: this fires AFTER the snapshot content read and BEFORE the
      # first replay. We inject a NEW commit here and DROP its advisory (we
      # never send the {:customer_delivery} event). The lower-bound replay must
      # still pick it up because `lower` was captured before the content read.
      injected = %{id: nil}
      pid = self()

      before_replay = fn ->
        written = commit_delivery(ctx, "raced-in", "turn-jp-race-2")
        send(pid, {:injected, written.id})
        :ok
      end

      {:ok, result} = CustomerFeed.join(ctx.session, ctx.token, before_replay: before_replay)

      injected_id =
        receive do
          {:injected, id} -> id
        after
          1000 -> flunk("seam never fired")
        end

      _ = injected

      # The raced-in delivery — whose advisory was DROPPED — is STILL in the
      # replay because lower (0) < its committed_seq. NEVER skipped.
      assert injected_id in delivery_message_ids(result),
             "lower-bound replay must re-include a commit that landed between the " <>
               "content read and the first replay even with the advisory dropped"

      # codex P3-2 HIGH: the channel RENDERS result.snapshot, not result.deliveries.
      # So the raced-in row must be in the SNAPSHOT the caller pushes — otherwise
      # the cursor advances past a row that was never rendered (stale forever).
      assert Enum.any?(result.snapshot.messages, &(&1.id == injected_id)),
             "the rendered snapshot must reflect the raced-in delivery — the cursor " <>
               "must not advance past a row the snapshot does not show"
    end

    test "WAKE-UP-LOSS: dropping the advisory does not lose a delivery — the next replay from the stored cursor catches it",
         ctx do
      {:ok, join} = CustomerFeed.join(ctx.session, ctx.token, [])
      assert join.cursor == 0

      # A delivery commits but the {:customer_delivery} advisory is DROPPED
      # (we never notify). The stored cursor is still 0.
      late = commit_delivery(ctx, "wake-up-lost", "turn-jp-wakeup")

      # The next replay (triggered by ANY later advisory / reconnect) from the
      # stored cursor still delivers it.
      {:ok, replay} = CustomerFeed.replay(ctx.session, ctx.token, join.cursor)
      assert late.id in delivery_message_ids(replay)
      assert replay.cursor == 1

      # codex P3-2 HIGH: the rendered snapshot (what the channel pushes) must
      # reflect the late delivery too — not just the deliveries list.
      assert Enum.any?(replay.snapshot.messages, &(&1.id == late.id)),
             "the replay snapshot must reflect the late (advisory-lost) delivery"
    end

    test "IDEMPOTENT replay: re-replaying from a cursor that already covers a delivery is a no-op (no double-delivery)",
         ctx do
      _m1 = commit_delivery(ctx, "once", "turn-jp-idem")

      {:ok, r1} = CustomerFeed.replay(ctx.session, ctx.token, 0)
      assert r1.cursor == 1
      assert Enum.map(r1.deliveries, & &1.cursor) == [1]

      # Re-replaying from the advanced cursor returns NOTHING — the row is not
      # re-delivered.
      {:ok, r2} = CustomerFeed.replay(ctx.session, ctx.token, r1.cursor)
      assert r2.deliveries == []
      assert r2.cursor == r1.cursor
    end

    test "cursor only advances to the max committed_seq actually replayed", ctx do
      _ = commit_delivery(ctx, "d1", "turn-jp-adv-1")
      _ = commit_delivery(ctx, "d2", "turn-jp-adv-2")

      {:ok, r} = CustomerFeed.replay(ctx.session, ctx.token, 0)
      assert Enum.map(r.deliveries, & &1.cursor) == [1, 2]
      assert r.cursor == 2

      # From cursor 1: only the second is replayed, cursor advances to 2.
      {:ok, r2} = CustomerFeed.replay(ctx.session, ctx.token, 1)
      assert Enum.map(r2.deliveries, & &1.cursor) == [2]
      assert r2.cursor == 2
    end

    test "unauthorized token fails the join closed", ctx do
      assert {:error, :unauthorized} = CustomerFeed.join(ctx.session, "bad-token", [])
      assert {:error, :unauthorized} = CustomerFeed.replay(ctx.session, "bad-token", 0)
    end

    test ">100-BATCH: a replay batch larger than the recency window renders EVERY delivered message; the cursor matches (codex P3-2 r2 HIGH-1)",
         ctx do
      # Commit more deliveries than the customer snapshot's recency window (100),
      # so the latest-100 snapshot alone cannot render them all. The cursor must
      # NOT advance past a delivery the rendered snapshot omits.
      n = 105
      for i <- 1..n, do: commit_delivery(ctx, "batch-#{i}", "turn-jp-batch-#{i}")

      {:ok, r} = CustomerFeed.replay(ctx.session, ctx.token, 0)

      assert r.cursor == n

      delivered_ids =
        r.deliveries |> Enum.flat_map(& &1.message_ids) |> MapSet.new()

      rendered_ids = MapSet.new(r.snapshot.messages, & &1.id)

      assert MapSet.subset?(delivered_ids, rendered_ids),
             "every replayed delivery message must be in the rendered snapshot — the " <>
               "cursor must not advance past a row omitted by the recency window"
    end

    test "FAIL-CLOSED: a token expiring BETWEEN the first snapshot read and the post-replay refresh denies — no stale push, no cursor advance (codex P3-2 r2 HIGH-2)",
         ctx do
      short_token =
        CustomerAuth.issue_token(ctx.session, ctx.workspace, expires_in_ms: 50)

      # The seam fires AFTER the first (valid) snapshot read: commit a delivery
      # (so the replay is non-empty and the post-replay refresh runs) and let the
      # short-TTL token EXPIRE before that refresh re-authorizes.
      before_replay = fn ->
        _ = commit_delivery(ctx, "raced-after-expiry", "turn-jp-expiry")
        Process.sleep(120)
        :ok
      end

      assert {:error, :unauthorized} =
               CustomerFeed.join(ctx.session, short_token, before_replay: before_replay)
    end
  end

  describe "adapter render/2 routes the customer projection" do
    test "render returns the SAME gated snapshot content the channel pushes", ctx do
      m1 = commit_delivery(ctx, "rendered", "turn-jp-render")

      rendered =
        Ezagent.ExternalMirror.Adapter.render(
          Ezagent.Socialware.CustomerFeedAdapter,
          ctx.session,
          %{token: ctx.token}
        )

      assert Enum.any?(rendered.messages, &(&1.id == m1.id))
      assert Map.has_key?(rendered, :page)
    end

    test "render with an unauthorized token returns the empty/denied projection", ctx do
      rendered =
        Ezagent.ExternalMirror.Adapter.render(
          Ezagent.Socialware.CustomerFeedAdapter,
          ctx.session,
          %{token: "bad-token"}
        )

      assert rendered == %{messages: [], page: nil}
    end
  end
end
