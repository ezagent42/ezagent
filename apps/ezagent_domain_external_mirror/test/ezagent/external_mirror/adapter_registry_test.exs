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

  alias Ezagent.ExternalMirror.AdapterRegistry
  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, OtherAdapter}

  setup do
    # Each test starts from a clean table — every test in this suite
    # is `async: false` and we delete on entry to keep tests
    # order-independent.
    :ets.delete_all_objects(AdapterRegistry.table())
    :ok
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
end
