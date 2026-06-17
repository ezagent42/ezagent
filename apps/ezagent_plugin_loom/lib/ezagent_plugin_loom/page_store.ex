defmodule EzagentPluginLoom.PageStore do
  @moduledoc """
  per-session **当前页**(files map)的权威缓存 —— 对应 loom-stitch orchestrator 的
  `loom_source` slice。每次 seed / v0 产出 page_update 即同步写这里;发布/分享读这里
  (而非扫消息历史,避免 MessageStore 持久化时序导致抓到旧页/seed)。ETS,本 GenServer 持有。
  """
  use GenServer

  @table :loom_page_store

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "写 session 当前页 files map。"
  @spec put(URI.t() | String.t(), map()) :: :ok
  def put(session_uri, files) when is_map(files) do
    ensure_table()
    :ets.insert(@table, {key(session_uri), files})
    :ok
  end

  @doc "读 session 当前页 files map(无 → nil)。"
  @spec get(URI.t() | String.t()) :: map() | nil
  def get(session_uri) do
    ensure_table()

    case :ets.lookup(@table, key(session_uri)) do
      [{_k, files}] -> files
      [] -> nil
    end
  end

  defp key(%URI{} = u), do: URI.to_string(u)
  defp key(s) when is_binary(s), do: s

  @impl true
  def init(:ok) do
    create_table()
    {:ok, %{}}
  end

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
