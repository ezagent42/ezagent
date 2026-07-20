defmodule Ezagent.InvocationDeathRaceTest do
  @moduledoc """
  Regression test for the Kind-death dispatch race (fix/readygate-death-race).

  ## The race

  A Kind can die in the window AFTER `ReadyGate.status == :ready` but
  BEFORE `KindRegistry` (a stdlib unique `Registry`) asynchronously reaps
  the dead pid on its monitor `:DOWN`. In that window:

    - `ReadyGate.status(uri) == :ready`, AND
    - `KindRegistry.lookup(uri)` either still returns the dead pid OR has
      already been reaped to `:error` (decided purely by Registry timing).

  Pre-fix, `Invocation.dispatch/1` gated on `:ready`, re-looked-up the
  pid, and did a RAW `GenServer.call(pid, …)` against the corpse → an
  uncaught `:noproc` EXIT (the recurring CI `(EXIT) no process` flake,
  surfaced as the `em3 subscribe_from` / DefaultSessionTemplateSeed /
  DB-ownership-churn intermittents).

  ## The fix (the half under test here)

  `Invocation.deliver_to_ready` now guards the call against a dead/missing
  target and falls through to the lazy-spawn-from-snapshot path
  (respawn-and-deliver) instead of crashing — for BOTH `:call` and
  `:cast`, and for BOTH sub-states (dead-pid-still-registered, reaped).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, SnapshotStore, SpawnRegistry, KindRegistry, ReadyGate}
  alias Ezagent.Test.{OnChangeTestKind, TestBehavior}

  @scheme "resource"

  setup do
    :ok = Ezagent.BehaviorRegistry.register(OnChangeTestKind, :noop, TestBehavior)

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
      Ezagent.URI.new!(
        "#{@scheme}://thing/team-alpha/drace-#{System.unique_integer([:positive])}"
      )

    {:ok, uri: uri, spawn_count_pid: spawn_count_pid}
  end

  # Seed a snapshot row so the respawn path has durable state to load
  # (a brutal kill never runs `:on_terminate`, so we cannot rely on the
  # killed Kind having persisted anything).
  defp seed_snapshot(uri, count) do
    {:ok, _} =
      SnapshotStore.write(uri, %{test: %{count: count, last_msg: "seed"}},
        kind_type: :test,
        workspace_uri: "workspace://system",
        version: 0
      )

    :ok
  end

  defp ctx do
    %{
      caller: Ezagent.URI.new!("entity://system/user/admin"),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
      reply: {:caller_inbox, self()}
    }
  end

  describe "deliver_to_ready guard — stale :ready gate, gone target" do
    # NOTE — why a "death-race" test does NOT kill a real process.
    #
    # The fix's externally-observable contract is: when the `:ready` gate
    # is STALE (says :ready but no live Kind backs the URI), a dispatch
    # must report the target is GONE (`:no_such_actor`) — NOT crash with
    # an uncaught `:noproc` EXIT (the original bug) and NOT RESURRECT the
    # target (the regression the coordinator caught: resurrecting broke
    # idempotent-terminate — a 2nd terminate on a gone agent must stay
    # `:no_such_actor`). We construct the stale-gate state DIRECTLY — a
    # snapshot row exists (so a respawn WOULD be possible, proving these
    # tests would catch any accidental resurrection) + force
    # `ReadyGate.put(:ready)` — rather than spawn+brutal-kill a real Kind
    # (which perturbs the shared ExUnit SQL sandbox owner under full-suite
    # contention, a harness-only artifact absent in production).
    #
    # The uncaught-`:noproc`-CRASH fix itself (sub-state a:
    # dead-pid-still-registered) is covered deterministically by the
    # `call_live_target/3` unit tests below — that catch is the real
    # crash regression test. The two tests here guard the SEMANTICS: gone
    # target → `:no_such_actor`, never resurrected.

    test ":call to a stale :ready gate returns :no_such_actor and does NOT resurrect the target",
         %{uri: uri} do
      # A snapshot row exists — so if the guard wrongly respawned, this
      # URI WOULD come back to life. The assertions below prove it does not.
      seed_snapshot(uri, 41)

      assert KindRegistry.lookup(uri) == :error
      :ok = ReadyGate.put(uri, :ready)

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      inv = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{msg: "after-death"},
        ctx: ctx()
      }

      # Gone target → :no_such_actor (same as the pre-existing missing-pid
      # path). Pre-fix sub-state (a) would have raised :noproc instead.
      assert {:error, :no_such_actor} = Invocation.dispatch(inv)

      # NOT resurrected — no live Kind, gate untouched by a phantom respawn.
      assert KindRegistry.lookup(uri) == :error
    end

    test ":cast to a stale :ready gate surfaces :no_such_actor (no silent drop, no resurrect)",
         %{uri: uri} do
      seed_snapshot(uri, 0)

      assert KindRegistry.lookup(uri) == :error
      :ok = ReadyGate.put(uri, :ready)

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")

      inv = %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{msg: "cast-after-death"},
        ctx: ctx()
      }

      # The cast is NOT silently dropped to a dead pid (invariant #9):
      # the missing/dead target is surfaced as :no_such_actor.
      assert {:error, :no_such_actor} = Invocation.dispatch(inv)

      # No respawned Kind ever ran the handler → no reply, no resurrection.
      refute_receive {:ezagent_reply, _}, 300
      assert KindRegistry.lookup(uri) == :error
    end
  end

  describe "call_live_target/3 (the discrimination line, in isolation)" do
    test "a killed pid yields :dead_target (no Registry/ReadyGate setup)" do
      {:ok, pid} = Agent.start(fn -> :ok end)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      assert Invocation.call_live_target(pid, :anything, 100) == :dead_target
    end

    test "a live target's normal reply is wrapped in {:ok, _}, never :dead_target" do
      {:ok, pid} = Agent.start(fn -> 7 end)
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      # Agent implements GenServer; a get returns the value normally.
      assert {:ok, 7} = Invocation.call_live_target(pid, {:get, & &1}, 1_000)
    end

    test "a :timeout EXIT propagates (alive-but-slow is NOT a dead target)" do
      {:ok, pid} =
        Agent.start(fn -> :ok end)

      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      # A 0ms timeout forces a :timeout EXIT; it must NOT be swallowed
      # as :dead_target — re-dispatching an alive-but-slow target would
      # mask a genuinely stuck handler.
      assert catch_exit(Invocation.call_live_target(pid, {:get, &Function.identity/1}, 0))
    end
  end
end
