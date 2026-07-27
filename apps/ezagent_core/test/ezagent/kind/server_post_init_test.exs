defmodule Ezagent.Kind.ServerPostInitTest do
  @moduledoc """
  PR-EM-CORE acceptance tests — verify `Ezagent.Kind.Server` chains
  post-init continuations AFTER `:announce_ready` and preserves the
  pre-PR behaviour for Kinds whose Behaviors do not declare
  `post_init/2`.

  See ExternalMirror SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-CORE for the requirements driving this test.
  """

  use EzagentCore.DataCase, async: false

  require Logger

  alias Ezagent.TestSupport.{
    MultiPostInitKind,
    NoPostInitBehavior,
    NoPostInitKind,
    OrderTracker,
    PostInitBehavior,
    PostInitBehaviorA,
    PostInitBehaviorB,
    PostInitCrashBehavior,
    PostInitCrashKind,
    PostInitKind,
    SlowPostInitBehavior,
    SlowPostInitKind
  }

  setup do
    {:ok, tracker} = OrderTracker.start_link([])
    # Unique URI per test so KindRegistry / ReadyGate state never collide.
    suffix = System.unique_integer([:positive])
    {:ok, tracker: tracker, suffix: suffix}
  end

  # -------------------------------------------------------------------
  # Test 1 — happy path: post_init/2 → handle_continue/3 chain runs
  # AFTER announce_ready; slice is mutated; boot order is preserved.
  # -------------------------------------------------------------------

  describe "post-init continuation hook" do
    test "post-init handle_continue/3 runs BEFORE :ready is published and merges new slice back",
         %{tracker: tracker, suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(PostInitKind, :noop, PostInitBehavior)

      {:ok, pid} =
        Ezagent.Kind.Server.start_link({PostInitKind, %{uri: uri, tracker: tracker}})

      # 1. The Kind reaches :ready (round-2 HIGH-1 invariant: :ready
      # only fires AFTER all post-init handle_continue/3 callbacks
      # have completed).
      :ok = wait_until_ready(uri_str, 500)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri_str)
      assert :ready = Ezagent.ReadyGate.status(uri_str)

      # 2. Slice has the post-init mutation merged back via Kind.Server +
      #    snapshot commit path.
      {:ok, slice} = Ezagent.Kind.read(uri_str, :post_init_behavior, spawn: :never)
      assert slice.setup_done == true
      assert slice.continued_with == :setup_thing

      # 3. Boot-order invariant (codex round-2 HIGH-1): at the moment
      #    handle_continue/3 ran, ReadyGate was STILL :not_ready BUT
      #    KindRegistry was already populated. This is the safe-publish
      #    property — external dispatchers cannot see :ready until
      #    post-init has completed, so they never observe a half-
      #    initialised Kind.
      assert [{:post_init, :not_ready, true}] = OrderTracker.events(tracker)
    end

    # -----------------------------------------------------------------
    # Test 2 — backwards-compat: a Behavior with NO post_init/2
    # boots normally with no extra continuation noise.
    # -----------------------------------------------------------------
    test "Behavior without post_init/2 boots unchanged (backwards-compat)",
         %{suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_no_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(NoPostInitKind, :noop, NoPostInitBehavior)

      {:ok, pid} =
        Ezagent.Kind.Server.start_link({NoPostInitKind, %{uri: uri}})

      # Process becomes :ready exactly as it would before PR-EM-CORE.
      :ok = wait_until_ready(uri_str, 500)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri_str)
      assert :ready = Ezagent.ReadyGate.status(uri_str)

      # init_slice/1 output is intact — no post-init mutation, no surprise
      # continuations rewrote it.
      {:ok, slice} = Ezagent.Kind.read(uri_str, :no_post_init, spawn: :never)
      assert slice == %{baseline: :ok, count: 0}

      # No continuation noise — process is alive and responsive to a
      # normal dispatch (would be dead if a stray continuation crashed it).
      assert Process.alive?(pid)
    end

    # -----------------------------------------------------------------
    # Test 3 — multi-Behavior ordering: per-Behavior post-init
    # continuations fire in behaviors/0 declaration order.
    # -----------------------------------------------------------------
    test "multiple Behaviors' post-init continuations run in behaviors/0 order",
         %{tracker: tracker, suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_multi_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(MultiPostInitKind, :noop, PostInitBehaviorA)
      :ok = Ezagent.BehaviorRegistry.register(MultiPostInitKind, :noop, PostInitBehaviorB)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({MultiPostInitKind, %{uri: uri, tracker: tracker}})

      :ok = wait_until_ready(uri_str, 500)
      :ok = wait_until(fn -> length(OrderTracker.events(tracker)) == 2 end, 500)

      # behaviors/0 order is [PostInitBehaviorA, PostInitBehaviorB] →
      # tracker records [:post_init_a, :post_init_b].
      assert [:post_init_a, :post_init_b] = OrderTracker.events(tracker)

      # Both slices got their handle_continue/3 mutations merged.
      {:ok, slice_a} = Ezagent.Kind.read(uri_str, :post_init_a, spawn: :never)
      {:ok, slice_b} = Ezagent.Kind.read(uri_str, :post_init_b, spawn: :never)
      assert slice_a.ran == true
      assert slice_b.ran == true
    end

    # -----------------------------------------------------------------
    # Test 4 — codex round-1 HIGH-1 regression: a pre-ready buffered
    # cast combined with a crashing post-init continuation MUST NOT
    # silently lose the buffered cast. With the fix in place,
    # PendingDelivery.flush/1 is DEFERRED until after the last
    # post-init continuation completes; a crashing post-init causes
    # the process to die WITHOUT having flushed the buffer, so the
    # buffered entries survive in ETS for the next attempt (or for a
    # test like this one to observe).
    # -----------------------------------------------------------------
    test "pre-ready buffered cast survives a crashing post-init continuation",
         %{suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_crash_post_init-#{suffix}")

      :ok =
        Ezagent.BehaviorRegistry.register(PostInitCrashKind, :noop, PostInitCrashBehavior)

      target = Ezagent.URI.with_action(uri, :test, :noop)
      presenter = Ezagent.Entity.User.admin_uri()

      cap =
        signed_fixture_cap!(
          uri,
          PostInitCrashKind.type_name(),
          PostInitCrashBehavior,
          :noop,
          presenter
        )

      pre_inv = %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{},
        ctx: %{
          caller: presenter,
          authenticated_principal: presenter,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      }

      :ok = Ezagent.PendingDelivery.buffer(uri, pre_inv)
      assert Ezagent.PendingDelivery.buffer_size(uri) == 1

      # Suppress the expected crash + Logger.warning noise LOCALLY via
      # capture_log. The previous `Logger.configure(level: :critical)`
      # mutated the GLOBAL logger level — and this test is async: true, so
      # that window suppressed error logs in any concurrent async test.
      # That broke `Ezagent.SagaRunnerTest`'s `with_log` capture of its
      # `Logger.error` operator-repair marker (captured "" → flaky
      # failure). `capture_log/1` redirects only this process's logs, so
      # the global level is untouched.
      Process.flag(:trap_exit, true)

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} =
          Ezagent.Kind.Server.start_link({PostInitCrashKind, %{uri: uri}})

        # Wait for the process to crash (post-init raises).
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
      end)

      # Boot-order invariant: the deferred flush means the buffer is
      # STILL POPULATED after the crash — no silent loss. (Pre-PR
      # behaviour was to flush in :announce_ready BEFORE post-init,
      # which would have left the buffer empty and the self-casted
      # invocations stuck in the dead process's mailbox.)
      assert Ezagent.PendingDelivery.buffer_size(uri) == 1
    end

    # -----------------------------------------------------------------
    # Test 5 — codex round-2 HIGH-1 regression: a cast dispatched
    # WHILE post-init is still running MUST see ReadyGate as
    # :not_ready and buffer via PendingDelivery (NOT deliver
    # directly into the GenServer mailbox, where it could die with
    # a crashing post-init). After post-init completes, mark_ready
    # + flush fires and the buffered cast is delivered.
    # -----------------------------------------------------------------
    test "cast dispatched during post-init window buffers via PendingDelivery (not mailbox)",
         %{suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_dispatch_during_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(SlowPostInitKind, :noop, SlowPostInitBehavior)

      # Start the Kind with a 50ms post-init sleep — gives the test
      # time to assert the not-ready window + issue a dispatch.
      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({SlowPostInitKind, %{uri: uri, post_init_sleep_ms: 50}})

      # The Kind is registered immediately but `:not_ready` until
      # post-init completes. Wait until KindRegistry has the URI,
      # then assert ReadyGate is still :not_ready (we're in the
      # post-init window).
      :ok = wait_until(fn -> match?({:ok, _}, Ezagent.KindRegistry.lookup(uri_str)) end, 200)
      assert :not_ready = Ezagent.ReadyGate.status(uri_str)

      # Now dispatch a :cast while post-init is still running. With
      # the round-2 HIGH-1 fix in place, this MUST buffer via
      # PendingDelivery (because ReadyGate is :not_ready) — NOT
      # land directly in the mailbox.
      target = Ezagent.URI.with_action(uri, :test, :noop)
      presenter = Ezagent.Entity.User.admin_uri()

      cap =
        signed_fixture_cap!(
          uri,
          SlowPostInitKind.type_name(),
          SlowPostInitBehavior,
          :noop,
          presenter
        )

      inv = %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{msg: "during-post-init"},
        ctx: %{
          caller: presenter,
          authenticated_principal: presenter,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      }

      assert :ok = Ezagent.Invocation.dispatch(inv)

      # After post-init completes, ReadyGate flips to :ready AND
      # the buffered cast drains via PendingDelivery.flush/1 →
      # GenServer.cast(self(), ...) → dispatch path → reply.
      assert_receive {:ezagent_reply, {:ok, %{echoed: "during-post-init"}}}, 1000
      assert :ready = Ezagent.ReadyGate.status(uri_str)

      # Slice contains the message that flowed through the buffered
      # cast — proves end-to-end delivery via PendingDelivery.
      {:ok, slice} = Ezagent.Kind.read(uri_str, :slow, spawn: :never)
      assert "during-post-init" in slice.msgs
    end

    # -----------------------------------------------------------------
    # Test 6 — codex round-3 HIGH-1 regression: per-target FIFO across
    # the not-ready → ready transition. With the round-3 fix in place
    # (`drain_then_mark_ready/1` flushes PendingDelivery BEFORE
    # mark_ready, looping until empty), older buffered entries are
    # ALWAYS in our mailbox before any external direct-cast that hits
    # `:ready`. The structural assertion below is that by the time
    # ReadyGate becomes `:ready` externally observable, the
    # PendingDelivery buffer for that URI is empty — i.e. there are
    # no "straggler" buffered entries that a post-ready dispatcher
    # could overtake by direct-casting.
    # -----------------------------------------------------------------
    test "PendingDelivery buffer is empty by the time ReadyGate is :ready",
         %{suffix: suffix} do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_fifo_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(SlowPostInitKind, :noop, SlowPostInitBehavior)

      # Pre-buffer multiple casts (they all land in PendingDelivery
      # because the URI doesn't exist yet → dispatch buffers).
      presenter = Ezagent.Entity.User.admin_uri()

      cap =
        signed_fixture_cap!(
          uri,
          SlowPostInitKind.type_name(),
          SlowPostInitBehavior,
          :noop,
          presenter
        )

      for n <- 1..3 do
        inv = %Ezagent.Invocation{
          origin: :trusted_internal,
          target: Ezagent.URI.with_action(uri, :test, :noop),
          mode: :cast,
          args: %{msg: "pre-ready-#{n}"},
          ctx: %{
            caller: presenter,
            authenticated_principal: presenter,
            caps: MapSet.new([cap]),
            reply: :ignore
          }
        }

        :ok = Ezagent.PendingDelivery.buffer(uri, inv)
      end

      assert Ezagent.PendingDelivery.buffer_size(uri) == 3

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({SlowPostInitKind, %{uri: uri, post_init_sleep_ms: 20}})

      # Wait until ReadyGate flips to :ready (post-init done, drain done).
      :ok = wait_until_ready(uri_str, 500)

      # Round-3 HIGH-1 invariant: PendingDelivery buffer is EMPTY at
      # the moment :ready is observable. Without the
      # drain-then-mark order this could be non-zero (entries that
      # arrived during the drain-flush window stayed buffered after
      # mark_ready, then would be overtaken by post-ready
      # direct-casts on the next dispatch).
      assert Ezagent.PendingDelivery.buffer_size(uri) == 0

      # Sanity: all 3 pre-buffered casts eventually applied to the
      # slice — proves the drain delivered them all (not just
      # cleared the buffer).
      :ok =
        wait_until(
          fn ->
            case Ezagent.Kind.read(uri_str, :slow, spawn: :never) do
              {:ok, %{msgs: msgs}} -> length(msgs) == 3
              _ -> false
            end
          end,
          500
        )

      {:ok, %{msgs: msgs}} = Ezagent.Kind.read(uri_str, :slow, spawn: :never)
      assert msgs == ["pre-ready-1", "pre-ready-2", "pre-ready-3"]
    end
  end

  # -------------------------------------------------------------------
  # Helpers — local copies of the wait_until_ready/2 pattern used by
  # `Ezagent.Kind.ServerTest`; kept inline so this file stays
  # self-contained.
  # -------------------------------------------------------------------

  defp wait_until_ready(uri, timeout_ms) do
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end, timeout_ms)
  end

  defp wait_until(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(check, deadline)
  end

  defp poll(check, deadline) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(5)
        poll(check, deadline)
      end
    end
  end
end
