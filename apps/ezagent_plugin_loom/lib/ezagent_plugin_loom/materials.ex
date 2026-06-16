defmodule EzagentPluginLoom.Materials do
  @moduledoc """
  Loom **素材库**(务实版,对接 `Ezagent.Uploads`)。

  上传的素材文件落 `Ezagent.Uploads.store!`(workspace 受控存储),loom 维护 per-session
  素材清单(ETS,本 GenServer 持有)供列表 + 编排器 compose 时注入(让 v0 知道有哪些素材可引用)。
  弃旧 loom「目录即库 + 裸 FS 服务」,文件服务走 `Uploads.DownloadToken`(受控,红线 #6)。
  """
  use GenServer

  @table :loom_materials

  # --- API ------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "记录一个 session 素材(uri + 展示名)。"
  def register(session_uri, %URI{} = resource_uri, name) when is_binary(name) do
    ensure_table()
    key = URI.to_string(session_uri)
    entry = %{uri: URI.to_string(resource_uri), name: name}
    existing = list(session_uri)
    :ets.insert(@table, {key, existing ++ [entry]})
    :ok
  end

  @doc "列出 session 素材清单 `[%{uri, name}]`。"
  def list(session_uri) do
    ensure_table()

    case :ets.lookup(@table, URI.to_string(session_uri)) do
      [{_k, entries}] -> entries
      [] -> []
    end
  end

  @doc "供 compose prompt 注入的素材清单文本(无素材 → nil)。"
  def prompt_block(session_uri) do
    case list(session_uri) do
      [] -> nil
      entries -> entries |> Enum.map_join("\n", &"- #{&1.name}: #{&1.uri}") |> then(&("可引用的素材：\n" <> &1))
    end
  end

  # --- GenServer ------------------------------------------------------------

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

  # 测试/未起 GenServer 时容错建表(隔离 DataCase)。
  defp ensure_table do
    if :ets.whereis(@table) == :undefined, do: create_table()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
