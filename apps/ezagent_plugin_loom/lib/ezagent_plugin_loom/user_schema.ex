defmodule EzagentPluginLoom.UserSchema do
  @moduledoc """
  Loom **per-visitor 页面增强**(清单 D — 按用户要求**保留在 loom 内部**实现)。

  最终页 = base(approved surface,所有访客共享) ⊕ 应用(本访客 op 序列)。socialware 的 Surface
  无 per-visitor 层,故 loom 在 plugin 内自维护 per-(session, visitor) op 序列(ETS),customer
  读 feed 时附带本访客 ops,**叠加在前端完成**(op 语义由前端定义,后端只存序列、不改 surface)。

  visitor 身份由前端提供(stable visitor id);不碰 socialware customer 边界、不改 surface。
  """
  use GenServer

  @table :loom_user_schema

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "给 (session, visitor) 追加一个增强 op。"
  def add(session_uri, visitor, op) when is_binary(visitor) do
    ensure_table()
    k = key(session_uri, visitor)
    :ets.insert(@table, {k, ops(session_uri, visitor) ++ [op]})
    :ok
  end

  @doc "读 (session, visitor) 的 op 序列(无 → [])。"
  def ops(session_uri, visitor) when is_binary(visitor) do
    ensure_table()

    case :ets.lookup(@table, key(session_uri, visitor)) do
      [{_k, list}] -> list
      [] -> []
    end
  end

  # --- session 级 ops(前端 /api/:ws/:sid/user-schema:发布页增强,非 per-visitor)---
  @doc "读 session 级 op 序列(无 → [])。"
  def session_ops(session_uri) do
    ensure_table()

    case :ets.lookup(@table, session_key(session_uri)) do
      [{_k, list}] -> list
      [] -> []
    end
  end

  @doc "session 级追加一个 op。"
  def append_session_op(session_uri, op) do
    ensure_table()
    :ets.insert(@table, {session_key(session_uri), session_ops(session_uri) ++ [op]})
    {:ok, session_ops(session_uri)}
  end

  @doc "session 级整盘替换。"
  def replace_session_ops(session_uri, ops) when is_list(ops) do
    ensure_table()
    :ets.insert(@table, {session_key(session_uri), ops})
    {:ok, ops}
  end

  @impl true
  def init(:ok) do
    create_table()
    {:ok, %{}}
  end

  defp key(session_uri, visitor), do: {URI.to_string(session_uri), visitor}
  defp session_key(session_uri), do: {URI.to_string(session_uri), :__session__}

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
