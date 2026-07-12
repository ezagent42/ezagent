defmodule Ezagent.Orchestrator.McpServer.ToolCatalog do
  @moduledoc "Thin MCP projection of the assembled domain Session-Config catalog."

  @spec tool_schemas() :: [map()]
  def tool_schemas, do: Ezagent.Session.Config.Catalog.schemas()

  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(tool_schemas(), & &1["name"])
end
