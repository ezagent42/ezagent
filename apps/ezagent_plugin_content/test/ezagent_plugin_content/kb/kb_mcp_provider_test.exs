defmodule EzagentPluginContent.Kb.KbMcpProviderTest do
  use ExUnit.Case
  alias EzagentPluginContent.Kb.KbMcpProvider

  test "config returns valid JSON with parameterized server name" do
    json = KbMcpProvider.config("cinnox", "/tmp/test-sandbox/kb")
    {:ok, decoded} = Jason.decode(json)
    assert Map.has_key?(decoded["mcpServers"], "cinnox-kb")
    server = decoded["mcpServers"]["cinnox-kb"]
    assert server["command"] == "uv"
    assert server["env"]["KB_DB_PATH"] == "/tmp/test-sandbox/kb/kb.db"
  end
end
