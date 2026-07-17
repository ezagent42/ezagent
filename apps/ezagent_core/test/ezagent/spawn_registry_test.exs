defmodule Ezagent.SpawnRegistryTest do
  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.SpawnRegistry

  describe "register/2 + spawn/1" do
    test "unknown options fail closed" do
      uri = URI.parse("unknown-options-#{System.unique_integer([:positive])}://x")

      assert {:error, [:launch_context_typo]} =
               SpawnRegistry.spawn_detailed(uri, launch_context_typo: make_ref())
    end

    test "option-bearing spawn transports launch context unchanged to an arity-two registration" do
      test_pid = self()
      scheme = "spawnreg-opts-#{System.unique_integer([:positive])}"
      launch_context = make_ref()

      SpawnRegistry.register(scheme, fn uri, opts ->
        send(test_pid, {:spawn_called, uri, opts})
        {:ok, self()}
      end)

      uri = URI.parse("#{scheme}://x")

      assert {:ok, _pid} = SpawnRegistry.spawn(uri, launch_context: launch_context)
      assert_receive {:spawn_called, ^uri, [launch_context: ^launch_context]}
    end

    test "arity-one registration fails closed before invocation when launch context is present" do
      test_pid = self()
      scheme = "spawnreg-legacy-#{System.unique_integer([:positive])}"

      SpawnRegistry.register(scheme, fn uri ->
        send(test_pid, {:legacy_spawn_called, uri})
        {:ok, self()}
      end)

      uri = URI.parse("#{scheme}://x")

      assert {:error, :launch_context_unsupported} =
               SpawnRegistry.spawn_detailed(uri, launch_context: make_ref())

      refute_receive {:legacy_spawn_called, ^uri}
      assert {:ok, :started, _pid} = SpawnRegistry.spawn_detailed(uri)
      assert_receive {:legacy_spawn_called, ^uri}
    end

    test "registered spawn fn is invoked for matching scheme" do
      test_pid = self()
      scheme = "spawnreg-test-#{System.unique_integer([:positive])}"

      SpawnRegistry.register(scheme, fn uri ->
        send(test_pid, {:spawn_called, uri})
        {:ok, self()}
      end)

      uri = URI.parse("#{scheme}://x")
      assert {:ok, _pid} = SpawnRegistry.spawn(uri)
      assert_receive {:spawn_called, ^uri}
    end

    test "unknown scheme returns {:error, {:no_spawn_fn, scheme}}" do
      uri = URI.parse("nonesuch-scheme-#{System.unique_integer([:positive])}://x")
      assert {:error, {:no_spawn_fn, _}} = SpawnRegistry.spawn(uri)
    end

    test "spawn/1 returns existing pid if URI already registered in KindRegistry" do
      # Use admin user — guaranteed alive in test env via chat plugin Application
      uri = Ezagent.Entity.User.admin_uri()
      {:ok, existing_pid} = Ezagent.KindRegistry.lookup(uri)

      # Even though no "user" spawn fn might be registered (it is via chat
      # plugin, but doesn't matter here), the KindRegistry lookup short-
      # circuits before consulting SpawnRegistry.
      assert {:ok, ^existing_pid} = SpawnRegistry.spawn(uri)
    end

    test "registered_schemes/0 lists every registered scheme" do
      scheme = "list-test-#{System.unique_integer([:positive])}"
      SpawnRegistry.register(scheme, fn _ -> {:ok, self()} end)

      assert scheme in SpawnRegistry.registered_schemes()
    end
  end

  describe "{:already_started, pid} translation" do
    test "spawn/1 unwraps :already_started to {:ok, pid}" do
      scheme = "already-test-#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)

      SpawnRegistry.register(scheme, fn _uri -> {:error, {:already_started, fake_pid}} end)

      uri = URI.parse("#{scheme}://x")
      assert {:ok, ^fake_pid} = SpawnRegistry.spawn(uri)
    end
  end

  # codex round-6 HIGH-1 — `spawn_detailed/1` preserves the atomic
  # "this call won the start" signal that `spawn/1` collapses. It is
  # the ground truth `update_agent_template`'s swap derives `fresh?`
  # from — never a pre-probe (a pre-probe is a TOCTOU window).
  describe "spawn_detailed/1 — atomic started vs already_started" do
    test "a spawn fn returning {:ok, pid} is reported as :started" do
      scheme = "detailed-started-#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)
      SpawnRegistry.register(scheme, fn _uri -> {:ok, fake_pid} end)

      uri = URI.parse("#{scheme}://x")

      assert {:ok, :started, ^fake_pid} = SpawnRegistry.spawn_detailed(uri),
             "a fresh DynamicSupervisor start must be reported as :started"
    end

    test "a spawn fn returning {:error, {:already_started, pid}} is reported as :already_started" do
      scheme = "detailed-already-#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)
      SpawnRegistry.register(scheme, fn _uri -> {:error, {:already_started, fake_pid}} end)

      uri = URI.parse("#{scheme}://x")

      assert {:ok, :already_started, ^fake_pid} = SpawnRegistry.spawn_detailed(uri),
             "an already_started supervisor result must be reported as :already_started — " <>
               "the caller did NOT win the start"
    end

    test "a URI already live in KindRegistry is reported as :already_started" do
      uri = Ezagent.Entity.User.admin_uri()
      {:ok, existing_pid} = Ezagent.KindRegistry.lookup(uri)

      assert {:ok, :already_started, ^existing_pid} = SpawnRegistry.spawn_detailed(uri),
             "a KindRegistry lookup hit means the worker pre-existed — :already_started"
    end

    test "an unknown scheme returns {:error, {:no_spawn_fn, scheme}}" do
      uri = URI.parse("nonesuch-detailed-#{System.unique_integer([:positive])}://x")
      assert {:error, {:no_spawn_fn, _}} = SpawnRegistry.spawn_detailed(uri)
    end

    test "a spawn fn error propagates" do
      scheme = "detailed-err-#{System.unique_integer([:positive])}"
      SpawnRegistry.register(scheme, fn _uri -> {:error, :boom} end)

      uri = URI.parse("#{scheme}://x")
      assert {:error, :boom} = SpawnRegistry.spawn_detailed(uri)
    end
  end
end
