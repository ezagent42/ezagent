defmodule Ezagent.Socialware.ExternalFeedJoinProtocolTest do
  @moduledoc """
  P3-2 — the LOWER-BOUND cursor join protocol (codex P3 rev1 HIGH-3 + rev2
  HIGH-1) and its idempotent cursor replay, exercised at the `ExternalFeed`
  source layer (where the channel's join/advisory handlers delegate).

  Correctness invariant: a committed delivery may be re-delivered (harmless,
  idempotent by committed_seq) but is NEVER skipped — even when the advisory
  `{:external_delivery}` PubSub event is dropped and a commit lands in the
  narrow window BETWEEN the snapshot CONTENT read and the first replay.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{DeliveryOutbox, ExternalFeed, Settlement}
  alias EzagentCore.Repo

  # The external read is authorized by LIVE membership (the session owner/member),
  # not an identity-less token. The lower-bound cursor join/replay protocol is
  # auth-agnostic; only the AUTH carrier changed from a token to a principal.
  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "join-proto-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    owner =
      Ezagent.URI.entity(
        :team_alpha,
        :user,
        "join-proto-owner-#{System.unique_integer([:positive])}"
      )

    {:ok, _row} = Ezagent.Users.create(owner, "pw-not-secret", [])
    {:ok, _owner_pid} = Ezagent.SpawnRegistry.spawn(owner)

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    :ok = Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session, owner)
    %{session: session, workspace: workspace, caller: owner}
  end

  # Write a external-visible message, commit it via a settlement (so it appears
  # in the gated snapshot), AND emit a committed DeliveryOutbox row carrying its
  # id (so it becomes a cursor-addressable delivery the replay observes). The
  # committed_seq is assigned by `mark_committed_for_test` (the real commit
  # boundary), mirroring the direct-outbox pattern in
  # external_delivery_cursor_test.exs.
  defp commit_delivery(ctx, text, turn_id) do
    msg = Message.new(sender_uri(), %{text: text, attachments: []}, visibility: :external_visible)
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
      Repo.insert(%DeliveryOutbox{
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

      {:ok, result} = ExternalFeed.join(ctx.session, ctx.caller, [])

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
      # never send the {:external_delivery} event). The lower-bound replay must
      # still pick it up because `lower` was captured before the content read.
      injected = %{id: nil}
      pid = self()

      before_replay = fn ->
        written = commit_delivery(ctx, "raced-in", "turn-jp-race-2")
        send(pid, {:injected, written.id})
        :ok
      end

      {:ok, result} = ExternalFeed.join(ctx.session, ctx.caller, before_replay: before_replay)

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
      {:ok, join} = ExternalFeed.join(ctx.session, ctx.caller, [])
      assert join.cursor == 0

      # A delivery commits but the {:external_delivery} advisory is DROPPED
      # (we never notify). The stored cursor is still 0.
      late = commit_delivery(ctx, "wake-up-lost", "turn-jp-wakeup")

      # The next replay (triggered by ANY later advisory / reconnect) from the
      # stored cursor still delivers it.
      {:ok, replay} = ExternalFeed.replay(ctx.session, ctx.caller, join.cursor)
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

      {:ok, r1} = ExternalFeed.replay(ctx.session, ctx.caller, 0)
      assert r1.cursor == 1
      assert Enum.map(r1.deliveries, & &1.cursor) == [1]

      # Re-replaying from the advanced cursor returns NOTHING — the row is not
      # re-delivered.
      {:ok, r2} = ExternalFeed.replay(ctx.session, ctx.caller, r1.cursor)
      assert r2.deliveries == []
      assert r2.cursor == r1.cursor
    end

    test "cursor only advances to the max committed_seq actually replayed", ctx do
      _ = commit_delivery(ctx, "d1", "turn-jp-adv-1")
      _ = commit_delivery(ctx, "d2", "turn-jp-adv-2")

      {:ok, r} = ExternalFeed.replay(ctx.session, ctx.caller, 0)
      assert Enum.map(r.deliveries, & &1.cursor) == [1, 2]
      assert r.cursor == 2

      # From cursor 1: only the second is replayed, cursor advances to 2.
      {:ok, r2} = ExternalFeed.replay(ctx.session, ctx.caller, 1)
      assert Enum.map(r2.deliveries, & &1.cursor) == [2]
      assert r2.cursor == 2
    end

    test "an unauthorized caller fails the join closed", ctx do
      assert {:error, :unauthorized} = ExternalFeed.join(ctx.session, "bad-caller", [])
      assert {:error, :unauthorized} = ExternalFeed.replay(ctx.session, "bad-caller", 0)
    end

    test ">100-BATCH: a replay batch larger than the recency window renders EVERY delivered message; the cursor matches (codex P3-2 r2 HIGH-1)",
         ctx do
      # Commit more deliveries than the external snapshot's recency window (100),
      # so the latest-100 snapshot alone cannot render them all. The cursor must
      # NOT advance past a delivery the rendered snapshot omits.
      n = 105
      for i <- 1..n, do: commit_delivery(ctx, "batch-#{i}", "turn-jp-batch-#{i}")

      {:ok, r} = ExternalFeed.replay(ctx.session, ctx.caller, 0)

      assert r.cursor == n

      delivered_ids =
        r.deliveries |> Enum.flat_map(& &1.message_ids) |> MapSet.new()

      rendered_ids = MapSet.new(r.snapshot.messages, & &1.id)

      assert MapSet.subset?(delivered_ids, rendered_ids),
             "every replayed delivery message must be in the rendered snapshot — the " <>
               "cursor must not advance past a row omitted by the recency window"
    end

    test "FAIL-CLOSED: membership LOST BETWEEN the first snapshot read and the post-replay refresh denies — no stale push, no cursor advance (codex P3-2 r2 HIGH-2)",
         ctx do
      # Auth is now LIVE membership, re-checked on the post-replay refresh. The
      # seam fires AFTER the first (valid) snapshot read: commit a delivery (so the
      # replay is non-empty and the post-replay refresh runs) and DROP the live
      # session process so the refresh's `get_slice(:session)` fails closed (the
      # member can no longer be confirmed — the membership-auth analogue of a token
      # expiring between reads). The join must deny, NOT push a stale snapshot or
      # advance the cursor.
      before_replay = fn ->
        _ = commit_delivery(ctx, "raced-after-revoke", "turn-jp-revoke")
        {:ok, pid} = Ezagent.KindRegistry.lookup(ctx.session)

        :ok =
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.SessionSupervisor,
            pid
          )

        wait_until(fn -> Ezagent.KindRegistry.lookup(ctx.session) == :error end)
        :ok
      end

      assert {:error, :unauthorized} =
               ExternalFeed.join(ctx.session, ctx.caller, before_replay: before_replay)
    end

    test "JOIN with MORE than the recency window of pre-existing deliveries renders EVERY delivered message; the cursor covers only rendered rows (codex P3-2 r3 HIGH-1)",
         ctx do
      # A session that already has >100 committed external-visible deliveries at
      # join time: the recency-windowed snapshot alone renders only the latest
      # 100, so join must replay the FULL backlog (since 0) and augment the
      # snapshot — never checkpointing the cursor past an unrendered older row.
      n = 105
      for i <- 1..n, do: commit_delivery(ctx, "prejoin-#{i}", "turn-jp-prejoin-#{i}")

      {:ok, r} = ExternalFeed.join(ctx.session, ctx.caller, [])

      assert r.cursor == n

      delivered_ids = r.deliveries |> Enum.flat_map(& &1.message_ids) |> MapSet.new()
      rendered_ids = MapSet.new(r.snapshot.messages, & &1.id)

      assert MapSet.subset?(delivered_ids, rendered_ids),
             "join must render every pre-existing committed delivery — the cursor " <>
               "must not checkpoint past a row outside the recency window"
    end

    test "CROSS-SESSION: a message committed in session A is NOT in session B's external feed (session-scoped isolation)",
         ctx do
      # Post message-session-scoping (2026-06-21): a message belongs to exactly
      # ONE session, so cross-session isolation is STRUCTURAL — B simply has no
      # row for A's message. (Pre-collapse this guarded against B "borrowing" A's
      # commit via shared-id multi-routing, which can no longer be expressed.)
      session_b = session_uri()

      {:ok, _pid} =
        Ezagent.Socialware.TestCapHelper.spawn_session(%{
          uri: session_b,
          owner_uri: ctx.caller,
          behaviors: Ezagent.Entity.Session.socialware_behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_b, ctx.workspace)
      :ok = Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session_b, ctx.caller)

      msg =
        Message.new(sender_uri(), %{text: "shared", attachments: []},
          visibility: :external_visible
        )

      # The message belongs to session A only (a second write of the same id is a
      # no-op conflict — there is no multi-routing).
      {:ok, written} = MessageStore.write(msg, ctx.session)

      # Commit a settlement binding the message in session A.
      {:ok, _} =
        Settlement.begin(%{
          turn_id: "turn-xsess",
          session_uri: ctx.session,
          workspace_uri: ctx.workspace,
          target_message_ids: [written.id],
          target_surface_version: nil,
          expected_prior_approved: nil
        })

      {:ok, _} = Settlement.mark_committed_for_test("turn-xsess")

      a_ids = ctx.session |> MessageStore.committed_external_visible(100) |> Enum.map(& &1.id)
      b_ids = session_b |> MessageStore.committed_external_visible(100) |> Enum.map(& &1.id)

      assert written.id in a_ids, "session A (which owns + committed it) sees the message"
      refute written.id in b_ids, "session B has no row for A's message"

      # The by-id gate (used by the replay augment) is also session-scoped.
      b_byid =
        session_b
        |> MessageStore.committed_external_visible_by_ids([written.id])
        |> Enum.map(& &1.id)

      refute written.id in b_byid, "the by-id gate is bound to the session"

      # And B's external feed snapshot does not show it.
      {:ok, snap_b} = ExternalFeed.snapshot(session_b, ctx.caller)
      refute Enum.any?(snap_b.messages, &(&1.id == written.id))
    end
  end
end
