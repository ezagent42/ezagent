defmodule Ezagent.PluginLoom.StitchChat do
  @moduledoc """
  **Stitch** 对话存储(2026-06-05)。

  Stitch = preview 页右下角固定叠加的聊天界面。访客跟 Stitch(独立 DeepSeek-v4-flash,
  非思考)对话,做简单页面增强。这里存**每个 preview 会话一份对话**(user/assistant
  消息序列),从属于 session。

  本轮重点:Stitch 对话**被持久化** → 分享时冻结进快照 → 被分享者只读能看见。

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_stitch_chats.json`,key=session uri:

      %{ "session://loom/<ws>/<sid>" => [%{"role"=>"user"|"assistant","text"=>..,"id"=>..}, ...] }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_stitch_chats.json")
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

  @doc "读某 session 的 Stitch 对话(无则空列表)。"
  @spec get(String.t(), String.t()) :: [map()]
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), key(ws, sid)) do
      msgs when is_list(msgs) -> msgs
      _ -> []
    end
  end

  @doc "追加一条消息,返回更新后的完整对话。"
  @spec append(String.t(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def append(ws, sid, msg) when is_binary(ws) and is_binary(sid) and is_map(msg) do
    k = key(ws, sid)
    all = load_all()

    existing =
      case Map.get(all, k) do
        msgs when is_list(msgs) -> msgs
        _ -> []
      end

    updated = existing ++ [msg]
    save_all(Map.put(all, k, updated))
    {:ok, updated}
  end

  def append(_ws, _sid, _msg), do: {:error, :invalid_msg}

  @doc "整盘替换对话(fork 时把快照的对话复制进新 session)。"
  @spec replace(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def replace(ws, sid, msgs) when is_binary(ws) and is_binary(sid) and is_list(msgs) do
    save_all(Map.put(load_all(), key(ws, sid), msgs))
    {:ok, msgs}
  end

  def replace(_ws, _sid, _msgs), do: {:error, :invalid_msgs}
end
