defmodule Ezagent.PluginLoom.Knowledge do
  @moduledoc """
  Loom **知识库**(2026-06-09)。

  编辑者在 loom 编辑器里写一段 Markdown 知识库;它作为**消费侧 Salesperson / AiSpot 的
  grounding**——访客提问时,助手据这段知识作答(而不是"不懂")。

  从属于 session(每个会话一段)。发布时随模板带走、fork 时复制,这样消费侧会话也有。

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_knowledge.json`,key=session uri:

      %{ "session://loom/<ws>/<sid>" => "<markdown 字符串>" }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_knowledge.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  defp key(ws, sid), do: "session://loom/#{ws}/#{sid}"

  @doc "读某 session 的知识库 md(无则空串)。"
  @spec get(String.t(), String.t()) :: String.t()
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), key(ws, sid)) do
      md when is_binary(md) -> md
      _ -> ""
    end
  end

  @doc "整盘写某 session 的知识库 md。"
  @spec put(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def put(ws, sid, md) when is_binary(ws) and is_binary(sid) and is_binary(md) do
    load_all() |> Map.put(key(ws, sid), md) |> save_all()
    {:ok, md}
  end

  def put(_ws, _sid, _md), do: {:error, :invalid_md}
end
