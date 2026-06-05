defmodule Ezagent.PluginLoom.UserSchema do
  @moduledoc """
  Per-session **user_schema** —— loom 发布页"可增强"模型的每用户操作序列(v0)。

  ## 模型

  最终页面 = 渲染(发布物 base) ⊕ 应用(user_schema 的 op 序列)。base 是不可变的
  冻结模板页(所有访客共享);user_schema 是**从属于某个 session** 的一串 op,
  每个访客 session 一份,空白起步。引擎(前端)按 op 序列在 base 上叠加,得到该
  访客最终看到的页面。

  ## 持久化(v0:旁路 JSON)

  `~/.ezagent/<EZAGENT_PROFILE>/loom_user_schemas.json`:

      %{ "session://loom/<ws>/<sid>" => [op, op, ...] }

  key = canonical session URI 字符串 → "从属于 session"。刷新会建新 session(新 key、
  空序列),**旧 session 的序列保留不删**(内部测试阶段,接受累积)。

  > v0 刻意用旁路 JSON 求快;架构正确的归宿是把 user_schema 存进 session 的一个
  > slice(随快照持久)。迁移时把本模块的 get/append 换成 slice 读写即可,端点不变。

  ## op 形状(v0 不约束,前端引擎解释)

  本模块只负责**存/取 op 列表**,不解释 op 语义(前端引擎定义)。v0 第一个 op:

      %{"op" => "addText", "id" => "op_xxx", "position" => "top", "text" => "...", "style" => %{}}
  """

  require Logger

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_user_schemas.json")
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

  defp key(ws, sid), do: "session://loom/#{ws}/#{sid}"

  @doc "读某 session 的 op 列表(无则空列表)。"
  @spec get(String.t(), String.t()) :: [map()]
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), key(ws, sid)) do
      ops when is_list(ops) -> ops
      _ -> []
    end
  end

  @doc """
  往某 session 的 op 列表**追加一个 op**,持久化,返回更新后的完整列表。
  `op` 必须是 map(否则 `{:error, :invalid_op}`)。
  """
  @spec append(String.t(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def append(ws, sid, op) when is_binary(ws) and is_binary(sid) and is_map(op) do
    k = key(ws, sid)
    all = load_all()

    existing =
      case Map.get(all, k) do
        ops when is_list(ops) -> ops
        _ -> []
      end

    updated = existing ++ [op]
    save_all(Map.put(all, k, updated))
    {:ok, updated}
  end

  def append(_ws, _sid, _op), do: {:error, :invalid_op}

  @doc """
  整盘**替换**某 session 的 op 列表(fork 时把快照的 ops 复制进新 session 用)。
  `ops` 非列表 → `{:error, :invalid_ops}`。
  """
  @spec replace(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def replace(ws, sid, ops) when is_binary(ws) and is_binary(sid) and is_list(ops) do
    all = load_all()
    save_all(Map.put(all, key(ws, sid), ops))
    {:ok, ops}
  end

  def replace(_ws, _sid, _ops), do: {:error, :invalid_ops}
end
