defmodule Ezagent.ExternalMirror.BindingRegistryTest do
  @moduledoc """
  BindingRegistry lifecycle tests (PR-EM-1 acceptance test 2).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.2 + §9 PR-EM-1.

  Tests the four contract points:
  - `register_module/2` stores `adapter_id → binding_module`.
  - `lookup/1` returns `{:ok, binding_module}` / `:error`.
  - `lookup!/1` raises `KeyError` on missing (structural fail-loud).
  - Idempotency + duplicate-id rejection (Grill-5 1:1 enforcement).
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.BindingRegistry
  alias Ezagent.ExternalMirror.TestSupport.{MockBinding, OtherBinding}
  alias Ezagent.ExternalMirror.TestSupport.RegistrySnapshot

  setup do
    # Snapshot + wipe + restore-on-exit so wiping the GLOBAL registry
    # doesn't drop production rows (e.g. feishu) for concurrent async
    # tests like EzagentPluginFeishu PluginContractTest.
    RegistrySnapshot.with_clean_registries()
  end

  describe "register_module/2 + lookup/1 + lookup!/1" do
    test "registers a binding and looks it up by adapter_id" do
      assert :ok = BindingRegistry.register_module("mock_em", MockBinding)
      assert {:ok, MockBinding} = BindingRegistry.lookup("mock_em")
      assert MockBinding == BindingRegistry.lookup!("mock_em")
    end

    test "lookup/1 returns :error for an unregistered adapter_id" do
      assert :error = BindingRegistry.lookup("never-registered")
    end

    test "lookup!/1 RAISES for an unregistered adapter_id (structural fail-loud per §5.2)" do
      err =
        assert_raise KeyError, fn ->
          BindingRegistry.lookup!("never-registered")
        end

      assert err.key == "never-registered"
    end

    test "re-registering the same (adapter_id, binding_module) pair is idempotent" do
      # First call inserts → `:ok`. Second call sees the existing
      # row → `{:ok, :already_present}` (codex r2 HIGH-2).
      assert :ok = BindingRegistry.register_module("mock_em", MockBinding)
      assert {:ok, :already_present} = BindingRegistry.register_module("mock_em", MockBinding)
      assert {:ok, MockBinding} = BindingRegistry.lookup("mock_em")
    end

    test "binding a different module to an already-registered adapter_id raises (Grill-5 1:1)" do
      assert :ok = BindingRegistry.register_module("mock_em", MockBinding)

      err =
        assert_raise ArgumentError, fn ->
          BindingRegistry.register_module("mock_em", OtherBinding)
        end

      assert err.message =~ "mock_em"
      assert err.message =~ "MockBinding"
      assert err.message =~ "OtherBinding"
      assert err.message =~ "Grill-5"
    end
  end

  describe "list_all/0" do
    test "returns the registered (adapter_id, binding_module) pairs" do
      assert BindingRegistry.list_all() == []
      :ok = BindingRegistry.register_module("mock_em", MockBinding)
      assert [{"mock_em", MockBinding}] == BindingRegistry.list_all()
    end
  end
end
