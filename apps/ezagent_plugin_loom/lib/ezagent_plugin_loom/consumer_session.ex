defmodule EzagentPluginLoom.ConsumerSession do
  @moduledoc """
  「发布消费会话」标记(迁移自 loom-stitch)。打开分享链接 mint 的 `pub_<hex>` session 是
  **只读消费会话**,不该出现编辑器视图(Loom / Dashboard tab)。`mark/2` 在 open/fork 时打标,
  `consumer?/2` 给 SessionView 的 `applies_to?` 判定。ETS(本 GenServer 持有)。
  """
  use GenServer

  @table :loom_consumer_session

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec mark(String.t(), String.t()) :: :ok
  def mark(ws, sid) when is_binary(ws) and is_binary(sid) do
    ensure_table()
    :ets.insert(@table, {{ws, sid}, true})
    :ok
  end

  def mark(_ws, _sid), do: :ok

  @spec consumer?(String.t(), String.t()) :: boolean()
  def consumer?(ws, sid) when is_binary(ws) and is_binary(sid) do
    ensure_table()
    :ets.lookup(@table, {ws, sid}) != []
  end

  def consumer?(_ws, _sid), do: false

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
