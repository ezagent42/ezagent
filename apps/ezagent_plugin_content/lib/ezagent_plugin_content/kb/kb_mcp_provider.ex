defmodule EzagentPluginContent.Kb.KbMcpProvider do
  @moduledoc "Generate per-agent .mcp.json with parameterized <tid>-kb MCP server."

  @spec config(String.t(), binary()) :: binary()
  def config(tid, sandbox_kb_dir) do
    %{
      "mcpServers" => %{
        "#{tid}-kb" => %{
          "command" => "uv",
          "args" => ["run", "--script", Path.join(sandbox_kb_dir, "kb_search_mcp.py")],
          "env" => %{"KB_DB_PATH" => Path.join(sandbox_kb_dir, "kb.db")}
        }
      }
    }
    |> Jason.encode_to_iodata!()
    |> IO.iodata_to_binary()
  end
end
