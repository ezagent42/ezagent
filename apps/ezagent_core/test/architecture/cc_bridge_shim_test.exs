Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.CcBridgeShimTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  # FF-4: distinct non-agent_bridge/non-test lib files still referencing a
  # `/cc_socket` deprecation-shim module
  # (EzagentPluginCc.{BridgeRegistry,Socket,Channel,TokenStore}). A later cleanup
  # PR migrates those callers to the `Ezagent.AgentBridge.*` modules and deletes
  # the shims, ratcheting this counter to 0.
  test "cc_socket shim callers do not grow beyond baseline" do
    assert_at_or_below(:cc_bridge_shim_callers)
  end
end
