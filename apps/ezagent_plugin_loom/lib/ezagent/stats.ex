defmodule Ezagent.PluginLoom.Stats do
  @moduledoc """
  Loom **per-session 统计**(2026-06-12):token 消耗等。给 loom session 的 Dashboard tab。

  旁路 JSON(仿 Knowledge / Materials):`~/.ezagent/<profile>/loom_stats.json`,
  key = session 字符串(= claude_code `group`)→ 累计:

      %{ "session://loom/<ws>/<sid>" =>
           %{"input" => N, "output" => M, "calls" => K, "by_role" => %{"v0"=>%{...}, ...}} }

  token 由 `EzagentPluginLoom.ClaudeCode` 在每次 result 事件里抽 `usage` 累加(v0 /
  orchestrator / worker 都走 claude_code)。Stitch(DeepSeek)暂不计入。
  """

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

  @doc "累加一次 LLM 调用的 token(session = claude_code 的 group;role 如 v0/orch/worker)。"
  @spec add_tokens(String.t() | nil, integer(), integer(), String.t()) :: :ok
  def add_tokens(session, input, output, role \\ "other")

  def add_tokens(session, input, output, role)
      when is_binary(session) and session != "" and is_integer(input) and is_integer(output) do
    all = load_all()
    cur = Map.get(all, session, %{"input" => 0, "output" => 0, "calls" => 0, "by_role" => %{}})

    role_cur = get_in(cur, ["by_role", role]) || %{"input" => 0, "output" => 0, "calls" => 0}

    updated =
      cur
      |> Map.update("input", input, &(&1 + input))
      |> Map.update("output", output, &(&1 + output))
      |> Map.update("calls", 1, &(&1 + 1))
      |> put_in(["by_role", role], %{
        "input" => role_cur["input"] + input,
        "output" => role_cur["output"] + output,
        "calls" => role_cur["calls"] + 1
      })

    all |> Map.put(session, updated) |> save_all()
    :ok
  rescue
    _ -> :ok
  end

  def add_tokens(_, _, _, _), do: :ok

  @doc "读某 session 的统计(无 → 全 0)。"
  @spec get(String.t()) :: map()
  def get(session) when is_binary(session) do
    Map.get(load_all(), session, %{"input" => 0, "output" => 0, "calls" => 0, "by_role" => %{}})
  end

  def get(_), do: %{"input" => 0, "output" => 0, "calls" => 0, "by_role" => %{}}

  @doc "从 claude_code group + 当前调用方(self_uri 名段)推 role:v0 / orch / worker / stitch / meta / other。"
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
end
