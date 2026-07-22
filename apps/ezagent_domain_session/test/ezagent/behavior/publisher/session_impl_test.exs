defmodule Ezagent.ActionSet.Publisher.SessionImplTest do
  @moduledoc """
  Unit tests for `Ezagent.ActionSet.Publisher.SessionImpl` — direct
  handler + `handle_signal/2` exercises against synthetic flat slices. No
  live KindRegistry / SliceChange wiring (covered by the integration tests
  in `EzagentDomainInstanceMessage.Integration.PublisherSessionTest`).

  ## Lifecycle migration (SPEC 2026-05-29) — accessor updates

  After `use Ezagent.ActionSet` → `use Ezagent.Lifecycle`:
  - `init_slice/1` returns the two-container `%{state:, transients:}`
    shape; `fresh_slice/1` returns a FLAT working slice (persistent +
    transient co-located) for the direct-handler unit tests, the same
    way `EzagentDomainInstanceMessage.Test.BehaviorInvoker` exposes a flat slice.
  - `handle_kind_message/3` → `handle_signal/2`. The `signal/3` helper
    below calls `handle_signal/2` with `ctx.read` over the flat slice +
    `ctx.transients` = the flat slice, folds the returned `:set` /
    `:set_transient` effects back onto the flat slice (both containers
    co-located), and lifts the `{:ok, [effects]} | :ignore` result into
    the old `{:ok, new_slice} | :ignore` shape the assertions use.
  - `reconcile_after_load/2` is GONE — its subscriber/monitor clear is
    subsumed by the transient container (rebuilt EMPTY every `activate/2`).
    The reconcile describe block is replaced with `create/1` +
    `activate/2` structural assertions of the same invariant.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Publisher.SessionImpl
  alias Ezagent.Publisher.Event

  defp ctx(self_uri \\ Ezagent.URI.new!("session://team-alpha/default/unit-test")) do
    %{
      self_uri: self_uri,
      kind_module: Ezagent.Entity.Session,
      caller: Ezagent.URI.new!("entity://system/user/admin"),
      authenticated_principal: Ezagent.URI.new!("entity://system/user/admin"),
      caps: MapSet.new()
    }
  end

  # FLAT working slice for direct-handler unit tests: persistent fields
  # (`ring`/`cursor`/`retention`) + transient maps (`subscribers`/
  # `monitors`) co-located, matching the BehaviorInvoker convention.
  defp fresh_slice(opts \\ []) do
    {:ok, state} =
      SessionImpl.create(%{publisher_retention: Keyword.get(opts, :retention, 100)})

    Map.merge(state, %{subscribers: %{}, monitors: %{}})
  end

  # Call `handle_signal/2` with a flat slice and fold the returned effects
  # back onto it (both `:set` and `:set_transient` write the same flat
  # map). Lifts `{:ok, [effects]} | :ignore` → `{:ok, new_slice} | :ignore`.
  defp signal(message, slice, ctx) do
    enriched =
      ctx
      |> Map.put(:read, fn key, default -> Map.get(slice, key, default) end)
      |> Map.put(:transients, slice)

    case SessionImpl.handle_signal(message, enriched) do
      :ignore ->
        :ignore

      {:ok, effects} when is_list(effects) ->
        new_slice =
          Enum.reduce(effects, slice, fn
            {:set, k, v}, acc -> Map.put(acc, k, v)
            {:set_transient, k, v}, acc -> Map.put(acc, k, v)
            _other, acc -> acc
          end)

        {:ok, new_slice}
    end
  end

  # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25) — the SliceChange
  # broadcast envelope is security-minimal: `uri / slice_key /
  # cursor / event_at / result_summary`. The `:self_uri` field was
  # renamed `:uri`; slice content (`new_slice`/`old_slice`/`result`)
  # is stripped. SessionImpl re-fetches via `Kind.get_slice/2`;
  # unit tests pass a `nil` payload because no live Kind exists.
  # `new_slice_map` is kept as a positional arg for test legibility
  # (the test wants to assert on cursor / count, not payload).
  defp slice_change(self_uri, _new_slice_map, opts \\ []) do
    %{
      uri: self_uri,
      slice_key: Keyword.get(opts, :slice_key, :session),
      cursor: Keyword.get(opts, :cursor, 1),
      event_at: DateTime.utc_now(),
      result_summary: :ok
    }
  end

  # Architectural-invariant gate per feedback_completion_requires_invariant_test
  # (Allen 2026-05-05). These tests FAIL when the Session ↔ Publisher
  # binding regresses — a future refactor that "moves Publisher to
  # another Kind" without updating Session would otherwise leave
  # SessionImpl orphaned, tests passing, invariant silently broken.
  describe "INVARIANT: Session is the V1 Publisher" do
    test "Ezagent.Entity.Session declares @behaviour Ezagent.ActionSet.Publisher" do
      behaviours =
        :attributes
        |> Ezagent.Entity.Session.__info__()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ezagent.ActionSet.Publisher in behaviours,
             "Session must declare @behaviour Ezagent.ActionSet.Publisher " <>
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

    test "Session.behaviors/0 includes Ezagent.ActionSet.Publisher.SessionImpl" do
      # Without SessionImpl in behaviors/0, the :publisher slice is
      # never initialized at Kind spawn — silent breakage.
      assert SessionImpl in Ezagent.Entity.Session.behaviors()
    end
  end

  describe "create/1 + init_slice/1 (Lifecycle two-container)" do
    test "create/1 returns the persistent fields only (default retention 100)" do
      assert {:ok, state} = SessionImpl.create(%{})

      assert state == %{ring: [], cursor: 0, retention: 100}
      # subscribers / monitors are TRANSIENTS, not in persistent state.
      refute Map.has_key?(state, :subscribers)
      refute Map.has_key?(state, :monitors)
    end

    test "init_slice/1 wraps create/1 in the two-container shape (transients empty)" do
      slice = SessionImpl.init_slice(%{})

      assert slice == %{
               state: %{ring: [], cursor: 0, retention: 100},
               transients: %{}
             }
    end

    test "honors :publisher_retention spawn arg" do
      assert {:ok, %{retention: 3}} = SessionImpl.create(%{publisher_retention: 3})
    end

    test "activate/2 rebuilds the transient subscriber/monitor maps EMPTY + the SliceChange subscription token" do
      ctx = %{self_uri: Ezagent.URI.new!("session://team-alpha/default/activate")}
      assert {:ok, transients} = SessionImpl.activate(%{ring: [], cursor: 0, retention: 100}, ctx)
      assert transients.subscribers == %{}
      assert transients.monitors == %{}
      # The subscription record is itself a transient; subscriber pid is
      # the cold-restart-detectable token (SPEC §6 step 5c).
      assert transients.slice_change_subscription.subscriber == self()
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

    # Lifecycle: `post_init/2` is macro-emitted and returns the unified
    # activate continuation; the self-subscribe folded into `activate/2`.
    test "post_init/2 returns the macro activate continuation" do
      assert SessionImpl.post_init(%{}, fresh_slice()) ==
               {:continue, :ezagent_activate}
    end

    test "activated/2 broadcasts publisher-alive AFTER :ready (post-ready reachability hook)" do
      # `activated/2` (= engine on_ready) runs post-`:ready`; in this unit
      # context PublisherLifecycle.broadcast_alive/1 returns :ok without a
      # live subscriber. The point of the assertion is the hook EXISTS and
      # is the post-ready successor to on_ready (SPEC §9 OQ-5 / §10-R1).
      assert function_exported?(SessionImpl, :activated, 2)

      assert SessionImpl.activated(%{}, %{
               self_uri: Ezagent.URI.new!("session://team-alpha/default/activated")
             }) == :ok
    end
  end

  describe "handle_kind_message({:slice_changed, _})" do
    test "appends an Event with cursor=1 on the first slice change" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/append-1")
      slice = fresh_slice()

      change =
        slice_change(self_uri, %{members: %{:m1 => true}}, slice_key: :session, action: :join)

      assert {:ok, new_slice} =
               signal({:slice_changed, change}, slice, ctx(self_uri))

      assert new_slice.cursor == 1
      assert [%Event{cursor: 1, slice_key: :session}] = new_slice.ring
    end

    test "F1b — Lifecycle :transients are STRIPPED from the slice mirrored into the durable ring" do
      # SPEC §0.1 / §10-R2 / codex F1b. When the mirrored sibling slice
      # has the Lifecycle two-container shape, the Publisher must store
      # ONLY the persistent `:state` view in its ring (the ring IS
      # persisted via the Session's {:snapshot, :on_change}); a live
      # monitor-ref map in `:transients` would otherwise be serialized
      # into durable storage — the indirect "transients leak" path.
      self_uri = Ezagent.URI.new!("session://team-alpha/default/strip-transients")
      slice = fresh_slice()

      change = slice_change(self_uri, %{ignored: true}, slice_key: :session)

      lifecycle_sibling = %{
        state: %{members: %{m1: true}},
        transients: %{monitors: %{make_ref() => :pid}}
      }

      ctx_with_state =
        ctx(self_uri) |> Map.put(:slice_state, %{session: lifecycle_sibling})

      assert {:ok, new_slice} =
               signal({:slice_changed, change}, slice, ctx_with_state)

      [%Event{payload: payload}] = new_slice.ring
      stored = payload.new_slice

      refute Map.has_key?(stored, :transients),
             "Publisher ring stored the :transients sub-key — transients leaked into the durable ring (F1b)"

      assert stored == %{state: %{members: %{m1: true}}}
    end

    test "F1b — a legacy flat sibling slice mirrors UNCHANGED (no :transients sub-key)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/legacy-mirror")
      slice = fresh_slice()
      change = slice_change(self_uri, %{ignored: true}, slice_key: :session)

      legacy_flat = %{members: %{m1: true}, owner_uri: :x}
      ctx_with_state = ctx(self_uri) |> Map.put(:slice_state, %{session: legacy_flat})

      assert {:ok, new_slice} =
               signal({:slice_changed, change}, slice, ctx_with_state)

      [%Event{payload: payload}] = new_slice.ring
      assert payload.new_slice == legacy_flat
    end

    test "ignores slice_changed events for OTHER URIs (topic shape is per-URI but defense-in-depth)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/me")
      other_uri = Ezagent.URI.new!("session://team-alpha/default/other")
      slice = fresh_slice()

      change = slice_change(other_uri, %{x: 1})

      assert signal({:slice_changed, change}, slice, ctx(self_uri)) ==
               :ignore
    end

    test "ignores slice_changed events whose slice_key is :publisher (no emit-loop)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/no-loop")
      slice = fresh_slice()

      change = slice_change(self_uri, %{x: 1}, slice_key: :publisher)

      assert signal({:slice_changed, change}, slice, ctx(self_uri)) ==
               :ignore
    end

    test "trims the ring to retention on overflow (newest events kept)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/trim")
      slice = fresh_slice(retention: 3)

      slice =
        Enum.reduce(1..5, slice, fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new_slice} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new_slice
        end)

      # cursor reflects ALL emissions (monotonic), but ring is trimmed.
      assert slice.cursor == 5
      assert length(slice.ring) == 3
      assert Enum.map(slice.ring, & &1.cursor) == [3, 4, 5]
    end

    test "fans events out to all subscribers via {:publisher_event, %Event{}}" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/fanout")

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
        signal({:slice_changed, change}, slice, ctx(self_uri))

      assert {:publisher_event, %Event{cursor: 1}} = Task.await(task1)
      assert {:publisher_event, %Event{cursor: 1}} = Task.await(task2)
    end
  end

  describe "invoke(:subscribe_from, _, %{cursor: :latest}, _)" do
    test "monitors subscriber pid; replays NOTHING; returns current cursor" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/sub-latest")

      # Pre-populate the slice with 3 events to confirm latest skips them.
      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

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
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
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
      self_uri = Ezagent.URI.new!("session://team-alpha/default/sub-earliest")

      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      parent = self()

      pid =
        spawn(fn ->
          msgs = collect_events(3, [])
          send(parent, {:got, msgs})
        end)

      assert {:ok, _new_slice, %{cursor: 3}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: pid, cursor: :earliest},
                 ctx(self_uri)
               )

      assert_receive {:got, events}, 500
      assert Enum.map(events, & &1.cursor) == [1, 2, 3]
    end
  end

  describe "invoke(:subscribe_from, ...) — dead-subscriber pruning (2026-05-26)" do
    test "removes pids that died before a new subscribe arrives (worker restart-storm guard)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/sub-dead-prune")

      # Simulate the worker-restart-storm: spawn 3 short-lived processes,
      # subscribe each, let them die, then subscribe a fresh long-lived one.
      # Without the prune the subscribers map would carry all 4 entries
      # (the 3 dead ones DOWNed after each call rather than during),
      # and every subscribe would mutate the slice — triggering an
      # on_change snapshot.write of the full ~30KB state binary per
      # call. Pre-fix this drove the outbound feishu e2e into a 5s+
      # subscribe_from deadline_ms timeout loop.
      slice = fresh_slice()

      slice =
        Enum.reduce(1..3, slice, fn _n, acc ->
          dead_pid = spawn(fn -> :ok end)
          # Let the spawn exit so the pid is genuinely dead by subscribe.
          ref = Process.monitor(dead_pid)
          assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}, 200

          {:ok, new, _} =
            EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
              Ezagent.ActionSet.Publisher.SessionImpl,
              :subscribe_from,
              acc,
              %{subscriber_pid: dead_pid, cursor: :latest},
              ctx(self_uri)
            )

          new
        end)

      # Now subscribe a fresh live subscriber. The 3 dead pids should be
      # pruned by the time invoke returns.
      live_task =
        Task.async(fn ->
          receive do
            _ -> :got
          after
            100 -> :nope
          end
        end)

      {:ok, final_slice, _} =
        EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
          Ezagent.ActionSet.Publisher.SessionImpl,
          :subscribe_from,
          slice,
          %{subscriber_pid: live_task.pid, cursor: :latest},
          ctx(self_uri)
        )

      # Slice should only contain the live subscriber after prune.
      assert map_size(final_slice.subscribers) == 1,
             """
             Expected subscribers map to be pruned of dead pids; got
             #{map_size(final_slice.subscribers)} entries:
             #{inspect(final_slice.subscribers, limit: :infinity)}
             """

      assert Map.has_key?(final_slice.subscribers, live_task.pid)
      # Cleanup test pid.
      Task.shutdown(live_task, :brutal_kill)
    end
  end

  describe "invoke(:subscribe_from, _, %{cursor: <integer>}, _)" do
    test "replays only events with cursor > N (window: exclusive lower bound)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/sub-cursor")

      slice =
        Enum.reduce(1..5, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

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
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: pid, cursor: 2},
                 ctx(self_uri)
               )

      assert_receive {:got, events}, 500
      assert Enum.map(events, & &1.cursor) == [3, 4, 5]
    end

    test "returns {:error, :cursor_out_of_window} when cursor is older than oldest retained" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/sub-oow")

      # retention=2, emit 5 → oldest retained cursor is 4.
      slice =
        Enum.reduce(1..5, fresh_slice(retention: 2), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      # Asking from cursor=1 — older than oldest (4) by far.
      assert {:error, :cursor_out_of_window} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :subscribe_from,
                 slice,
                 %{subscriber_pid: self(), cursor: 1},
                 ctx(self_uri)
               )
    end
  end

  describe "invoke(:snapshot, _, _, _)" do
    test "returns the current cursor + the most-recent payload as state" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/snap")
      slice = fresh_slice()

      change = slice_change(self_uri, %{x: 1}, slice_key: :session, action: :send)

      {:ok, slice, _} =
        signal({:slice_changed, change}, slice, ctx(self_uri))
        |> case do
          {:ok, new_slice} -> {:ok, new_slice, nil}
        end

      assert {:ok, ^slice, %{cursor: 1, state: state}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :snapshot,
                 slice,
                 %{},
                 ctx(self_uri)
               )

      # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25) — `build_payload/2`
      # re-fetches the slice via `Kind.get_slice/2`. In this unit
      # test no live Kind exists for `self_uri`, so the re-fetch
      # returns `:not_found` and `:new_slice` resolves to `nil`. The
      # integration test
      # `EzagentDomainInstanceMessage.Integration.PublisherSessionTest` covers
      # the live-Kind path and asserts on actual slice content.
      assert Map.has_key?(state, :new_slice)
      assert state.new_slice == nil
    end

    test "returns cursor=0 + state=nil when the ring is empty" do
      slice = fresh_slice()

      assert {:ok, ^slice, %{cursor: 0, state: nil}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :snapshot,
                 slice,
                 %{},
                 ctx()
               )
    end
  end

  describe "invoke(:history, _, %{from, to}, _)" do
    test "returns events in the (from, to] window — from exclusive, to inclusive" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/hist")

      slice =
        Enum.reduce(1..5, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      # history(1, 3) — from exclusive, to inclusive → cursors 2, 3
      assert {:ok, _slice, %{events: events}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :history,
                 slice,
                 %{from: 1, to: 3},
                 ctx(self_uri)
               )

      assert Enum.map(events, & &1.cursor) == [2, 3]
    end

    test "defaults: from=:earliest, to=:latest → entire ring" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/hist-all")

      slice =
        Enum.reduce(1..3, fresh_slice(), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      assert {:ok, _slice, %{events: events}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :history,
                 slice,
                 %{},
                 ctx(self_uri)
               )

      assert Enum.map(events, & &1.cursor) == [1, 2, 3]
    end

    test "returns :cursor_out_of_window when from precedes oldest retained" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/hist-oow")

      slice =
        Enum.reduce(1..5, fresh_slice(retention: 2), fn n, acc ->
          change = slice_change(self_uri, %{n: n})

          {:ok, new} =
            signal({:slice_changed, change}, acc, ctx(self_uri))

          new
        end)

      assert {:error, :cursor_out_of_window} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Publisher.SessionImpl,
                 :history,
                 slice,
                 %{from: 1, to: :latest},
                 ctx(self_uri)
               )
    end
  end

  describe "handle_kind_message({:DOWN, ...}) subscriber cleanup" do
    test "removes a subscriber on DOWN; new slice has neither the subscriber nor the monitor ref" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/down")

      # Spawn a subscriber + monitor it.
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)

      slice = %{
        fresh_slice()
        | subscribers: %{pid => ref},
          monitors: %{ref => pid}
      }

      down_msg = {:DOWN, ref, :process, pid, :normal}

      assert {:ok, new_slice} = signal(down_msg, slice, ctx(self_uri))

      assert new_slice.subscribers == %{}
      assert new_slice.monitors == %{}
    end

    test ":ignore on DOWN for an unknown ref (could belong to another Behavior)" do
      foreign_ref = Process.monitor(self())
      slice = fresh_slice()
      down_msg = {:DOWN, foreign_ref, :process, self(), :normal}
      assert :ignore = signal(down_msg, slice, ctx())
    after
      :ok
    end

    test "publisher still works after a subscriber DOWN (no leak / no crash on next emit)" do
      self_uri = Ezagent.URI.new!("session://team-alpha/default/down-then-emit")

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
               signal(
                 {:DOWN, ref, :process, pid, :normal},
                 slice,
                 ctx(self_uri)
               )

      assert cleaned.subscribers == %{}

      # Now a fresh slice change goes through cleanly.
      change = slice_change(self_uri, %{x: 1})

      assert {:ok, after_emit} =
               signal({:slice_changed, change}, cleaned, ctx(self_uri))

      assert after_emit.cursor == 1
      assert length(after_emit.ring) == 1
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §10-R1 / §9 OQ-5): the old
  # `reconcile_after_load/2` cleared the transient subscriber/monitor maps
  # on snapshot load. Under Lifecycle those maps are TRANSIENTS — they
  # live in `transients`, which has NO serialization path and is rebuilt
  # EMPTY by `activate/2` on every start. The reconcile-clear is therefore
  # subsumed by the container model: there is structurally nothing to
  # clear. These tests assert that the SAME invariant — no stale handle
  # survives a restart — holds by construction.
  describe "transients are NOT persisted (subsumes the old reconcile_after_load clear)" do
    test "create/1 builds NO subscriber/monitor maps in persistent state" do
      assert {:ok, state} = SessionImpl.create(%{})
      refute Map.has_key?(state, :subscribers)
      refute Map.has_key?(state, :monitors)
    end

    test "activate/2 rebuilds subscribers + monitors EMPTY regardless of prior incarnation" do
      uri = Ezagent.URI.new!("session://team-alpha/default/transient-rebuild-1")

      # A rehydrated persistent state carries ONLY the durable fields.
      state = %{ring: [], cursor: 0, retention: 100}

      assert {:ok, transients} = SessionImpl.activate(state, %{self_uri: uri})
      assert transients.subscribers == %{}
      assert transients.monitors == %{}
    end

    test "durable fields are preserved through a cold-load (rehydrated state passes through activate untouched)" do
      uri = Ezagent.URI.new!("session://team-alpha/default/transient-rebuild-2")

      stale_event = %Event{
        cursor: 7,
        publisher_uri: uri,
        slice_key: :session,
        event_at: DateTime.utc_now(),
        payload: %{new_slice: %{}}
      }

      # `activate/2` returns a 2-arity {:ok, transients} — it does NOT
      # reconcile state for SessionImpl (state is already durable), so the
      # persistent ring/cursor/retention survive unchanged from the
      # rehydrated snapshot.
      state = %{ring: [stale_event], cursor: 7, retention: 42}

      assert {:ok, transients} = SessionImpl.activate(state, %{self_uri: uri})
      assert transients.subscribers == %{}
      assert transients.monitors == %{}
      # State is unchanged by activate (no 3-arity reconcile return).
    end

    test "activate/2 is idempotent — re-running yields EMPTY transient maps again" do
      uri = Ezagent.URI.new!("session://team-alpha/default/transient-rebuild-3")
      state = %{ring: [], cursor: 0, retention: 100}

      assert {:ok, once} = SessionImpl.activate(state, %{self_uri: uri})
      assert {:ok, twice} = SessionImpl.activate(state, %{self_uri: uri})
      assert once.subscribers == twice.subscribers
      assert once.monitors == twice.monitors
      assert once.subscribers == %{}
    end

    test "reconcile_after_load/2 is GONE from the developer surface (folded into activate)" do
      # The Lifecycle migration removed the developer-facing
      # `reconcile_after_load/2`; the transient container subsumes it.
      refute function_exported?(SessionImpl, :reconcile_after_load, 2)
      # The Lifecycle hooks that replace it ARE exported.
      assert function_exported?(SessionImpl, :create, 1)
      assert function_exported?(SessionImpl, :activate, 2)
      assert function_exported?(SessionImpl, :activated, 2)
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
