defmodule EzagentPluginLoom.Stats do
  @moduledoc """
  Loom **per-session 统计聚合**:attach `[:ezagent, :loom, :llm, :call]` telemetry,
  累加每 session 的 token / 调用次数到 ETS(本 GenServer 持有),供 Dashboard 读。
  (telemetry 是瞬时事件;此聚合器只为 operator 看板提供 per-session 累计视图。)
  """
  use GenServer

  @table :loom_stats_agg
  @event [:ezagent, :loom, :llm, :call]
  @handler "loom-stats-aggregator"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "读 session 累计统计 `%{input, output, calls}`。"
  def get(session_uri) do
    ensure_table()

    case :ets.lookup(@table, key(session_uri)) do
      [{_k, i, o, c}] -> %{input: i, output: o, calls: c}
      [] -> %{input: 0, output: 0, calls: 0}
    end
  end

  @doc false
  def handle_event(@event, measurements, %{session: session}, _cfg) when not is_nil(session) do
    ensure_table()

    :ets.update_counter(
      @table,
      key(session),
      [{2, measurements[:input_tokens] || 0}, {3, measurements[:output_tokens] || 0}, {4, 1}],
      {key(session), 0, 0, 0}
    )
  end

  def handle_event(_event, _measurements, _metadata, _cfg), do: :ok

  @impl true
  def init(:ok) do
    create_table()
    :telemetry.attach(@handler, @event, &__MODULE__.handle_event/4, nil)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler)

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined, do: create_table()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
