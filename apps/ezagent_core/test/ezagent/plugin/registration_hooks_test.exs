defmodule Ezagent.Plugin.RegistrationHooksTest do
  @moduledoc """
  Unit tests for `Ezagent.Plugin.RegistrationHooks` — the GenServer
  backing `Ezagent.Plugin.publish_after_all_registered/2`.

  SPEC `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` §5.

  These tests use stub registries whose `lookup/1` consults a per-test
  Agent so we can deterministically flip "registered" state without
  touching real ExternalMirror registries.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Plugin.RegistrationHooks

  defmodule StubRegistryA do
    def start_state, do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
    def set(key), do: Agent.update(__MODULE__, &MapSet.put(&1, key))

    def lookup(key),
      do: if(Agent.get(__MODULE__, &MapSet.member?(&1, key)), do: {:ok, key}, else: :error)
  end

  defmodule StubRegistryB do
    def start_state, do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
    def set(key), do: Agent.update(__MODULE__, &MapSet.put(&1, key))

    def lookup(key),
      do: if(Agent.get(__MODULE__, &MapSet.member?(&1, key)), do: {:ok, key}, else: :error)
  end

  setup do
    # Each test starts with fresh stub state + cleared hooks table.
    # Defensive Agent.stop — between Process.whereis returning a pid
    # and Agent.stop running, the pid may exit (race with concurrent
    # cleanup or supervisor activity). Catch the :noproc exit so
    # cleanup doesn't surface as a test failure unrelated to the
    # test body.
    on_exit(fn ->
      safe_stop_agent(StubRegistryA)
      safe_stop_agent(StubRegistryB)
    end)

    {:ok, _} = StubRegistryA.start_state()
    {:ok, _} = StubRegistryB.start_state()
    :ok = RegistrationHooks.__clear_all__()
    :ok
  end

  defp safe_stop_agent(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  test "fires synchronously when all registries already have the key" do
    StubRegistryA.set("ada")
    StubRegistryB.set("ada")

    me = self()
    ref = make_ref()

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "ada"}, {StubRegistryB, "ada"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    # Synchronous fire — message already in mailbox before assert_receive.
    assert_receive {:fired, ^ref}, 100
  end

  test "defers fire until the second registry lands" do
    StubRegistryA.set("ada")
    # B not yet set

    me = self()
    ref = make_ref()

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "ada"}, {StubRegistryB, "ada"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    refute_receive {:fired, ^ref}, 50

    StubRegistryB.set("ada")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "ada")

    assert_receive {:fired, ^ref}, 100
  end

  test "fires exactly once even if notify_subscribers is called twice for the same key" do
    StubRegistryA.set("ada")

    me = self()
    ref = make_ref()

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "ada"}, {StubRegistryB, "ada"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    StubRegistryB.set("ada")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "ada")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "ada")

    assert_receive {:fired, ^ref}, 100
    refute_receive {:fired, ^ref}, 50
  end

  test "does not fire for unrelated notify_subscribers calls" do
    # Hook waits on adapter_id="ada"; we'll notify for "bob".
    me = self()
    ref = make_ref()

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "ada"}, {StubRegistryB, "ada"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    StubRegistryA.set("bob")
    StubRegistryB.set("bob")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryA, "bob")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "bob")

    refute_receive {:fired, ^ref}, 100
  end

  test "buggy hook fn does not crash the GenServer (logs + isolates)" do
    StubRegistryA.set("ada")
    StubRegistryB.set("ada")

    pid_before = Process.whereis(RegistrationHooks)
    assert is_pid(pid_before)

    # Hook raises — the GenServer must survive.
    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "ada"}, {StubRegistryB, "ada"}],
        fn -> raise "boom" end
      )

    # Sanity: a normal call after the crash still works → GenServer
    # didn't die.
    me = self()
    ref = make_ref()

    StubRegistryA.set("bob")
    StubRegistryB.set("bob")

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "bob"}, {StubRegistryB, "bob"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    assert_receive {:fired, ^ref}, 100
    assert Process.whereis(RegistrationHooks) == pid_before
  end

  # codex PR-AUDIT r3 HIGH regression — exit/throw isolation
  #
  # Pre-fix, `safe_fire/1` only used `rescue`, catching raised
  # exceptions but NOT `exit/1`. A hook that calls `exit(:boom)` OR
  # a hook performing a `GenServer.call/2` where the callee dies
  # (which propagates as `:exit` to the caller) would bypass
  # `rescue`, exit the GenServer, and destroy EVERY queued hook.
  # Post-fix `catch :exit, _` + `catch :throw, _` are also caught.
  test "hook exit does not crash the GenServer (codex r3 HIGH gate)" do
    StubRegistryA.set("exit-ada")
    StubRegistryB.set("exit-ada")

    pid_before = Process.whereis(RegistrationHooks)
    assert is_pid(pid_before)

    # Also pre-queue a deferred hook so the assertion that it
    # later fires proves the GenServer survived the exit AND the
    # ETS pending-table is intact.
    me = self()
    pending_ref = make_ref()

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "exit-survives"}, {StubRegistryB, "exit-survives"}],
        fn ->
          send(me, {:pending_fired, pending_ref})
          :ok
        end
      )

    # Hook exits — the GenServer must survive AND the pending hook
    # above must remain in the table.
    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "exit-ada"}, {StubRegistryB, "exit-ada"}],
        fn -> exit(:boom) end
      )

    # Sanity: GenServer still alive (same pid).
    assert Process.whereis(RegistrationHooks) == pid_before

    # Pending hook still fires when its registries complete.
    StubRegistryA.set("exit-survives")
    StubRegistryB.set("exit-survives")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "exit-survives")

    assert_receive {:pending_fired, ^pending_ref}, 100
    assert Process.whereis(RegistrationHooks) == pid_before
  end

  # codex PR-AUDIT r4 HIGH regression — `:private` ETS denies external reads
  #
  # Pre-fix, the hooks table was `:protected` — any in-VM process could
  # `:ets.lookup/2` or `:ets.tab2list/1` to extract a pending hook
  # closure and call it directly, bypassing both the all_registered?
  # gate AND the safe_fire/1 isolation. Hook closures often perform
  # privileged work (cap subject registration, persisted-binding
  # reconciliation); exposing them outside the GenServer breaks the
  # once-after-all-registered contract.
  #
  # Post-fix, `:private` denies all non-owner reads + writes. The
  # caller process (this test pid) is not the table owner.
  test "hooks ETS table is :private — non-owner reads raise ArgumentError (codex r4 HIGH gate)" do
    me = self()
    ref = make_ref()

    # Queue a deferred hook so the table has a non-counter row.
    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "private-r4"}, {StubRegistryB, "private-r4"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    # Non-owner read attempt → BEAM raises ArgumentError on a `:private`
    # named table from a non-owner pid.
    assert_raise ArgumentError, fn ->
      :ets.tab2list(:ezagent_plugin_registration_hooks)
    end

    assert_raise ArgumentError, fn ->
      :ets.lookup(:ezagent_plugin_registration_hooks, 1)
    end

    # Pending hook still works via the normal path (GenServer-mediated).
    StubRegistryA.set("private-r4")
    StubRegistryB.set("private-r4")
    :ok = RegistrationHooks.notify_subscribers(StubRegistryB, "private-r4")
    assert_receive {:fired, ^ref}, 100
  end

  test "hook throw does not crash the GenServer" do
    StubRegistryA.set("throw-ada")
    StubRegistryB.set("throw-ada")

    pid_before = Process.whereis(RegistrationHooks)
    assert is_pid(pid_before)

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "throw-ada"}, {StubRegistryB, "throw-ada"}],
        fn -> throw(:boom) end
      )

    # GenServer survives.
    assert Process.whereis(RegistrationHooks) == pid_before

    # Sanity: a normal call after the throw still works.
    me = self()
    ref = make_ref()
    StubRegistryA.set("throw-bob")
    StubRegistryB.set("throw-bob")

    :ok =
      RegistrationHooks.publish_after_all_registered(
        [{StubRegistryA, "throw-bob"}, {StubRegistryB, "throw-bob"}],
        fn ->
          send(me, {:fired, ref})
          :ok
        end
      )

    assert_receive {:fired, ^ref}, 100
    assert Process.whereis(RegistrationHooks) == pid_before
  end
end
