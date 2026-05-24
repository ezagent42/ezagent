defmodule Ezagent.ExternalMirrorTest do
  @moduledoc """
  Tests for the `Ezagent.ExternalMirror` facade (PR-EM-1 acceptance
  test 6 + facade stub-return policy verification).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.4.

  Pins:
  - `list_adapters/0` returns the SPEC §4.4 shape
    (`%{id, display_name, description}`) for every registered adapter.
  - `list_bindings/1` returns `{:ok, []}` (PR-EM-1 stub — slice lands
    in PR-EM-3).
  - `sessions_for_adapter/1` returns `{:ok, []}` (PR-EM-1 stub —
    same reason).
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror
  alias Ezagent.ExternalMirror.AdapterRegistry
  alias Ezagent.ExternalMirror.TestSupport.MockAdapter

  setup do
    :ets.delete_all_objects(AdapterRegistry.table())
    :ok
  end

  describe "list_adapters/0" do
    test "returns SPEC §4.4 shape — id, display_name, description — for each registered adapter" do
      :ok = AdapterRegistry.register(MockAdapter)

      [adapter] = ExternalMirror.list_adapters()

      assert adapter == %{
               id: "mock_em",
               display_name: "Mock EM Adapter",
               description: "Test-only adapter for PR-EM-1 registry tests."
             }
    end

    test "returns an empty list when no adapters are registered" do
      assert ExternalMirror.list_adapters() == []
    end

    test "strips the AdapterRegistry's internal :module field (SPEC §4.4 is module-free)" do
      :ok = AdapterRegistry.register(MockAdapter)

      [adapter] = ExternalMirror.list_adapters()
      refute Map.has_key?(adapter, :module)
    end
  end

  describe "list_bindings/1 (PR-EM-3 — real slice lookup)" do
    test "returns {:error, :not_found} for a session URI that isn't live" do
      uri = URI.parse("session://workspace/test/session_123")
      assert {:error, _} = ExternalMirror.list_bindings(uri)
    end
  end

  describe "sessions_for_adapter/1 (PR-EM-1 stub)" do
    test "returns {:ok, []} for any adapter_id — projection lands in PR-EM-3" do
      assert {:ok, []} = ExternalMirror.sessions_for_adapter("feishu")
      assert {:ok, []} = ExternalMirror.sessions_for_adapter("anything")
    end
  end
end
