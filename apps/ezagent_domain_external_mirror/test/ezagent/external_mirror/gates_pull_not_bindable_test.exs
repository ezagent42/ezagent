defmodule Ezagent.ExternalMirror.GatesPullNotBindableTest do
  @moduledoc """
  P3-1 codex Finding 2 (MEDIUM) — a `:pull` adapter submitted to the
  push bind gate (`Gates.run_all/4`) must be REJECTED cleanly with
  `{:error, :not_bindable}` BEFORE the target-ownership-check /
  worker-binding dispatch.

  A pull adapter omits `target_ownership_check/2` (it has no per-binding
  external transport — it is served by its caller's Phoenix channel,
  P3-2). Without the guard, the bind flow reaches
  `run_target_ownership_check/3` and crashes with
  `UndefinedFunctionError` instead of returning a clean structural
  rejection. This test would fail (crash, not the error tuple) if the
  push-only guard were removed.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{AdapterRegistry, Gates}
  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding, PullAdapter}
  alias Ezagent.ExternalMirror.TestSupport.RegistrySnapshot

  setup do
    RegistrySnapshot.with_clean_registries()
  end

  # Admin-wildcard ctx — passes Gates 1, 2, 3 unconditionally so the
  # flow would (absent the guard) reach Gate 4 (target_ownership_check).
  defp admin_ctx(caller_uri) do
    %{
      caller: caller_uri,
      caps:
        MapSet.new([
          %Ezagent.Capability{
            kind: :any,
            behavior: :any,
            action: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.system(:bootstrap, :default),
            granted_at: ~U[2026-01-01 00:00:00Z]
          }
        ])
    }
  end

  describe "Gates.run_all/4 rejects a :pull adapter (Finding 2)" do
    test "returns {:error, :not_bindable} and does NOT invoke target_ownership_check/2" do
      :ok = AdapterRegistry.register(PullAdapter)

      # The pull adapter genuinely does not export the push transport
      # callback — proving the guard cannot be relying on it.
      refute function_exported?(PullAdapter, :target_ownership_check, 2)

      session_uri = Ezagent.URI.new!("session://session/default/pull-bind-guard")
      caller_uri = Ezagent.URI.user(:default, "pull-guard-caller")

      assert {:error, :not_bindable} =
               Gates.run_all(session_uri, admin_ctx(caller_uri), "pull_em", "tgt-1")
    end

    test "a :push adapter still passes the gate (push path unchanged)" do
      :ok = AdapterRegistry.register(MockAdapter)

      _ =
        Ezagent.ExternalMirror.BindingRegistry.register_module(
          "mock_em",
          MockBinding
        )

      session_uri = Ezagent.URI.new!("session://session/default/push-bind-guard")
      caller_uri = Ezagent.URI.user(:default, "push-guard-caller")

      # MockAdapter.target_ownership_check/2 returns :ok, so a push
      # adapter passes all gates → {:ok, module}.
      assert {:ok, MockAdapter} =
               Gates.run_all(session_uri, admin_ctx(caller_uri), "mock_em", "tgt-1")
    end
  end
end
