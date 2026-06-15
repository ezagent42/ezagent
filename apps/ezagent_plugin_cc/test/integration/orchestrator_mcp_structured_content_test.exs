defmodule Ezagent.Orchestrator.McpStructuredContentTest do
  @moduledoc """
  Regression for the 2026-06-15 orchestrator-MCP `structuredContent` encode bug
  (Transport #53 / #750).

  `McpServer.success_result/1` set `structuredContent` to `stringify(value)`
  directly. For a tool returning a SCALAR/URI/list — e.g. `add_managed_member`
  → `{:ok, member_uri}` (a `%URI{}`) — that yields a bare STRING (or array),
  but MCP requires `structuredContent` to be an OBJECT/record. The bridge
  rejected it with `structuredContent: invalid_type, expected record, received
  string`, so the orchestrator's claude could not read back the result (the new
  member URI) and correctly refused to fabricate one — even though the tool's
  side effect (the agent spawn) succeeded.

  The fix wraps any non-map result in `%{"result" => ...}` so structuredContent
  is always a valid object; map results pass through unchanged. These tests
  exercise the encode boundary `McpServer.to_mcp_result/1` directly.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Orchestrator.McpServer

  test "a URI tool result (e.g. add_managed_member → {:ok, member_uri}) encodes as an OBJECT structuredContent" do
    uri = URI.parse("entity://system/agent/demo-helper-7b8f982a8729ecb0")

    result = McpServer.to_mcp_result({:ok, uri})

    refute result["isError"]

    assert is_map(result["structuredContent"]),
           "MCP structuredContent MUST be an object/record, not a bare string — " <>
             "got: #{inspect(result["structuredContent"])}"

    assert result["structuredContent"]["result"] == "entity://system/agent/demo-helper-7b8f982a8729ecb0",
           "the member URI must be readable back from structuredContent.result"
  end

  test "a plain string tool result encodes as an OBJECT structuredContent" do
    result = McpServer.to_mcp_result({:ok, "ok-done"})

    assert is_map(result["structuredContent"])
    assert result["structuredContent"]["result"] == "ok-done"
  end

  test "a list tool result encodes as an OBJECT structuredContent (not a bare array)" do
    result = McpServer.to_mcp_result({:ok, [1, 2, 3]})

    assert is_map(result["structuredContent"]),
           "a list result must be wrapped so structuredContent is an object, not an array"

    assert result["structuredContent"]["result"] == [1, 2, 3]
  end

  test "a map tool result passes through unchanged as structuredContent (object already)" do
    result = McpServer.to_mcp_result({:ok, %{agent_templates: [], session_templates: []}})

    assert result["structuredContent"]["agent_templates"] == []
    assert result["structuredContent"]["session_templates"] == []
    refute Map.has_key?(result["structuredContent"], "result"),
           "a map result must NOT be double-wrapped under :result"
  end

  test ":ok (bare) encodes as an object, not a bare atom/string" do
    result = McpServer.to_mcp_result(:ok)
    assert is_map(result["structuredContent"])
  end
end
