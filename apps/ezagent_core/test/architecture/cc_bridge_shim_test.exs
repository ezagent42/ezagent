Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.CcBridgeShimTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  # FF-4: distinct non-agent_bridge/non-test lib files still referencing a
  # `/cc_socket` deprecation-shim module
  # (EzagentPluginCc.{BridgeRegistry,Socket,Channel,TokenStore}). Cleanup-3
  # migrated the three liveview callers to `Ezagent.AgentBridge.Registry`,
  # deleted all four shim modules, and removed the `/cc_socket` endpoint
  # mount — ratcheting this counter to 0. This is now a TARGET-ZERO
  # invariant: any lib file reintroducing the shim layer must fail this test.
  test "cc_socket shim callers are zero — shim layer removed (Cleanup-3)" do
    assert_zero(:cc_bridge_shim_callers)
  end
end
