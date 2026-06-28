defmodule EzagentPluginCodex.BridgeAdapterToolTest do
  use ExUnit.Case, async: true

  test "run_tool client event fails closed through the SessionManager seam" do
    agent_uri = Ezagent.URI.new!("entity://system/agent/codex_orch_tool_test")

    socket = %Phoenix.Socket{
      assigns: %{
        agent_uri: agent_uri,
        bridge_token: "not-a-real-token"
      }
    }

    assert {:reply, {:ok, %{"ok" => false, "error" => error}}, ^socket} =
             EzagentPluginCodex.BridgeAdapter.handle_client_event(
               "run_tool",
               %{"tool" => "kb_query", "arguments" => %{"kb_agent" => "kb", "query" => "q"}},
               socket
             )

    assert error =~ "session_manager_unavailable"
  end
end
