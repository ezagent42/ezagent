defmodule Ezagent.ExternalMirror.AdapterRegistryTest do
  @moduledoc """
  AdapterRegistry lifecycle tests (PR-EM-1 acceptance test 1).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.2 + §9 PR-EM-1.

  Tests the four contract points:
  - `register/1` reads `adapter_id/0` and stores `id → module`.
  - `lookup/1` returns `{:ok, module}` / `:error`.
  - `lookup!/1` raises `KeyError` on missing (structural fail-loud).
  - `list/0` returns the SPEC §4.4 shape per registered adapter.
  - Idempotency + duplicate-id rejection.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry, WorkerRegistry}

  alias Ezagent.ExternalMirror.TestSupport.{
    CursorPullAdapter,
    MockAdapter,
    OtherAdapter,
    PullAdapter,
    PullAdapterMissingLiveTopics,
    PushAdapterMissingBinding,
    SnapshotPullAdapter,
    SnapshotPullAdapterWithCursor
  }

  alias Ezagent.ExternalMirror.TestSupport.RegistrySnapshot

  setup do
    # Each test starts from a clean table — every test in this suite
    # is `async: false` and we delete on entry to keep tests
    # order-independent. Snapshot + restore-on-exit so wiping the GLOBAL
    # registry doesn't drop production rows (e.g. feishu) for concurrent
    # async tests.
    RegistrySnapshot.with_clean_registries()
  end

  describe "register/1 + lookup/1 + lookup!/1" do
    test "registers an adapter and looks it up by id" do
      assert :ok = AdapterRegistry.register(MockAdapter)
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")
      assert MockAdapter == AdapterRegistry.lookup!("mock_em")
    end

    test "lookup/1 returns :error for an unregistered id" do
      assert :error = AdapterRegistry.lookup("never-registered")
    end

    test "lookup!/1 RAISES for an unregistered id (structural fail-loud per §5.2)" do
      err =
        assert_raise KeyError, fn ->
          AdapterRegistry.lookup!("never-registered")
        end

      assert err.key == "never-registered"
    end

    test "registering the same module twice is idempotent" do
      # First call inserts → `:ok`. Second call sees an existing row
      # for the same module → `{:ok, :already_present}` (codex r2
      # HIGH-2 distinguished return so the rollback path can avoid
      # over-deleting pre-existing rows).
      assert :ok = AdapterRegistry.register(MockAdapter)
      assert {:ok, :already_present} = AdapterRegistry.register(MockAdapter)
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")
    end

    test "two different modules claiming the same adapter_id raises" do
      assert :ok = AdapterRegistry.register(MockAdapter)

      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(OtherAdapter)
        end

      assert err.message =~ "mock_em"
      assert err.message =~ "MockAdapter"
      assert err.message =~ "OtherAdapter"
    end
  end

  describe "list/0" do
    test "returns SPEC §4.4 shape: %{id, module, display_name, description}" do
      :ok = AdapterRegistry.register(MockAdapter)

      [entry] = AdapterRegistry.list()
      assert entry.id == "mock_em"
      assert entry.module == MockAdapter
      assert entry.display_name == "Mock EM Adapter"
      assert entry.description =~ "Test-only adapter"
    end

    test "returns an empty list when no adapters registered" do
      assert AdapterRegistry.list() == []
    end
  end

  describe "adapter KIND axis (P3-1)" do
    test "kind_of/1 defaults to :push for an adapter that does not export adapter_kind/0" do
      # MockAdapter is an existing :push adapter and does NOT export
      # adapter_kind/0 — back-compat default per P3-1.
      refute function_exported?(MockAdapter, :adapter_kind, 0)
      assert Adapter.kind_of(MockAdapter) == :push
    end

    test "kind_of/1 returns :pull for an adapter that declares adapter_kind :pull" do
      assert Adapter.kind_of(PullAdapter) == :pull
    end

    test "a :pull adapter registers WITHOUT a binding_module" do
      refute function_exported?(PullAdapter, :binding_module, 0)
      assert :ok = AdapterRegistry.register(PullAdapter)
      assert {:ok, PullAdapter} = AdapterRegistry.lookup("pull_em")
    end

    test "a :pull adapter does NOT spawn a Worker on registration" do
      before = WorkerRegistry.list_all()
      assert :ok = AdapterRegistry.register(PullAdapter)
      # No per-binding Worker/supervisor is started for a pull adapter —
      # it is served by its caller's Phoenix channel (P3-2), not a Worker.
      assert WorkerRegistry.list_all() == before
    end

    test "a :pull adapter's install hook FIRES on AdapterRegistry alone — cap subject registered, no binding (codex P3-1 HIGH)" do
      # The install hook for a binding-less pull adapter must NOT wait on a
      # BindingRegistry entry (which never arrives) — otherwise install/1 never
      # runs and the per-adapter allow cap is never registered, leaving the
      # adapter unusable for grant/validate flows.
      assert :ok = AdapterRegistry.register(PullAdapter)

      # install/1 ran register_cap_subject/2 → the allow_<id> subject exists
      # on Ezagent.Entity.Session, even though no Worker/binding exists.
      assert {:ok, %{behavior: Ezagent.ExternalMirror.TestSupport.PullAdapter.Allow}} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 :allow_pull_em
               )

      # ...and NO BindingRegistry row was ever created for the pull adapter.
      assert :error = Ezagent.ExternalMirror.BindingRegistry.lookup("pull_em")
    end

    test "adapter-first: a binding for an already-registered :pull adapter is REJECTED (codex P3-1 r3 HIGH)" do
      # The "a :pull adapter NEVER has a BindingRegistry row" invariant holds at
      # the registry layer for the DIRECT path too — not just plugin boot.
      assert :ok = AdapterRegistry.register(PullAdapter)

      assert_raise ArgumentError, ~r/pull adapter|no transport binding/, fn ->
        Ezagent.ExternalMirror.BindingRegistry.register_module(
          "pull_em",
          Ezagent.ExternalMirror.TestSupport.MockBinding
        )
      end

      assert :error = Ezagent.ExternalMirror.BindingRegistry.lookup("pull_em")
    end

    test "binding-first: registering a :pull adapter whose id already has a binding row is REJECTED (codex P3-1 r3 HIGH)" do
      # The symmetric ordering: a binding row landed first (id not yet an
      # adapter, so allowed), then a :pull adapter claims that id → rejected.
      assert :ok =
               Ezagent.ExternalMirror.BindingRegistry.register_module(
                 "pull_em",
                 Ezagent.ExternalMirror.TestSupport.MockBinding
               )

      assert_raise ArgumentError,
                   ~r/BindingRegistry row already binds|no transport binding/,
                   fn ->
                     AdapterRegistry.register(PullAdapter)
                   end

      assert :error = AdapterRegistry.lookup("pull_em")
    end

    test "concurrent: racing AdapterRegistry.register(pull) vs BindingRegistry.register_module never lands the forbidden state (codex P3-1 r4 HIGH)" do
      # The cross-registry check+insert is serialized by RegistryLock, so under a
      # concurrent race exactly one side wins and the other is rejected — the
      # forbidden "pull adapter id WITH a binding row" state never occurs.
      a =
        Task.async(fn ->
          try do
            AdapterRegistry.register(PullAdapter)
          rescue
            ArgumentError -> :rejected
          end
        end)

      b =
        Task.async(fn ->
          try do
            Ezagent.ExternalMirror.BindingRegistry.register_module(
              "pull_em",
              Ezagent.ExternalMirror.TestSupport.MockBinding
            )
          rescue
            ArgumentError -> :rejected
          end
        end)

      Task.await(a)
      Task.await(b)

      # The invariant: NOT (id resolves to a :pull adapter AND a binding row
      # exists). At least one side was rejected by the locked cross-check.
      adapter_is_pull? = match?({:ok, PullAdapter}, AdapterRegistry.lookup("pull_em"))
      has_binding? = match?({:ok, _}, Ezagent.ExternalMirror.BindingRegistry.lookup("pull_em"))

      refute adapter_is_pull? and has_binding?,
             "forbidden state: :pull adapter pull_em coexisting with a binding row"
    end

    test "a :push adapter missing binding_module/0 still RAISES (push contract unchanged)" do
      assert Adapter.kind_of(PushAdapterMissingBinding) == :push

      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(PushAdapterMissingBinding)
        end

      assert err.message =~ "binding_module/0"
    end

    test "accepts a :cursor_replay pull adapter with replay callbacks" do
      assert Adapter.delivery_discipline_of(CursorPullAdapter) == :cursor_replay
      assert Adapter.participation_profile_of(CursorPullAdapter) == :participatory
      assert :ok = AdapterRegistry.register(CursorPullAdapter)
      assert {:ok, CursorPullAdapter} = AdapterRegistry.lookup("cursor_pull_em")
    end

    test "accepts a :snapshot_refresh pull adapter with result-bearing render and no cursor callbacks" do
      assert Adapter.delivery_discipline_of(SnapshotPullAdapter) == :snapshot_refresh
      assert Adapter.participation_profile_of(SnapshotPullAdapter) == :read_only
      refute function_exported?(SnapshotPullAdapter, :join_with_cursor, 2)
      refute function_exported?(SnapshotPullAdapter, :replay, 3)
      assert :ok = AdapterRegistry.register(SnapshotPullAdapter)
      assert {:ok, SnapshotPullAdapter} = AdapterRegistry.lookup("snapshot_pull_em")
    end

    test "rejects a :snapshot_refresh pull adapter that declares cursor callbacks" do
      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(SnapshotPullAdapterWithCursor)
        end

      assert err.message =~ "snapshot_refresh"
      assert err.message =~ "join_with_cursor/2"
    end

    test "rejects a pull adapter missing live_topics/1" do
      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(PullAdapterMissingLiveTopics)
        end

      assert err.message =~ "live_topics/1"
    end
  end
end
