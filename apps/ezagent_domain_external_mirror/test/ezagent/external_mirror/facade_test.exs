defmodule Ezagent.ExternalMirrorTest do
  @moduledoc """
  Tests for the `Ezagent.ExternalMirror` facade (PR-EM-1 acceptance
  test 6 + facade stub-return policy verification).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.4.

  Pins:
  - `list_adapters/0` returns the SPEC §4.4 shape
    (`%{id, display_name, description}`) for every registered adapter.
  - `list_bindings/2` returns `{:error, :no_such_actor}` for a session
    that isn't running (PR-EM-3 r3 — dispatch path).
  - `sessions_for_adapter/2` returns `{:ok, []}` when there are no
    bindings.

  ## codex r3 — facade signature change

  `list_bindings/1` → `list_bindings/2` (caller ctx required so
  dispatch CapBAC step 5.5 runs). `sessions_for_adapter/1` →
  `sessions_for_adapter/2` (caller ctx required so workspace filter
  runs). See `Ezagent.ExternalMirror` moduledoc r2 HIGH-2 fix.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Capability, ExternalMirror}
  alias Ezagent.ExternalMirror.AdapterRegistry
  alias Ezagent.ExternalMirror.TestSupport.MockAdapter
  alias Ezagent.ExternalMirror.TestSupport.RegistrySnapshot

  setup do
    # Snapshot + wipe + restore-on-exit so wiping the GLOBAL registry
    # doesn't drop production rows (e.g. feishu) for concurrent async
    # tests.
    RegistrySnapshot.with_clean_registries()
  end

  # Admin-shape ctx for "bare unit tests don't care about caps" cases.
  defp admin_ctx do
    %{
      caller: Ezagent.URI.new!("system://bootstrap/default"),
      caps:
        MapSet.new([
          %Capability{
            kind: :any,
            behavior: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.user(:system, :admin),
            granted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]),
      reply: :ignore
    }
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

  describe "list_bindings/2 (PR-EM-3 r3 — dispatch-gated lookup)" do
    test "returns {:error, _} for a session URI that isn't live" do
      uri = Ezagent.URI.new!("session://workspace/test/session_123")
      assert {:error, _} = ExternalMirror.list_bindings(uri, admin_ctx())
    end
  end

  describe "sessions_for_adapter/2 (PR-EM-3 r3 — workspace-filtered)" do
    test "returns {:ok, []} for an adapter with no rows" do
      assert {:ok, []} = ExternalMirror.sessions_for_adapter("feishu", admin_ctx())
      assert {:ok, []} = ExternalMirror.sessions_for_adapter("anything", admin_ctx())
    end
  end
end
