defmodule Ezagent.EventLogTest do
  @moduledoc """
  Phase 1B SPEC §5.1 — `Ezagent.EventLog` synchronous append + replay
  stream API.

  Tests cover:

  1. `append/4` returns `{:ok, event_id}` with the assigned id
  2. `stream_by_aggregate/2` returns events for one Kind instance
  3. `stream_by_workspace/2` returns events scoped to one workspace
  4. `(inserted_at, id)` ordering tie-breaker for same-microsecond writes
  5. Workspace scoping isolates rows across workspaces
  6. `:since` opt filters strictly after timestamp
  7. `:limit` opt caps the result size
  8. `:order` opt flips both axes of the composite ordering
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.EventLog
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  @aggregate_a "entity://team-alpha/agent/test_event-log-a"
  @aggregate_b "entity://team-alpha/agent/test_event-log-b"
  @workspace_x "workspace://team-alpha"
  @workspace_y "workspace://team-beta"
  @caller "entity://system/user/admin"

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
    # `Ezagent.Audit.Writer` is skipped in :test env (see
    # EzagentCore.Application.skip_in_test_env?/1), so its async flush
    # won't pollute this test's view of the `invocations` table.
    :ok
  end

  describe "append/4" do
    test "returns {:ok, event_id} and the id is a positive integer" do
      assert {:ok, event_id} =
               EventLog.append(@aggregate_a, :message_sent, %{body: "hello"}, %{
                 caller: @caller,
                 workspace_uri: @workspace_x
               })

      assert is_integer(event_id) and event_id > 0
    end

    test "successive appends produce strictly increasing event_ids" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}

      {:ok, id1} = EventLog.append(@aggregate_a, :first, %{}, ctx)
      {:ok, id2} = EventLog.append(@aggregate_a, :second, %{}, ctx)
      {:ok, id3} = EventLog.append(@aggregate_a, :third, %{}, ctx)

      assert id2 > id1
      assert id3 > id2
    end

    test "raises ArgumentError when ctx is missing :workspace_uri" do
      # invocations.workspace_uri is NOT NULL (Phase 9 PR-6). The append
      # contract enforces this at the boundary, not at the SQL constraint.
      assert_raise ArgumentError, ~r/:workspace_uri/, fn ->
        EventLog.append(@aggregate_a, :no_ws, %{}, %{caller: @caller})
      end
    end
  end

  describe "stream_by_aggregate/2" do
    test "returns only events for the requested aggregate, ascending by default" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}

      {:ok, _} = EventLog.append(@aggregate_a, :event_a1, %{n: 1}, ctx)
      {:ok, _} = EventLog.append(@aggregate_b, :event_b1, %{n: 99}, ctx)
      {:ok, _} = EventLog.append(@aggregate_a, :event_a2, %{n: 2}, ctx)

      events_a = EventLog.stream_by_aggregate(@aggregate_a)

      assert length(events_a) == 2
      assert Enum.map(events_a, & &1.event_name) == ["event_a1", "event_a2"]
      # Aggregate B's event is not in A's stream.
      refute Enum.any?(events_a, &(&1.event_name == "event_b1"))
    end

    test "decodes JSON payload back to a map" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}
      payload = %{"user_id" => "u-123", "count" => 7}

      {:ok, _} = EventLog.append(@aggregate_a, :rich_event, payload, ctx)

      [event] = EventLog.stream_by_aggregate(@aggregate_a)
      assert event.payload == payload
    end

    test "(inserted_at, id) tie-breaker: same-timestamp rows order by id asc" do
      # Force two writes to share the same inserted_at down to the
      # microsecond — SPEC §5.1 (codex r2 MED-2): id is the deterministic
      # tie-breaker.
      same_ts = DateTime.utc_now()

      ctx = %{caller: @caller, workspace_uri: @workspace_x, inserted_at: same_ts}

      {:ok, id1} = EventLog.append(@aggregate_a, :tied_a, %{}, ctx)
      {:ok, id2} = EventLog.append(@aggregate_a, :tied_b, %{}, ctx)
      {:ok, id3} = EventLog.append(@aggregate_a, :tied_c, %{}, ctx)

      assert id1 < id2
      assert id2 < id3

      events = EventLog.stream_by_aggregate(@aggregate_a)

      assert Enum.map(events, & &1.event_name) == ["tied_a", "tied_b", "tied_c"]
      assert Enum.map(events, & &1.event_id) == [id1, id2, id3]
    end

    test ":order, :desc flips both axes of the composite ordering" do
      same_ts = DateTime.utc_now()
      ctx = %{caller: @caller, workspace_uri: @workspace_x, inserted_at: same_ts}

      {:ok, _id1} = EventLog.append(@aggregate_a, :first, %{}, ctx)
      {:ok, _id2} = EventLog.append(@aggregate_a, :second, %{}, ctx)
      {:ok, _id3} = EventLog.append(@aggregate_a, :third, %{}, ctx)

      events = EventLog.stream_by_aggregate(@aggregate_a, order: :desc)

      assert Enum.map(events, & &1.event_name) == ["third", "second", "first"]
    end

    test ":since opt filters strictly after the timestamp" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}

      {:ok, _} = EventLog.append(@aggregate_a, :before, %{}, ctx)
      # Snapshot cursor between writes.
      Process.sleep(2)
      cursor = DateTime.utc_now()
      Process.sleep(2)
      {:ok, _} = EventLog.append(@aggregate_a, :after, %{}, ctx)

      events = EventLog.stream_by_aggregate(@aggregate_a, since: cursor)

      assert Enum.map(events, & &1.event_name) == ["after"]
    end

    test ":limit caps the result size" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}

      Enum.each(1..5, fn n ->
        {:ok, _} = EventLog.append(@aggregate_a, :"e#{n}", %{}, ctx)
      end)

      events = EventLog.stream_by_aggregate(@aggregate_a, limit: 3)
      assert length(events) == 3
    end
  end

  describe "stream_by_workspace/2" do
    test "isolates rows across workspaces" do
      {:ok, _} =
        EventLog.append(@aggregate_a, :in_x, %{}, %{
          caller: @caller,
          workspace_uri: @workspace_x
        })

      {:ok, _} =
        EventLog.append(@aggregate_b, :in_y, %{}, %{
          caller: @caller,
          workspace_uri: @workspace_y
        })

      events_x = EventLog.stream_by_workspace(@workspace_x)
      events_y = EventLog.stream_by_workspace(@workspace_y)

      test_event_names = fn events ->
        events
        |> Enum.map(& &1.event_name)
        |> Enum.filter(&(&1 in ["in_x", "in_y"]))
      end

      assert test_event_names.(events_x) == ["in_x"]
      assert test_event_names.(events_y) == ["in_y"]
    end

    test "honours `:limit` + `:order` like stream_by_aggregate" do
      ctx = %{caller: @caller, workspace_uri: @workspace_x}
      same_ts = DateTime.utc_now()
      ctx = Map.put(ctx, :inserted_at, same_ts)

      Enum.each(1..4, fn n ->
        {:ok, _} = EventLog.append(@aggregate_a, :"w#{n}", %{}, ctx)
      end)

      events = EventLog.stream_by_workspace(@workspace_x, limit: 2, order: :desc)

      assert length(events) == 2
      assert Enum.map(events, & &1.event_name) == ["w4", "w3"]
    end
  end
end
