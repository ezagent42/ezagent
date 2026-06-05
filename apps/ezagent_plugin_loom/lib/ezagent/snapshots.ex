defmodule Ezagent.PluginLoom.Snapshots do
  @moduledoc """
  Loom **share snapshot** store(2026-06-05)。

  > 命名:叫 "share snapshot",**不要**跟 ezagent 的 Kind snapshot(状态持久化)混。

  发布(`POST /api/:ws/:sid/publish`)时,除了创建不可变 Template Class(供 fork
  实例化),还**冻结当前 session 的一份分享快照**:对话历史 + user_schema ops +
  模板引用 + 原 session URI。快照**不可变**:分享者后续编辑不回流。

  分享链接打开:
  - 非分享者 → 只读浏览快照(`GET /loom/snapshot/:token`:历史 + ops + 页面)。
  - 要交互 → fork:用 `template_class` 实例化一个**无 v0** 的新 session,把快照的
    ops **复制**进新 session 的 user_schema。(历史是前端只读展示,不写进新 session,
    避免重放 re-dispatch / 违反 P14。)

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_snapshots.json`,key=token:

      %{ "<token>" => %{
           "ws", "template_class", "origin_sid",
           "history" => [frame...], "ops" => [op...], "created_at" } }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_snapshots.json")
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

  @doc "写入一份分享快照(key=token)。"
  @spec put(String.t(), map()) :: :ok
  def put(token, %{} = data) when is_binary(token) and token != "" do
    load_all() |> Map.put(token, data) |> save_all()
    :ok
  end

  @doc "读一份分享快照,无则 `:error`。"
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(token) when is_binary(token) and token != "" do
    case Map.get(load_all(), token) do
      %{} = data -> {:ok, data}
      _ -> :error
    end
  end

  def get(_), do: :error
end
