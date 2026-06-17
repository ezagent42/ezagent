defmodule Ezagent.PluginLoom.ConsumerSession do
  @moduledoc """
  「发布消费会话」标记(2026-06-10)。

  loom 会话分两类:
  - **创作会话**:直接从 `session.loom`、或从手存模板(如 zuatu 的 `session.zuatu`)
    实例化 —— 用来编辑/创作页面,**应当有 loom 视图**。
  - **发布消费会话**:`/p/:token/open` 从**已发布模板**(`published:true`)mint 出来的
    per-访客只读消费页(名为 `pub_<hex>`)。它不该出现 loom 编辑视图 tab。

  按**名字**(`pub_` 前缀)判不可靠;按**有没有 v0** 也分不开(zuatu 也无 v0)。真正的
  区别是**创建来源**:是否经 `/p/:token/open` 从发布物 mint。所以在那唯一的创建点
  `mark/2` 打一个**持久标志**,`LoomSessionView.applies_to?/1` 读它来隐藏 loom tab。

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_consumer_sessions.json`,key=session uri → true:

      %{ "session://loom/<ws>/<sid>" => true }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_consumer_sessions.json")
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

  @doc "标记某 session 为发布消费会话(无 loom 视图)。在 `/p/:token/open` 调用。"
  @spec mark(String.t(), String.t()) :: :ok
  def mark(ws, sid) when is_binary(ws) and is_binary(sid) do
    load_all() |> Map.put(key(ws, sid), true) |> save_all()
    :ok
  rescue
    _ -> :ok
  end

  def mark(_ws, _sid), do: :ok

  @doc "是否是发布消费会话(无 loom 视图)。"
  @spec consumer?(String.t(), String.t()) :: boolean()
  def consumer?(ws, sid) when is_binary(ws) and is_binary(sid) do
    Map.get(load_all(), key(ws, sid)) == true
  rescue
    _ -> false
  end

  def consumer?(_ws, _sid), do: false
end
