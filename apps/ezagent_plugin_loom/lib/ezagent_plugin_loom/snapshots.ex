defmodule EzagentPluginLoom.Snapshots do
  @moduledoc """
  Loom **发布/分享** 快照存储:把一个 loom session 当前页冻结成不可变副本,token 寻址,
  返回分享链接 `/loom/p/<token>`。迁移自 loom-stitch `Snapshots`(那边落 JSON 文件;
  本迁移用 ETS,server 生命周期内有效,够 demo/内部用)。

  value = `%{"ws","origin_sid","page","ops","conversation","knowledge","created_at"}`,
  `page` = 冻结时的 page_update map(`%{"files","source","summary"}`)。
  """
  use GenServer

  @table :loom_snapshots

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "写一份快照(key=token)。"
  @spec put(String.t(), map()) :: :ok
  def put(token, %{} = data) when is_binary(token) and token != "" do
    ensure_table()
    :ets.insert(@table, {token, data})
    :ok
  end

  @doc "读一份快照,无 → `:error`。"
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(token) when is_binary(token) and token != "" do
    ensure_table()

    case :ets.lookup(@table, token) do
      [{_t, data}] -> {:ok, data}
      [] -> :error
    end
  end

  def get(_), do: :error

  @doc "列出某 workspace 的全部快照(新的在前),每条带 token + link。"
  @spec list_for_ws(String.t()) :: [map()]
  def list_for_ws(ws) when is_binary(ws) do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.filter(fn {_t, d} -> Map.get(d, "ws") == ws end)
    |> Enum.map(fn {token, d} ->
      %{
        token: token,
        link: "/loom/p/#{token}",
        published_from: Map.get(d, "origin_sid"),
        created_at: Map.get(d, "created_at")
      }
    end)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "生成一个 16-hex token。"
  @spec mint_token() :: String.t()
  def mint_token, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

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
