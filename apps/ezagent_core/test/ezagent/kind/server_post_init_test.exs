defmodule Ezagent.Kind.ServerPostInitTest do
  @moduledoc """
  PR-EM-CORE acceptance tests — verify `Ezagent.Kind.Server` chains
  post-init continuations AFTER `:announce_ready` and preserves the
  pre-PR behaviour for Kinds whose Behaviors do not declare
  `post_init/2`.

  See ExternalMirror SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-CORE for the requirements driving this test.
  """

  use ExUnit.Case, async: true

  alias Ezagent.TestSupport.{
    MultiPostInitKind,
    NoPostInitBehavior,
    NoPostInitKind,
    OrderTracker,
    PostInitBehavior,
    PostInitBehaviorA,
    PostInitBehaviorB,
    PostInitKind
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
    test "runs handle_continue/3 AFTER :announce_ready and merges new slice back",
         %{tracker: tracker, suffix: suffix} do
      uri = URI.parse("entity://agent/default/test_post_init-#{suffix}")
      uri_str = URI.to_string(uri)

      :ok = Ezagent.BehaviorRegistry.register(PostInitKind, :noop, PostInitBehavior)

      {:ok, pid} =
        Ezagent.Kind.Server.start_link({PostInitKind, %{uri: uri, tracker: tracker}})

      # 1. announce_ready ran — KindRegistry has the URI and ReadyGate is :ready.
      :ok = wait_until_ready(uri_str, 500)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri_str)
      assert :ready = Ezagent.ReadyGate.status(uri_str)

      # 2. post_init handle_continue/3 ran — wait for it to finish writing back.
      :ok = wait_until(fn -> OrderTracker.events(tracker) != [] end, 500)

      # 3. Slice has the post-init mutation merged back via Kind.Server.
      {:ok, slice} = Ezagent.Kind.get_slice(uri_str, :post_init_behavior)
      assert slice.setup_done == true
      assert slice.continued_with == :setup_thing

      # 4. Boot-order invariant: at the moment handle_continue/3 ran,
      #    ReadyGate was already :ready — i.e. :announce_ready ran first.
      assert [{:post_init, :ready}] = OrderTracker.events(tracker)
    end

    # -----------------------------------------------------------------
    # Test 2 — backwards-compat: a Behavior with NO post_init/2
    # boots normally with no extra continuation noise.
    # -----------------------------------------------------------------
    test "Behavior without post_init/2 boots unchanged (backwards-compat)",
         %{suffix: suffix} do
      uri = URI.parse("entity://agent/default/test_no_post_init-#{suffix}")
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
      {:ok, slice} = Ezagent.Kind.get_slice(uri_str, :no_post_init)
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
      uri = URI.parse("entity://agent/default/test_multi_post_init-#{suffix}")
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
      {:ok, slice_a} = Ezagent.Kind.get_slice(uri_str, :post_init_a)
      {:ok, slice_b} = Ezagent.Kind.get_slice(uri_str, :post_init_b)
      assert slice_a.ran == true
      assert slice_b.ran == true
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
