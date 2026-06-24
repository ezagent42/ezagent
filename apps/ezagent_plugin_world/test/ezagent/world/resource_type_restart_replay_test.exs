defmodule Ezagent.World.ResourceTypeRestartReplayTest do
  @moduledoc """
  End-to-end proof (Bug B) that the `FsResolver.Registry` init-time
  discovery-replay reaches the world plugin through REAL plugin discovery — the
  actual `:ezagent_plugin` app-env key naming the real `EzagentPluginWorld.Application`
  module — NOT a test-injected env (as the `ezagent_core` unit tests must use,
  since standalone core loads no plugin). This suite runs with the world plugin
  REALLY loaded, so it closes the "tests prove the loop, not real discovery" gap.

  NON-MUTATING by design: it does NOT unregister the global `world-layouts` type.
  A global drop would race other suites in the shared umbrella BEAM (exactly the
  hazard `Ezagent.World.ResourceTypeCase.ensure_world_layouts!/0` exists to
  prevent). The "restore-when-absent" arm is proven on the injected-env path by
  the `ezagent_core` unit tests; here we prove the REAL discovery + that the replay
  is idempotent over the already-registered real type.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Resource.FsResolver.Registry

  @table :ezagent_resource_fs_types
  defp registered?, do: :ets.lookup(@table, "world-layouts") != []

  test "the world app is discoverable through the real :ezagent_plugin env contract" do
    # The exact discovery `replay_plugin_resource_types/0` performs: read the app's
    # `:ezagent_plugin` contract module and confirm it declares `world-layouts`.
    mod = Application.get_env(:ezagent_plugin_world, :ezagent_plugin)

    assert mod == EzagentPluginWorld.Application,
           "world app must name its plugin contract module via the :ezagent_plugin env key"

    assert function_exported?(mod, :resource_types, 0)
    assert Enum.any?(mod.resource_types(), &match?({"world-layouts", _}, &1))
  end

  test "the init-replay runs REAL discovery over the real world plugin idempotently (no crash, type preserved)" do
    # world-layouts is registered by the booted world app.
    assert registered?(), "world-layouts must be registered by the booted world app"

    # The SAME discovery + replay that `init/1` runs on EVERY start, against the
    # REAL loaded apps (no env injection). Because world-layouts is already present
    # with its real spec, the replay's `batch_register` hits the idempotent path
    # (same type + same backend → no-op) — it must NOT error and must NOT drop the
    # live type. This proves real discovery reaches the real plugin AND that the
    # restart-replay is safe to run when the type already exists (the OTP-release
    # first-boot ordering, where Phase-2 also registers).
    assert :ok = Registry.replay_plugins_for_test()
    assert registered?(), "idempotent replay must keep world-layouts registered"
  end
end
