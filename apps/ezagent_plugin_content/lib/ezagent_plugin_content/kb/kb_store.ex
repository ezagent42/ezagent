defmodule EzagentPluginContent.Kb.KbStore do
  @moduledoc "KB entry CRUD. Wraps Python MCP script calls."

  @spec search(binary(), String.t()) :: [map()]
  def search(kb_dir, query) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")

    case System.cmd("uv", ["run", "--script", script, "--db-path", db, "--query", query], stderr_to_stdout: true) do
      {output, 0} -> decode_json_list(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  @spec upsert(binary(), map()) :: :ok | {:error, term()}
  def upsert(kb_dir, entry) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")

    case System.cmd(
           "uv",
           [
             "run",
             "--script",
             script,
             "--db-path",
             db,
             "--upsert",
             Jason.encode_to_iodata!(entry) |> IO.iodata_to_binary()
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  @spec delete(binary(), String.t()) :: :ok
  def delete(kb_dir, id) do
    script = Path.join(kb_dir, "kb_search_mcp.py")
    db = Path.join(kb_dir, "kb.db")
    System.cmd("uv", ["run", "--script", script, "--db-path", db, "--delete", id], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp decode_json_list(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end
end
