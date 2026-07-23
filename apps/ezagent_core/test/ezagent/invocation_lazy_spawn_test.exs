defmodule Ezagent.InvocationLazySpawnTest do
  @moduledoc """
  Regression test for codex E2E fix v2 Bug B (2026-05-29).

  ## Scenario

  A Kind that lived long enough to write a `kind_snapshots` row has
  been reaped (or the BEAM restarted) — KindRegistry is empty,
  ReadyGate.status returns `:unknown`. Pre-fix, `Invocation.dispatch/1`
  returned `{:error, :no_such_actor}` for ANY dispatch against this
  URI, even though the snapshot row was right there in the DB. Only
  `Ezagent.ExternalMirror.BootReconciler` rehydrated Kinds at app
  boot — Agent / Session / Workspace / ... were invisible.

  ## Fix

  `Invocation.dispatch/1` now intercepts the `:unknown`-status case:

  1. Asks `StateRebuilder.snapshot_exists?/1` whether a row exists.
  2. If yes, calls `SpawnRegistry.spawn/1`. The plugin's registered
     spawn fn routes through `Kind.spawn/2` → `Kind.Server.init/1` →
     `Snapshot.load_or_init/3` which loads the snapshot.
  3. Re-checks ReadyGate and proceeds (for `:call` mode, awaits a
     bounded window first since the spawn just started + post_init
     is running).

  ## Failure mode preservation

  - "No snapshot AND no live Kind" still returns `:no_such_actor`
    (the URI is genuinely non-existent).
  - A spawn-fn failure (plugin not loaded, supervisor down) ALSO
    returns `:no_such_actor` — telemetry surfaces the actual reason
    for ops to diagnose, but the caller-visible shape stays the same
    so callers' error-handling logic is unchanged.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, SnapshotStore, SpawnRegistry, KindRegistry, ReadyGate}
  alias Ezagent.Test.{OnChangeTestKind, TestBehavior}

  # `resource` is one of the four unified-per-tenant schemes
  # (`Ezagent.URI.instance/1` preserves a 3-segment path for them);
  # other schemes drop the path during instance derivation, which
  # would collapse multiple test URIs to the same lookup key. No
  # production code registers a spawn fn for `resource://` so our
  # per-test registration is collision-free.
  @scheme "resource"

  setup do
    # Register Behavior so dispatch can resolve the handler.
    :ok = Ezagent.BehaviorRegistry.register(OnChangeTestKind, :noop, TestBehavior)

    # Register a per-test spawn fn that routes to
    # `Kind.spawn(OnChangeTestKind, %{uri: uri})`. The Agent counts how
    # many times the fn was invoked so we can assert the lazy-spawn
    # path didn't re-spawn an already-alive Kind.
    {:ok, spawn_count_pid} = Agent.start_link(fn -> 0 end)

    spawn_fn = fn uri ->
      Agent.update(spawn_count_pid, &(&1 + 1))
      Ezagent.Kind.spawn(OnChangeTestKind, %{uri: uri})
    end

    :ok = SpawnRegistry.register(@scheme, spawn_fn)

    on_exit(fn ->
      try do
        Agent.stop(spawn_count_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    uri =
      Ezagent.URI.new!("#{@scheme}://thing/team-alpha/lazy-#{System.unique_integer([:positive])}")

    {:ok, uri: uri, spawn_count_pid: spawn_count_pid}
  end

  describe ":unknown URI + snapshot exists → cold-spawn-from-snapshot" do
    test "the dispatch succeeds after lazy-spawning from snapshot",
         %{uri: uri, spawn_count_pid: counter} do
      # 1. Pre-seed a snapshot row for `uri` so it looks like a Kind
      #    that lived in a prior BEAM session.
      slice_state = %{test: %{count: 99, last_msg: "from-snapshot"}}

      {:ok, _} =
        SnapshotStore.write(uri, slice_state,
          kind_type: :test,
          workspace_uri: "workspace://system",
          # `OnChangeTestKind` doesn't declare `snapshot_version/0` so
          # the default `0` is enforced by `check_version/2`. Match it.
          version: 0
        )

      # 2. Sanity — the URI is NOT in KindRegistry and ReadyGate
      #    returns :unknown. This is the pristine restart state.
      assert KindRegistry.lookup(uri) == :error
      assert ReadyGate.status(uri) == :unknown

      # 3. Dispatch. Pre-fix this returned `{:error, :no_such_actor}`.
      #    Post-fix it triggers the lazy spawn + retry.
      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      inv = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{msg: "lazy-spawn-test"},
        ctx: signed_ctx(uri)
      }

      assert {:ok, %{echoed: "lazy-spawn-test"}} = Invocation.dispatch(inv)

      # 4. The spawn fn was invoked exactly once.
      assert Agent.get(counter, & &1) == 1

      # 5. After the dispatch the Kind is alive in KindRegistry +
      #    ReadyGate flipped to :ready.
      assert {:ok, _pid} = KindRegistry.lookup(uri)
      assert ReadyGate.status(uri) == :ready

      # 6. The snapshot state was actually loaded — the `count` is 99
      #    (from the seeded snapshot), not 0 (a fresh init would
      #    have started at 0; the dispatch then incremented to 100,
      #    not 1).
      assert {:ok, test_slice} = Ezagent.Kind.get_slice(uri, :test)
      assert test_slice.count == 100
      assert test_slice.last_msg == "lazy-spawn-test"
    end

    test "second dispatch (Kind already alive) does NOT re-spawn",
         %{uri: uri, spawn_count_pid: counter} do
      slice_state = %{test: %{count: 0, last_msg: nil}}

      {:ok, _} =
        SnapshotStore.write(uri, slice_state,
          kind_type: :test,
          workspace_uri: "workspace://system",
          version: 0
        )

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      ctx = signed_ctx(uri)

      # First dispatch lazy-spawns.
      assert {:ok, _} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{msg: "a"},
                 ctx: ctx
               })

      assert Agent.get(counter, & &1) == 1

      # Second dispatch hits :ready directly — no second spawn.
      assert {:ok, _} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{msg: "b"},
                 ctx: ctx
               })

      assert Agent.get(counter, & &1) == 1
    end

    test ":cast mode also lazy-spawns and delivers", %{uri: uri} do
      slice_state = %{test: %{count: 0, last_msg: nil}}

      {:ok, _} =
        SnapshotStore.write(uri, slice_state,
          kind_type: :test,
          workspace_uri: "workspace://system",
          version: 0
        )

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      inv = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{msg: "cast-lazy"},
        ctx: signed_ctx(uri)
      }

      assert :ok = Invocation.dispatch(inv)

      # The cast may buffer to PendingDelivery (if the Kind is still
      # :not_ready when dispatch returns) or be delivered directly
      # (if post_init had already completed by the time the cast
      # hit). Either way the receiving Kind eventually replies.
      assert_receive {:ezagent_reply, {:ok, %{echoed: "cast-lazy"}}}, 2_000
    end
  end

  describe ":unknown URI + NO snapshot → legacy :no_such_actor" do
    test "returns :no_such_actor when the URI was never persisted", %{uri: uri} do
      # NO write — the URI is truly never-seen.
      assert KindRegistry.lookup(uri) == :error
      assert ReadyGate.status(uri) == :unknown

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      inv = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{msg: "x"},
        ctx: signed_ctx(uri)
      }

      assert {:error, :no_such_actor} = Invocation.dispatch(inv)

      # Critical — the spawn fn was NOT invoked. We don't speculatively
      # spawn against URIs without snapshot evidence (would surprise
      # the caller for non-persistent test URIs + waste a supervisor
      # slot per bogus dispatch).
      assert KindRegistry.lookup(uri) == :error
    end
  end

  defp signed_ctx(uri) do
    presenter = Ezagent.URI.user(:system, :admin)
    cap = signed_fixture_cap!(uri, :test, TestBehavior, :noop, presenter)

    %{
      caller: presenter,
      authenticated_principal: presenter,
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end
end
