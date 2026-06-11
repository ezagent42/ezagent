defmodule EzagentPluginContent.Kb.KbRebuilder do
  @moduledoc "Invoke Python kb_search_mcp.py to rebuild kb.db from glossary + sources."

  @spec rebuild(binary(), binary()) :: :ok | {:error, term()}
  def rebuild(sandbox_kb_dir, _base_dir \\ nil) do
    script = Path.join(sandbox_kb_dir, "kb_search_mcp.py")
    db_path = Path.join(sandbox_kb_dir, "kb.db")
    glossary = Path.join(sandbox_kb_dir, "glossary.json")
    sources = Path.join(sandbox_kb_dir, "_sources")

    case System.cmd("uv", ["run", "--script", script, "--rebuild",
         "--db-path", db_path, "--glossary", glossary, "--sources", sources],
         stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, output}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
