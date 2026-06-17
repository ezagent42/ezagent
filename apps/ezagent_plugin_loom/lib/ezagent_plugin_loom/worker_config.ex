defmodule EzagentPluginLoom.WorkerConfig do
  @moduledoc """
  Loom **per-session 可配 worker roster**(`%{key, desc, prompt}` 列表,ETS)。

  有配置时编排器 decompose 用配置的 worker(desc 作 theme);无配置时回退动态 decompose。
  由 MetaAgent(@自然语言改 team)增删。这是务实版的 worker roster(对应 loom-stitch worker_config)。
  """
  use GenServer

  @table :loom_worker_config

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "列出 session 的 worker 配置(无 → [])。"
  def list(session_uri) do
    ensure_table()

    case :ets.lookup(@table, key(session_uri)) do
      [{_k, workers}] -> workers
      [] -> []
    end
  end

  @doc "增加一个 worker `%{\"key\",\"desc\",\"prompt\"}`(同 key 覆盖)。"
  def add(session_uri, %{} = worker) do
    ensure_table()
    wk = worker["key"] || worker[:key]
    others = Enum.reject(list(session_uri), &((&1["key"] || &1[:key]) == wk))
    :ets.insert(@table, {key(session_uri), others ++ [normalize(worker)]})
    :ok
  end

  @doc "按 key 删除。"
  def remove(session_uri, wk) when is_binary(wk) do
    ensure_table()
    kept = Enum.reject(list(session_uri), &((&1["key"] || &1[:key]) == wk))
    :ets.insert(@table, {key(session_uri), kept})
    :ok
  end

  @impl true
  def init(:ok) do
    create_table()
    {:ok, %{}}
  end

  defp normalize(w) do
    %{
      "key" => w["key"] || w[:key],
      "desc" => w["desc"] || w[:desc] || "",
      "prompt" => w["prompt"] || w[:prompt] || ""
    }
  end

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined, do: create_table()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
