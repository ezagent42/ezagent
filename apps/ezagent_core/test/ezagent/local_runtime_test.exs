defmodule Ezagent.LocalRuntimeTest do
  @moduledoc """
  Unit tests for the owner-gated plugin runtime facade (#95).

  The decentralization behavior (non-owner runtime) is the whole point, so it is
  exercised here by overriding the `WorkspacePlacement` resolver — the only way to
  simulate a multi-node owner split from a single node. We register the test
  process itself in `KindRegistry` (auto-unregistered when the test process exits)
  to make a URI "alive" without a full Kind spawn; `SpawnRegistry.spawn_detailed`
  reports an already-registered URI as `:already_started`, which lets us prove the
  `ensure_*` delegation too.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{KindRegistry, LocalRuntime, RuntimeIdentity, SpawnRegistry, WorkspacePlacement}

  defmodule RemoteResolver do
    @behaviour Ezagent.WorkspacePlacement
    @impl true
    def owner_of(%URI{scheme: "workspace"}), do: {:ok, "remote-node"}
  end

  setup do
    prev_identity = Application.get_env(:ezagent_core, RuntimeIdentity)
    prev_placement = Application.get_env(:ezagent_core, WorkspacePlacement)
    Application.put_env(:ezagent_core, RuntimeIdentity, runtime_id: "test-node-a")

    on_exit(fn ->
      restore(RuntimeIdentity, prev_identity)
      restore(WorkspacePlacement, prev_placement)
    end)

    uniq = System.unique_integer([:positive])
    {:ok, uri: Ezagent.URI.new!("entity://team-alpha/agent/lr-test-#{uniq}")}
  end

  defp restore(key, nil), do: Application.delete_env(:ezagent_core, key)
  defp restore(key, val), do: Application.put_env(:ezagent_core, key, val)

  describe "single-node (default local owner)" do
    test "ensure_started_detailed/2 delegates launch context unchanged" do
      test_pid = self()
      scheme = "local-runtime-opts-#{System.unique_integer([:positive])}"
      launch_context = make_ref()

      SpawnRegistry.register(scheme, fn uri, opts ->
        send(test_pid, {:local_runtime_spawn, uri, opts})
        {:ok, self()}
      end)

      uri = URI.parse("#{scheme}://x")

      assert {:ok, :started, _pid} =
               LocalRuntime.ensure_started_detailed(uri, launch_context: launch_context)

      assert_receive {:local_runtime_spawn, ^uri, [launch_context: ^launch_context]}
    end

    test "kind_alive?/1 is false for an unregistered URI (gate passes, lookup empty)", %{uri: uri} do
      refute LocalRuntime.kind_alive?(uri)
    end

    test "kind_alive?/1 is true once the Kind is live", %{uri: uri} do
      :ok = KindRegistry.put_new(uri, self())
      assert LocalRuntime.kind_alive?(uri)
    end

    test "ensure_started_detailed/1 delegates to SpawnRegistry (already-live → :already_started)",
         %{uri: uri} do
      :ok = KindRegistry.put_new(uri, self())
      assert {:ok, :already_started, pid} = LocalRuntime.ensure_started_detailed(uri)
      assert pid == self()
      assert {:ok, ^pid} = LocalRuntime.ensure_started(uri)
    end
  end

  describe "non-owner runtime (decentralization — RemoteResolver, enforce mode)" do
    setup do
      Application.put_env(:ezagent_core, WorkspacePlacement, resolver: RemoteResolver)
      :ok
    end

    test "kind_alive?/1 is false via the GATE even when the Kind is locally live", %{uri: uri} do
      # Register a live pid locally; the gate must short-circuit BEFORE the lookup
      # so a non-owner runtime never reports a foreign-owned Kind as alive here.
      :ok = KindRegistry.put_new(uri, self())
      refute LocalRuntime.kind_alive?(uri)
    end

    test "ensure_started/1 refuses to spawn a foreign-owned agent (gate error)", %{uri: uri} do
      assert {:error, {:not_workspace_owner, _ws, "remote-node", "test-node-a", {:spawn, _}}} =
               LocalRuntime.ensure_started(uri)
    end

    test "ensure_started_detailed/1 also returns the gate error, never spawns", %{uri: uri} do
      assert {:error, {:not_workspace_owner, _ws, "remote-node", "test-node-a", {:spawn, _}}} =
               LocalRuntime.ensure_started_detailed(uri)
    end

    test "ensure_started_detailed/2 preserves the owner-gate error", %{uri: uri} do
      assert {:error, {:not_workspace_owner, _ws, "remote-node", "test-node-a", {:spawn, _}}} =
               LocalRuntime.ensure_started_detailed(uri, launch_context: make_ref())
    end
  end
end
