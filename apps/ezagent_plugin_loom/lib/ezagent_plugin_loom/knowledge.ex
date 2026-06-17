defmodule EzagentPluginLoom.Knowledge do
  @moduledoc """
  Loom **知识库**(独有功能):编辑者写一段 Markdown,作为 Stitch / AiSpot 的 grounding
  (访客提问时据此作答)。per-session,随 fork 复制。ETS(本 GenServer 持有)。
  """
  use GenServer

  @table :loom_knowledge

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "写入(覆盖)session 知识库。"
  def put(session_uri, markdown) when is_binary(markdown) do
    ensure_table()
    :ets.insert(@table, {URI.to_string(session_uri), markdown})
    :ok
  end

  @doc "读 session 知识库(无 → nil)。"
  def get(session_uri) do
    ensure_table()

    case :ets.lookup(@table, URI.to_string(session_uri)) do
      [{_k, md}] -> md
      [] -> nil
    end
  end

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
