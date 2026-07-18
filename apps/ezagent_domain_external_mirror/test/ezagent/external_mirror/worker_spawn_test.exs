defmodule Ezagent.ExternalMirror.WorkerSpawnTest do
  @moduledoc """
  PR-EM-2 acceptance tests for the Worker spawn path + two-tier
  supervisor topology + Registry-keyed idempotency.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-2 acceptance bar (tests 3 + 4 below; the publish-flow
  + isolation + restart tests live in
  `worker_publish_test.exs`).

  Tests in this file:

  - **#3 — two-tier shape invariant (r5 HIGH-2)**:
    `Supervisor.which_children(RootSupervisor)` returns only
    `Supervisor`-typed children (PerBindingSupervisors), each of
    which has exactly one `Kind.Server` inner child.
  - **#4 — idempotency regression (r5 HIGH-3)**: 10 concurrent
    `WorkerSpawn.spawn/4` for the same triple → exactly 1 Worker
    in the Registry; 9 callers got `{:error, {:already_started, _}}`.
  - **URI shape (§7.2)** — `worker_uri_for/3` is deterministic for
    a given triple.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{
    RootSupervisor,
    WorkerRegistry,
    WorkerSpawn
  }

  alias Ezagent.ExternalMirror.TestSupport.{MockPublishAdapter, MockPublishBinding}

  setup do
    # Ensure the registries the Worker uses are populated; clean
    # PerBindingSupervisor + WorkerRegistry residue from prior tests.
    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    # The Worker subscribes to the Session Publisher in its
    # `handle_continue(:subscribe_and_init, ...)` callback (SPEC §6.1).
    # The test env's `EzagentDomainInstanceMessage.Application.start/2` seeds
    # `session://system/default/main`; we use that as the Publisher
    # for these tests so subscribe succeeds.
    session_uri = Ezagent.URI.new!("session://system/default/main")

    on_exit(fn -> cleanup_workers() end)

    {:ok, session_uri: session_uri}
  end

  describe "worker_uri_for/3 (SPEC §7.2)" do
    test "is deterministic for the same triple" do
      session_uri = Ezagent.URI.new!("session://wsA/default/main")
      a = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-1")
      b = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-1")
      assert URI.to_string(a) == URI.to_string(b)
    end

    test "yields different URIs for different targets" do
      session_uri = Ezagent.URI.new!("session://wsA/default/main")
      a = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-1")
      b = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-2")
      refute URI.to_string(a) == URI.to_string(b)
    end

    test "encodes workspace from session URI workspace segment" do
      session_uri = Ezagent.URI.new!("session://wsB/default/main")
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-1")

      assert worker_uri.scheme == "entity"
      assert worker_uri.host == "wsB"
      assert Ezagent.URI.type?(worker_uri, :worker)
      assert String.starts_with?(worker_uri.path, "/worker/em_")
    end

    test "raises on a 2-segment session URI (workspace missing)" do
      # Construct via concatenation to bypass the
      # `AllPerTenantURIsHaveWorkspaceTest` grep gate per its
      # documented escape (test/invariants/all_per_tenant_uris_have_workspace_test.exs:138-143).
      legacy = "session://default/" <> "main"

      assert_raise ArgumentError, fn ->
        WorkerSpawn.worker_uri_for(URI.parse(legacy), "mock", "tgt")
      end
    end
  end

  describe "spawn/4 — single binding" do
    test "spawns a PerBindingSupervisor under RootSupervisor + a Kind.Server inside",
         %{session_uri: session_uri} do
      target_id = "tgt-spawn-1"
      MockPublishBinding.register_observer(target_id, self())

      assert {:ok, sup_pid} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)

      # The returned pid IS a PerBindingSupervisor — recursively a Supervisor.
      assert is_pid(sup_pid)
      assert Process.alive?(sup_pid)

      # WorkerRegistry holds the binding_uri -> sup_pid mapping.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      binding_uri = URI.to_string(worker_uri)
      assert {:ok, ^sup_pid} = WorkerRegistry.lookup(binding_uri)
    end
  end

  describe "two-tier shape invariant (PR-EM-2 acceptance test #3 / r5 HIGH-2)" do
    test "RootSupervisor's children are all PerBindingSupervisors; each has exactly one Kind.Server",
         %{session_uri: session_uri} do
      Enum.each(1..3, fn n ->
        target_id = "tgt-tier-#{n}"
        MockPublishBinding.register_observer(target_id, self())
        {:ok, _} = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
      end)

      # Wait briefly for post_init to complete on all 3 (so their
      # PerBindingSupervisor subtrees are fully populated). Without
      # this, `which_children` may race against the inner Kind.Server
      # spawn and return early.
      Process.sleep(50)

      children = DynamicSupervisor.which_children(RootSupervisor)
      assert length(children) >= 3

      Enum.each(children, fn {_id, child_pid, type, _modules} ->
        # Direct children of RootSupervisor MUST be supervisors, NOT
        # plain Kind.Server workers. This is the architectural
        # invariant — a regression to a flat shared supervisor
        # would have `:worker` here.
        assert type == :supervisor,
               "RootSupervisor child #{inspect(child_pid)} is type #{inspect(type)}; " <>
                 "expected :supervisor (per SPEC §6.3 two-tier topology — " <>
                 "r5 HIGH-2 regression). A :worker child means the topology " <>
                 "flattened back to round-3's broken shared-supervisor shape."

        # Each per-binding supervisor owns EXACTLY one Kind.Server child.
        inner_children = Supervisor.which_children(child_pid)
        assert length(inner_children) == 1

        [{_id, _inner_pid, inner_type, inner_modules}] = inner_children
        assert inner_type == :worker

        assert Ezagent.Kind.Server in inner_modules,
               "PerBindingSupervisor inner child modules #{inspect(inner_modules)} " <>
                 "does not include Ezagent.Kind.Server (per SPEC §6.3 — the Worker " <>
                 "Kind MUST be hosted by the standard Kind.Server)."
      end)
    end
  end

  describe "idempotency regression (PR-EM-2 acceptance test #4 / r5 HIGH-3)" do
    test "10 concurrent spawns for same triple → exactly 1 Worker; 9 already_started",
         %{session_uri: session_uri} do
      target_id = "tgt-concurrent"
      MockPublishBinding.register_observer(target_id, self())

      # Build the binding_uri up-front so we can count WorkerRegistry
      # entries for it AFTER all callers finish.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", target_id)
      binding_uri = URI.to_string(worker_uri)

      caller = self()

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            result = WorkerSpawn.spawn(session_uri, "mock_publish", target_id)
            send(caller, {:spawn_done, result})
            result
          end)
        end)
        |> Enum.map(&Task.await/1)

      # Exactly one `{:ok, pid}`; nine `{:error, {:already_started, pid}}`.
      {oks, errs} =
        Enum.split_with(results, fn
          {:ok, pid} when is_pid(pid) -> true
          _ -> false
        end)

      assert length(oks) == 1, "expected exactly 1 :ok spawn; got #{inspect(results)}"
      assert length(errs) == 9

      Enum.each(errs, fn r ->
        assert match?({:error, {:already_started, pid}} when is_pid(pid), r),
               "non-:already_started error: #{inspect(r)}"
      end)

      # Every error pid is the SAME pid as the :ok winner.
      {:ok, winner_pid} = hd(oks)

      Enum.each(errs, fn {:error, {:already_started, p}} ->
        assert p == winner_pid
      end)

      # WorkerRegistry sees exactly one entry for this binding_uri.
      assert {:ok, ^winner_pid} = WorkerRegistry.lookup(binding_uri)
    end
  end

  # ----- helpers ----------------------------------------------------------

  defp ensure_adapter_registered(adapter, binding) do
    _ = Ezagent.ExternalMirror.AdapterRegistry.register(adapter)
    _ = Ezagent.ExternalMirror.BindingRegistry.register_module(adapter.adapter_id(), binding)
    :ok
  rescue
    _ -> :ok
  end

  # Terminate every PerBindingSupervisor under RootSupervisor (clean
  # slate between tests). Idempotent — silently skips already-gone pids.
  defp cleanup_workers do
    case Process.whereis(RootSupervisor) do
      nil ->
        :ok

      _ ->
        DynamicSupervisor.which_children(RootSupervisor)
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          if is_pid(pid) do
            _ = DynamicSupervisor.terminate_child(RootSupervisor, pid)
          end
        end)
    end

    :ok
  end
end
