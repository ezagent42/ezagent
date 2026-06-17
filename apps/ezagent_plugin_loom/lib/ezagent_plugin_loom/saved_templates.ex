defmodule EzagentPluginLoom.SavedTemplates do
  @moduledoc """
  Loom **存为模板**:把一个 loom session 当前 approved 页存成 per-workspace 可复用模板,
  供新建 session 时 seed(见 `LoomSession.instantiate` 的 `saved_template` 入参)。

  ETS(本 GenServer 持有),key = workspace name,value = `[%{name, tree}]`(同名覆盖)。
  """
  use GenServer

  @table :loom_saved_templates

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "存(覆盖同名)一张 workspace 级模板。"
  @spec save(String.t(), String.t(), map()) :: :ok
  def save(ws, name, tree)
      when is_binary(ws) and is_binary(name) and name != "" and is_map(tree) do
    ensure_table()
    others = Enum.reject(list(ws), &(&1.name == name))
    :ets.insert(@table, {ws, others ++ [%{name: name, tree: tree}]})
    :ok
  end

  @doc "列出某 workspace 的全部模板 `[%{name, tree}]`。"
  @spec list(String.t()) :: [%{name: String.t(), tree: map()}]
  def list(ws) when is_binary(ws) do
    ensure_table()

    case :ets.lookup(@table, ws) do
      [{_k, items}] -> items
      [] -> []
    end
  end

  @doc "取某模板(无 → nil)。"
  @spec get(String.t(), String.t()) :: %{name: String.t(), tree: map()} | nil
  def get(ws, name) when is_binary(ws) and is_binary(name) do
    Enum.find(list(ws), &(&1.name == name))
  end

  @doc "按名删除。"
  @spec delete(String.t(), String.t()) :: :ok
  def delete(ws, name) when is_binary(ws) and is_binary(name) do
    ensure_table()
    kept = Enum.reject(list(ws), &(&1.name == name))
    :ets.insert(@table, {ws, kept})
    :ok
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
