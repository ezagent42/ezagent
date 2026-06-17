defmodule EzagentPluginLoom.StitchExperts do
  @moduledoc """
  Stitch 完整体系的角色集 + per-role prompt/parser(文档:orchestrator over 4 real workers)。

  4 固定 role(chat/navigation/controls/content),每 preview turn:route(选相关 role)→ 并发
  调各 role 产 `stitch_part`(say + 可选 drive)→ compose 合成一条回复 + drives。

  ⚠️ 形态说明:文档原设计是 4 个**真实 socialware agent Kind**(loomstitchsub_<sid>_<role>),
  经 turn.dispatch/deliver fan-out。这里是**务实版**——编排逻辑内的 4-role 并发 LLM(产出等价),
  与主编排(orchestrator.ex)同款务实策略。Kind 化随主编排真实 agent 化(项 3)一起,待 Allen 架构决策。
  """

  alias EzagentPluginLoom.{Json, LLM}

  @roles [
    %{key: "chat", label: "Chat", desc: "一般问答与寒暄"},
    %{key: "navigation", label: "Navigation", desc: "切换视图、对比、跳转"},
    %{key: "controls", label: "Controls", desc: "筛选、高亮、步进、展开"},
    %{key: "content", label: "Content", desc: "解释页面内容"}
  ]

  @role_keys Enum.map(@roles, & &1.key)
  @worker_timeout_ms 120_000

  def roles, do: @roles
  def role_keys, do: @role_keys

  @doc """
  route:选出与访客诉求相关的 role(0 个 → fast 单 agent 兜底由调用方处理)。
  返回 `{:ok, [role_key]}` | `{:error, reason}`。
  """
  def route(user_text, opts \\ []) when is_binary(user_text) do
    system = """
    你是 Stitch 路由器。给定访客在发布页的诉求,从这些 role 里选出相关的(可多选,通常 1-2 个):
    #{Enum.map_join(@roles, "; ", &"#{&1.key}(#{&1.desc})")}
    严格只输出 JSON: {"roles": ["role_key", ...]}。简单寒暄/无关 → 空数组。
    """

    with {:ok, text} <- LLM.chat([%{role: "user", content: user_text}], Keyword.put(opts, :system, system)),
         {:ok, %{"roles" => roles}} when is_list(roles) <- Json.extract_object(text) do
      {:ok, Enum.filter(roles, &(&1 in @role_keys))}
    else
      _ -> {:error, :route_failed}
    end
  end

  @doc "并发让选中的 role 各产一个 stitch_part `%{role, say, drive}`。"
  def gather(user_text, role_keys, opts \\ []) when is_list(role_keys) do
    role_keys
    |> Task.async_stream(fn rk -> role_part(user_text, rk, opts) end,
      timeout: @worker_timeout_ms,
      max_concurrency: length(@roles),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, part}} -> [part]
      _ -> []
    end)
  end

  defp role_part(user_text, role_key, opts) do
    role = Enum.find(@roles, &(&1.key == role_key))

    system = """
    你是 Stitch 的「#{role.label}」专员(#{role.desc})。针对访客诉求,从本职角度给一句简短中文回应,
    若可转成页面操作则给 drive。严格只输出 JSON: {"say": "一句中文", "drive": {"op": "...", "args": {}} 或 null}
    """

    with {:ok, text} <- LLM.chat([%{role: "user", content: user_text}], Keyword.put(opts, :system, system)),
         {:ok, %{"say" => say}} when is_binary(say) <- Json.extract_object(text) do
      {:ok, %{role: role_key, say: say, drive: parse_drive(text)}}
    else
      _ -> {:error, :role_failed}
    end
  end

  defp parse_drive(text) do
    case Json.extract_object(text) do
      {:ok, %{"drive" => %{"op" => op} = drive}} when is_binary(op) -> drive
      _ -> nil
    end
  end
end
