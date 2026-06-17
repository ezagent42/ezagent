defmodule EzagentPluginLoom.MetaAgent do
  @moduledoc """
  Loom **团队管家**(loommeta):@自然语言增删改 session 的 worker team。

  一次 @ = 一次 LLM(把指令解析成 op)= 一次对 `WorkerConfig` 的操作。
  op ∈ add / remove / list / clarify。务实版(不 Kind 化);团队成员是 WorkerConfig roster,
  编排器 decompose 据此分工。
  """

  alias EzagentPluginLoom.{Json, LLM, WorkerConfig}

  @doc """
  解释并执行一条改-team 指令。返回 `{:ok, %{op, workers | message}}` | `{:error, reason}`。
  """
  @spec interpret(URI.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def interpret(%URI{} = session_uri, instruction, opts \\ []) when is_binary(instruction) do
    current = WorkerConfig.list(session_uri)

    system = """
    你是 loom 团队管家。当前 worker team:
    #{format_team(current)}

    把访客/编辑者的指令解析成一个操作。严格只输出 JSON,不要 markdown:
    - 增加: {"op":"add","worker":{"key":"slug","desc":"一句职责","prompt":"系统提示"}}
    - 删除: {"op":"remove","key":"要删的 key"}
    - 查看: {"op":"list"}
    - 看不懂: {"op":"clarify","message":"反问一句"}
    key 用小写 slug(^[a-z][a-z0-9_]*$)。
    """

    with {:ok, text} <- LLM.chat([%{role: "user", content: instruction}], Keyword.put(opts, :system, system)),
         {:ok, %{"op" => op} = parsed} <- Json.extract_object(text) do
      apply_op(session_uri, op, parsed)
    else
      _ -> {:error, :meta_failed}
    end
  end

  defp apply_op(session_uri, "add", %{"worker" => %{} = worker}) do
    :ok = WorkerConfig.add(session_uri, worker)
    {:ok, %{op: "add", workers: WorkerConfig.list(session_uri)}}
  end

  defp apply_op(session_uri, "remove", %{"key" => k}) when is_binary(k) do
    :ok = WorkerConfig.remove(session_uri, k)
    {:ok, %{op: "remove", workers: WorkerConfig.list(session_uri)}}
  end

  defp apply_op(session_uri, "list", _),
    do: {:ok, %{op: "list", workers: WorkerConfig.list(session_uri)}}

  defp apply_op(_session_uri, "clarify", parsed),
    do: {:ok, %{op: "clarify", message: parsed["message"] || "请再说明一下你想怎么改团队。"}}

  defp apply_op(_session_uri, _op, _parsed), do: {:error, :unknown_op}

  defp format_team([]), do: "(空)"

  defp format_team(workers),
    do: Enum.map_join(workers, "\n", &"- #{&1["key"]}: #{&1["desc"]}")
end
