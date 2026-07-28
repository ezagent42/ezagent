defmodule Ezagent.SpawnReceiptTest do
  @moduledoc """
  #201 PR-1 — the core-issued creation receipt: `{:started | :already_started,
  created?}` surfaced synchronously out of the spawn path.

  Pins the two DISTINCT ownership signals:

    * `:started` / `:already_started` — the atomic `DynamicSupervisor` winner
      verdict (did THIS call win the process start).
    * `created?` — the Lifecycle-owned logical-create verdict (durable
      `ever_created` marker absent at `Kind.Server.init`), read back from the
      winner's own process.

  The load-bearing case is the third test: a COLD, durably pre-existing Kind
  re-spawned after its process died wins `:started` but is NOT `created?` —
  a duplicate-create attempt against it must not re-run create-only side
  effects (credential grant mint / materialization).
  """

  use Ezagent.LifecycleCase

  # Cross-tier suite (spawns real Kinds under the gate supervisor).
  @moduletag :umbrella_only

  alias Ezagent.TestSupport.LifecycleFixtureKind

  defp fixture_uri do
    URI.new!("system://lifecycle_fixture/receipt-#{System.unique_integer([:positive])}")
  end

  defp stop_kind(uri) do
    _ = Ezagent.Kind.terminate(uri)
    wait_until(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)
  end

  describe "Ezagent.Kind.spawn_receipt/3" do
    test "a fresh logical create reports {:started, created?: true}" do
      uri = fixture_uri()

      assert {:ok, :started, pid, %{created?: true}} =
               Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri)
      stop_kind(uri)
    end

    test "a concurrent/second spawn of a LIVE Kind reports {:already_started, created?: false}" do
      uri = fixture_uri()

      assert {:ok, :started, pid, %{created?: true}} =
               Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

      assert {:ok, :already_started, ^pid, %{created?: false}} =
               Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

      stop_kind(uri)
    end

    test "a cold durably-pre-existing Kind wins :started but is NOT created?" do
      uri = fixture_uri()

      # First-ever spawn: genuine logical create.
      assert {:ok, :started, _pid, %{created?: true}} =
               Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

      # Go cold: kill the process (the durable snapshot + ever_created marker
      # survive — this is the rehydrate case, NOT a destroy).
      stop_kind(uri)

      # Re-spawn: THIS call wins the atomic start, but the marker verdict says
      # the Kind was logically created before — created? MUST be false.
      assert {:ok, :started, new_pid, %{created?: false}} =
               Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

      assert {:ok, ^new_pid} = Ezagent.KindRegistry.lookup(uri)
      stop_kind(uri)
    end

    test "create_freshness/2 is fail-conservative for a never-spawned URI" do
      uri = fixture_uri()
      assert Ezagent.Kind.create_freshness(uri, self()) == :unknown
    end
  end

  describe "Ezagent.SpawnRegistry.spawn_receipt/2" do
    test "surfaces :started + created? from the registered spawn fn's Kind" do
      scheme = "receipt-reg-#{System.unique_integer([:positive])}"
      kind_uri = Ezagent.URI.new!("system://lifecycle_fixture/#{scheme}")

      Ezagent.SpawnRegistry.register(scheme, fn _uri ->
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: kind_uri})
      end)

      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :started, pid, %{created?: true}} = Ezagent.SpawnRegistry.spawn_receipt(uri)

      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(kind_uri)
      stop_kind(kind_uri)
    end

    test "a cold durably-pre-existing Kind re-spawned via the registry is NOT created?" do
      scheme = "receipt-cold-#{System.unique_integer([:positive])}"
      kind_uri = Ezagent.URI.new!("system://lifecycle_fixture/#{scheme}")

      Ezagent.SpawnRegistry.register(scheme, fn _uri ->
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: kind_uri})
      end)

      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :started, _pid, %{created?: true}} = Ezagent.SpawnRegistry.spawn_receipt(uri)

      stop_kind(kind_uri)

      assert {:ok, :started, _new_pid, %{created?: false}} =
               Ezagent.SpawnRegistry.spawn_receipt(uri)

      stop_kind(kind_uri)
    end

    test ":already_started from the spawn fn maps to created?: false" do
      scheme = "receipt-adopt-#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)

      Ezagent.SpawnRegistry.register(scheme, fn _uri ->
        {:error, {:already_started, fake_pid}}
      end)

      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :already_started, ^fake_pid, %{created?: false}} =
               Ezagent.SpawnRegistry.spawn_receipt(uri)
    end

    test "created? is fail-conservative when the spawn fn's pid cannot answer" do
      scheme = "receipt-dead-#{System.unique_integer([:positive])}"

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      Ezagent.SpawnRegistry.register(scheme, fn _uri -> {:ok, dead} end)
      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :started, ^dead, %{created?: false}} =
               Ezagent.SpawnRegistry.spawn_receipt(uri)
    end

    test "spawn_detailed/2 keeps its 3-tuple contract" do
      scheme = "receipt-legacy-#{System.unique_integer([:positive])}"
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)

      Ezagent.SpawnRegistry.register(scheme, fn _uri -> {:ok, fake_pid} end)
      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :started, ^fake_pid} = Ezagent.SpawnRegistry.spawn_detailed(uri)
    end
  end

  describe "Ezagent.LocalRuntime.ensure_started_receipt/2" do
    test "delegates to the owner-gated registry receipt" do
      scheme = "receipt-facade-#{System.unique_integer([:positive])}"
      kind_uri = Ezagent.URI.new!("system://lifecycle_fixture/#{scheme}")

      Ezagent.SpawnRegistry.register(scheme, fn _uri ->
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: kind_uri})
      end)

      uri = Ezagent.URI.new!("#{scheme}://x")

      assert {:ok, :started, _pid, %{created?: true}} =
               Ezagent.LocalRuntime.ensure_started_receipt(uri)

      stop_kind(kind_uri)
    end
  end
end
