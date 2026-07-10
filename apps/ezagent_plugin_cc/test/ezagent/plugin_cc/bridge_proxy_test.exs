defmodule EzagentPluginCc.BridgeProxyTest do
  use ExUnit.Case, async: true

  @scripts [
    "priv/python/ezagent_mcp_bridge.py",
    "priv/orchestrator_bridge.py"
  ]

  test "Python websocket bridges bypass ambient proxy settings" do
    root = Path.expand("../../..", __DIR__)

    for script <- @scripts do
      source = File.read!(Path.join(root, script))

      assert source =~ "websockets.connect(url, max_size=None, proxy=None)",
             "#{script} must pass proxy=None so localhost bridge websockets " <>
               "ignore ambient http_proxy/https_proxy environment variables"
    end
  end
end
