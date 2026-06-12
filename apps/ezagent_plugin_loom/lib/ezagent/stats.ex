defmodule Ezagent.PluginLoom.Stats do
  @moduledoc """
  Loom **per-session 统计**(2026-06-12,v2 富化):token 消耗 / 成本 / 调用时间线等。
  给 loom session 的 Dashboard tab。

  旁路 JSON(仿 Knowledge / Materials):`~/.ezagent/<profile>/loom_stats.json`,
  key = session 字符串(= claude_code `group`)→ 累计:

      %{ "session://loom/<ws>/<sid>" => %{
           "input"          => N,    # 总 input(含 cache 读 + cache 写)
           "fresh_input"    => N,    # 非 cache 的 input_tokens
           "cache_read"     => N,    # cache_read_input_tokens
           "cache_creation" => N,    # cache_creation_input_tokens
           "output"         => N,
           "calls"          => K,
           "cost_usd"       => 1.23, # result 事件的 total_cost_usd 累加
           "duration_ms"    => N,    # 累计 wall-clock
           "first_at"       => iso8601,
           "last_at"        => iso8601,
           "by_role"        => %{"v0" => %{同上数值字段}, ...},
           "history"        => [%{"at","role","in","out","cost"} ...]  # 最近 60 次,新在后
         } }

  token / 成本由 `EzagentPluginLoom.ClaudeCode` 在每次 result 事件里抽 `usage` +
  `total_cost_usd` + `duration_ms`,经 `record/3` 累加(v0 / orchestrator / worker
  都走 claude_code)。Stitch(DeepSeek)暂不计入。
  """

  @num_fields ~w(input fresh_input cache_read cache_creation output cost_usd duration_ms)
  @history_cap 60

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_stats.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  @doc "一条 session 统计的空骨架(所有字段就位,给老文件 / 无数据兜底)。"
  def empty do
    base =
      Enum.into(@num_fields, %{}, fn k -> {k, 0} end)

    base
    |> Map.put("calls", 0)
    |> Map.put("first_at", nil)
    |> Map.put("last_at", nil)
    |> Map.put("by_role", %{})
    |> Map.put("history", [])
  end

  @doc """
  累加一次 LLM 调用。`session` = claude_code 的 group;`role` 如 v0/orchestrator/worker;
  `m` 是数值 map(原子键):`:input :fresh_input :cache_read :cache_creation :output
  :cost_usd :duration_ms`,可选 `:at`(iso8601)。
  """
  @spec record(String.t() | nil, String.t(), map()) :: :ok
  def record(session, role, m)
      when is_binary(session) and session != "" and is_binary(role) and is_map(m) do
    all = load_all()
    cur = Map.merge(empty(), Map.get(all, session, %{}))
    now = m[:at] || DateTime.utc_now() |> DateTime.to_iso8601()

    merged =
      cur
      |> bump(m)
      |> Map.put("first_at", cur["first_at"] || now)
      |> Map.put("last_at", now)
      |> Map.update("by_role", %{role => bump(%{}, m)}, fn br ->
        Map.update(br, role, bump(%{}, m), fn rc -> bump(rc, m) end)
      end)
      |> Map.update("history", [hist(role, m, now)], fn h ->
        (h ++ [hist(role, m, now)]) |> Enum.take(-@history_cap)
      end)

    all |> Map.put(session, merged) |> save_all()
    :ok
  rescue
    _ -> :ok
  end

  def record(_, _, _), do: :ok

  @doc "读某 session 的统计(无 → 空骨架)。"
  @spec get(String.t()) :: map()
  def get(session) when is_binary(session) do
    Map.merge(empty(), Map.get(load_all(), session, %{}))
  end

  def get(_), do: empty()

  @doc "从 claude_code group / 调用方 URI 推 role。"
  @spec role_of(String.t() | nil) :: String.t()
  def role_of(uri) when is_binary(uri) do
    cond do
      String.contains?(uri, "loomv0_") -> "v0"
      String.contains?(uri, "loomorch_") -> "orchestrator"
      String.contains?(uri, "loomstitchsub_") -> "stitch-worker"
      String.contains?(uri, "loomstitch_") -> "stitch"
      String.contains?(uri, "loommeta_") -> "meta"
      String.contains?(uri, "loomworker_") -> "worker"
      true -> "other"
    end
  end

  def role_of(_), do: "other"

  # --- internals ---

  # 把一次调用的数值字段累加进 acc(空 acc 也成 —— Map.update 用 v 做缺省)。
  defp bump(acc, m) do
    acc =
      Enum.reduce(@num_fields, acc, fn k, a -> add(a, k, Map.get(m, String.to_atom(k))) end)

    Map.update(acc, "calls", 1, &(&1 + 1))
  end

  defp add(map, _key, nil), do: map
  defp add(map, key, v) when is_number(v), do: Map.update(map, key, v, &(&1 + v))
  defp add(map, _key, _), do: map

  defp hist(role, m, now) do
    %{
      "at" => now,
      "role" => role,
      "in" => m[:input] || 0,
      "out" => m[:output] || 0,
      "cost" => m[:cost_usd] || 0
    }
  end
end
