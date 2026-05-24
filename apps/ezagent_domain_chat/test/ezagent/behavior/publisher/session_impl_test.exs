defmodule Ezagent.Behavior.Publisher.SessionImplTest do
  @moduledoc """
  Unit tests for `Ezagent.Behavior.Publisher.SessionImpl` — direct
  `invoke/4` + `handle_kind_message/3` exercises against synthetic
  slices. No live KindRegistry / SliceChange wiring (covered by the
  integration tests in `EzagentDomainChat.Integration.PublisherSessionTest`).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Publisher.SessionImpl
  alias Ezagent.Publisher.Event

  defp ctx(self_uri \\ URI.parse("session://default/default/unit-test")) do
    %{
      self_uri: self_uri,
      kind_module: Ezagent.Entity.Session,
      caller: URI.parse("entity://user/system/admin"),
      caps: MapSet.new()
    }
  end

  defp fresh_slice(opts \\ []) do
    SessionImpl.init_slice(%{publisher_retention: Keyword.get(opts, :retention, 100)})
  end

  defp slice_change(self_uri, new_slice_map, opts \\ []) do
    %{
      self_uri: self_uri,
      kind_module: Ezagent.Entity.Session,
      action: Keyword.get(opts, :action, :send),
      slice_key: Keyword.get(opts, :slice_key, :chat),
      old_slice: Keyword.get(opts, :old_slice, %{}),
      new_slice: new_slice_map,
      result: nil,
      caller: nil,
      at: DateTime.utc_now()
    }
  end

  # Architectural-invariant gate per feedback_completion_requires_invariant_test
  # (Allen 2026-05-05). These tests FAIL when the Session ↔ Publisher
  # binding regresses — a future refactor that "moves Publisher to
  # another Kind" without updating Session would otherwise leave
  # SessionImpl orphaned, tests passing, invariant silently broken.
  describe "INVARIANT: Session is the V1 Publisher" do
    test "Ezagent.Entity.Session declares @behaviour Ezagent.Behavior.Publisher" do
      behaviours =
        :attributes
        |> Ezagent.Entity.Session.__info__()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ezagent.Behavior.Publisher in behaviours,
             "Session must declare @behaviour Ezagent.Behavior.Publisher " <>
               "(SPEC §2.1 'first implementer'). Got: #{inspect(behaviours)}"
    end

    test "Session exports the four Publisher callbacks (3-ary contract)" do
      assert function_exported?(Ezagent.Entity.Session, :history_retention, 0)
      assert function_exported?(Ezagent.Entity.Session, :subscribe_from, 3)
      assert function_exported?(Ezagent.Entity.Session, :snapshot, 1)
      assert function_exported?(Ezagent.Entity.Session, :history, 3)
    end

    test "Session ALSO exports ctx-bearing variants (codex round-1 CRITICAL fix)" do
      # The 3-ary contract callbacks RAISE (no-ambient-caps invariant);
      # production callers use these 4-ary / 2-ary forms with explicit
      # `ctx: %{caller, caps}`. See SessionImpl moduledoc.
      assert function_exported?(Ezagent.Entity.Session, :subscribe_from, 4)
      assert function_exported?(Ezagent.Entity.Session, :snapshot, 2)
      assert function_exported?(Ezagent.Entity.Session, :history, 4)
    end

    test "Session.history_retention/0 == 100 (OQ-EM-A resolution: count-based, V1 default)" do
      assert Ezagent.Entity.Session.history_retention() == 100
    end

    test "Session.behaviors/0 includes Ezagent.Behavior.Publisher.SessionImpl" do
      # Without SessionImpl in behaviors/0, the :publisher slice is
      # never initialized at Kind spawn — silent breakage.
      assert SessionImpl in Ezagent.Entity.Session.behaviors()
    end
  end

  describe "init_slice/1" do
    test "returns the documented slice shape with default retention 100" do
      slice = SessionImpl.init_slice(%{})

      assert slice == %{
               ring: [],
               cursor: 0,
               retention: 100,
               subscribers: %{},
               monitors: %{}
             }
    end

    test "honors :publisher_retention spawn arg" do
      slice = SessionImpl.init_slice(%{publisher_retention: 3})
      assert slice.retention == 3
    end
  end

  describe "Behavior contract surface" do
    test "actions/0 lists the three publisher actions" do
      assert SessionImpl.actions() == [:subscribe_from, :snapshot, :history]
    end

    test "state_slice/0 is :publisher (sibling to :chat, not nested)" do
      assert SessionImpl.state_slice() == :publisher
    end

    test "cap_subjects/0 declares English descriptions for every action" do
      subjects = SessionImpl.cap_subjects()
      assert length(subjects) == 3

      Enum.each(subjects, fn {action, desc} ->
        assert action in [:subscribe_from, :snapshot, :history]
        assert is_binary(desc) and desc != ""
      end)
    end

    test "post_init/2 returns {:continue, :subscribe_to_self_slice_change}" do
      assert SessionImpl.post_init(%{}, fresh_slice()) ==
               {:continue, :subscribe_to_self_slice_change}
    end
  end

  describe "handle_kind_message({:slice_changed, _})" do
    test "appends an Event with cursor=1 on the first slice change" do
      self_uri = URI.parse("session://default/default/append-1")
      slice = fresh_slice()

      change =
        slice_change(self_uri, %{members: %{:m1 => true}}, slice_key: :chat, action: :join)

      assert {:ok, new_slice} =
               SessionImpl.handle_kind_message({:slice_changed, change}, slice, ctx(self_uri))

      assert new_slice.cursor == 1
      assert [%Event{cursor: 1, slice_key: :chat}] = new_slice.ring
    end

    test "ignores slice_changed events for OTHER URIs (topic shape is per-URI but defense-in-depth)" do
      self_uri = URI.parse("session://default/default/me")
      other_uri = URI.parse("session://default/default/other")
      slice = fresh_slice()

      change = slice_change(other_uri, %{x: 1})

      assert SessionImpl.handle_kind_message({:slice_changed, change}, slice, ctx(self_uri)) ==
               :ignore
    end

    test "ignores slice_changed events whose slice_key is :publisher (no emit-loop)" do
      self_uri = URI.parse("session://default/default/no-loop")
      slice = fresh_slice()

      change = slice_change(self_uri, %{x: 1}, slice_key: :publisher)

      assert SessionImpl.handle_kind_message({:slice_changed, change}, slice, ctx(self_uri)) ==
               :ignore
    end

    test "trims the ring to retention on overflow (newest events kept)" do
      self_uri = URI.parse("session://default/default/trim")
      slice = fresh_slice(retention: 3)

      slice =
        Enum.reduce(1..5, slice, fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new_slice} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new_slice
        end)

      # cursor reflects ALL emissions (monotonic), but ring is trimmed.
      assert slice.cursor == 5
      assert length(slice.ring) == 3
      assert Enum.map(slice.ring, & &1.cursor) == [3, 4, 5]
    end

    test "fans events out to all subscribers via {:publisher_event, %Event{}}" do
      self_uri = URI.parse("session://default/default/fanout")

      # Two listener pids.
      task1 =
        Task.async(fn ->
          receive do
            msg -> msg
          end
        end)

      task2 =
        Task.async(fn ->
          receive do
            msg -> msg
          end
        end)

      ref1 = Process.monitor(task1.pid)
      ref2 = Process.monitor(task2.pid)

      slice = %{
        fresh_slice()
        | subscribers: %{task1.pid => ref1, task2.pid => ref2},
          monitors: %{ref1 => task1.pid, ref2 => task2.pid}
      }

      change = slice_change(self_uri, %{x: 1})

      {:ok, _new_slice} =
        SessionImpl.handle_kind_message({:slice_changed, change}, slice, ctx(self_uri))

      assert {:publisher_event, %Event{cursor: 1}} = Task.await(task1)
      assert {:publisher_event, %Event{cursor: 1}} = Task.await(task2)
    end
  end

  describe "invoke(:subscribe_from, _, %{cursor: :latest}, _)" do
    test "monitors subscriber pid; replays NOTHING; returns current cursor" do
      self_uri = URI.parse("session://default/default/sub-latest")

      # Pre-populate the slice with 3 events to confirm latest skips them.
      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      task =
        Task.async(fn ->
          receive do
            msg -> msg
          after
            100 -> :no_message
          end
        end)

      assert {:ok, new_slice, %{cursor: 3}} =
               SessionImpl.invoke(
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: task.pid, cursor: :latest},
                 ctx(self_uri)
               )

      # Subscriber is now monitored.
      assert Map.has_key?(new_slice.subscribers, task.pid)

      # No backlog replay.
      assert Task.await(task) == :no_message
    end
  end

  describe "invoke(:subscribe_from, _, %{cursor: :earliest}, _)" do
    test "replays the entire retained history in cursor-ascending order" do
      self_uri = URI.parse("session://default/default/sub-earliest")

      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      parent = self()

      pid =
        spawn(fn ->
          msgs = collect_events(3, [])
          send(parent, {:got, msgs})
        end)

      assert {:ok, _new_slice, %{cursor: 3}} =
               SessionImpl.invoke(
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: pid, cursor: :earliest},
                 ctx(self_uri)
               )

      assert_receive {:got, events}, 500
      assert Enum.map(events, & &1.cursor) == [1, 2, 3]
    end
  end

  describe "invoke(:subscribe_from, _, %{cursor: <integer>}, _)" do
    test "replays only events with cursor > N (window: exclusive lower bound)" do
      self_uri = URI.parse("session://default/default/sub-cursor")

      slice =
        Enum.reduce(1..5, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      parent = self()

      pid =
        spawn(fn ->
          msgs = collect_events(3, [])
          send(parent, {:got, msgs})
        end)

      # cursor=2 → replay 3, 4, 5
      assert {:ok, _new_slice, %{cursor: 5}} =
               SessionImpl.invoke(
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: pid, cursor: 2},
                 ctx(self_uri)
               )

      assert_receive {:got, events}, 500
      assert Enum.map(events, & &1.cursor) == [3, 4, 5]
    end

    test "returns {:error, :cursor_out_of_window} when cursor is older than oldest retained" do
      self_uri = URI.parse("session://default/default/sub-oow")

      # retention=2, emit 5 → oldest retained cursor is 4.
      slice =
        Enum.reduce(1..5, fresh_slice(retention: 2), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      # Asking from cursor=1 — older than oldest (4) by far.
      assert {:error, :cursor_out_of_window} =
               SessionImpl.invoke(
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: self(), cursor: 1},
                 ctx(self_uri)
               )
    end
  end

  describe "invoke(:snapshot, _, _, _)" do
    test "returns the current cursor + the most-recent payload as state" do
      self_uri = URI.parse("session://default/default/snap")
      slice = fresh_slice()

      change = slice_change(self_uri, %{x: 1}, slice_key: :chat, action: :send)

      {:ok, slice, _} =
        SessionImpl.handle_kind_message({:slice_changed, change}, slice, ctx(self_uri))
        |> case do
          {:ok, new_slice} -> {:ok, new_slice, nil}
        end

      assert {:ok, ^slice, %{cursor: 1, state: state}} =
               SessionImpl.invoke(:snapshot, slice, %{}, ctx(self_uri))

      assert state.new_slice == %{x: 1}
    end

    test "returns cursor=0 + state=nil when the ring is empty" do
      slice = fresh_slice()

      assert {:ok, ^slice, %{cursor: 0, state: nil}} =
               SessionImpl.invoke(:snapshot, slice, %{}, ctx())
    end
  end

  describe "invoke(:history, _, %{from, to}, _)" do
    test "returns events in the (from, to] window — from exclusive, to inclusive" do
      self_uri = URI.parse("session://default/default/hist")

      slice =
        Enum.reduce(1..5, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      # history(1, 3) — from exclusive, to inclusive → cursors 2, 3
      assert {:ok, _slice, %{events: events}} =
               SessionImpl.invoke(:history, slice, %{from: 1, to: 3}, ctx(self_uri))

      assert Enum.map(events, & &1.cursor) == [2, 3]
    end

    test "defaults: from=:earliest, to=:latest → entire ring" do
      self_uri = URI.parse("session://default/default/hist-all")

      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      assert {:ok, _slice, %{events: events}} =
               SessionImpl.invoke(:history, slice, %{}, ctx(self_uri))

      assert Enum.map(events, & &1.cursor) == [1, 2, 3]
    end

    test "returns :cursor_out_of_window when from precedes oldest retained" do
      self_uri = URI.parse("session://default/default/hist-oow")

      slice =
        Enum.reduce(1..5, fresh_slice(retention: 2), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            SessionImpl.handle_kind_message({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      assert {:error, :cursor_out_of_window} =
               SessionImpl.invoke(:history, slice, %{from: 1, to: :latest}, ctx(self_uri))
    end
  end

  describe "handle_kind_message({:DOWN, ...}) subscriber cleanup" do
    test "removes a subscriber on DOWN; new slice has neither the subscriber nor the monitor ref" do
      self_uri = URI.parse("session://default/default/down")

      # Spawn a subscriber + monitor it.
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)

      slice = %{
        fresh_slice()
        | subscribers: %{pid => ref},
          monitors: %{ref => pid}
      }

      down_msg = {:DOWN, ref, :process, pid, :normal}

      assert {:ok, new_slice} = SessionImpl.handle_kind_message(down_msg, slice, ctx(self_uri))

      assert new_slice.subscribers == %{}
      assert new_slice.monitors == %{}
    end

    test ":ignore on DOWN for an unknown ref (could belong to another Behavior)" do
      foreign_ref = Process.monitor(self())
      slice = fresh_slice()
      down_msg = {:DOWN, foreign_ref, :process, self(), :normal}
      assert :ignore = SessionImpl.handle_kind_message(down_msg, slice, ctx())
    after
      :ok
    end

    test "publisher still works after a subscriber DOWN (no leak / no crash on next emit)" do
      self_uri = URI.parse("session://default/default/down-then-emit")

      # Subscriber that exits immediately.
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)

      # Wait for the DOWN to be deliverable.
      :ok = wait_until_dead(pid)

      slice = %{
        fresh_slice()
        | subscribers: %{pid => ref},
          monitors: %{ref => pid}
      }

      # First simulate the DOWN cleanup the Server would deliver.
      assert {:ok, cleaned} =
               SessionImpl.handle_kind_message(
                 {:DOWN, ref, :process, pid, :normal},
                 slice,
                 ctx(self_uri)
               )

      assert cleaned.subscribers == %{}

      # Now a fresh slice change goes through cleanly.
      change = slice_change(self_uri, %{x: 1})

      assert {:ok, after_emit} =
               SessionImpl.handle_kind_message({:slice_changed, change}, cleaned, ctx(self_uri))

      assert after_emit.cursor == 1
      assert length(after_emit.ring) == 1
    end
  end

  # -- helpers --------------------------------------------------------------

  defp collect_events(0, acc), do: Enum.reverse(acc)

  defp collect_events(n, acc) when n > 0 do
    receive do
      {:publisher_event, %Event{} = ev} -> collect_events(n - 1, [ev | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  defp wait_until_dead(pid, attempts \\ 50)

  defp wait_until_dead(_pid, 0), do: :timeout

  defp wait_until_dead(pid, attempts) when attempts > 0 do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_until_dead(pid, attempts - 1)
    else
      :ok
    end
  end
end
