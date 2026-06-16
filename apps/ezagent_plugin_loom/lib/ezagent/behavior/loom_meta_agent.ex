defmodule Ezagent.Behavior.LoomMetaAgent do
  @moduledoc """
  Loom 团队管家 Behavior。

  ## Mention-gated

  跟 `LoomWorker` / `LoomBuilderWorker` 一样 — `handle_receive` 只在被 @ 时
  动手。其它消息(orchestrator 派单、worker reply 互相走)一律忽略。

  ## 一次 @,一次 DeepSeek,一次 op

  调用 `EzagentPluginLoom.DeepSeek.chat/2`,用 `Prompts.meta_system_prompt/1`
  把当前 chat.members 中的 worker 列表注进 prompt(让模型知道有谁,避免
  乱删 / 重复加)。模型出 JSON,parse → 执行。

  ## 失败兜底

  - DeepSeek 失败 → 回复 ":api_error"
  - JSON 解析失败 → 回复 "我没看懂,再说一下"
  - op 未知 → 用模型自己产出的 clarify 问回去

  ## 副作用 = 底层原语组合,**无新 action,无新 caps**

  - add: `Ezagent.Kind.spawn(LoomWorker, ...)` + dispatch `chat.join`
  - remove: dispatch `chat.leave` + `Ezagent.Kind.terminate(...)`
  - list: 读 chat.members,chat.send 回复文本
  - unknown: chat.send 回复 clarify

  chat.join / chat.leave 的 caller 都是 `system://session-internal`
  (`cap(:any, Chat, :any)` 已经覆盖,跟 Team.ensure_team 的 join_step
  完全同一条路径)。
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginLoom.{LLM, Prompts, Span}

  # 预制 worker(用户不能误删 — manager 在 prompt 里就说不能删,但代码也兜底)。
  @builtin_themes ~w(policy company)
  @builtin_kinds ~w(v0 loombuilder)

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom team manager — parse natural-language team mod via local Claude Code, emit spawn/join or leave/terminate effects"
  )

  def required_caps do
    %{receive: Ezagent.Capability.cap(:loommeta, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_meta

  def init_slice(_args) do
    %{count: 0, last_error: nil}
  end

  # ---------------------------------------------------------------
  # handle_<action>/2
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    if addressed_to_self?(msg, ctx) do
      handle_at_me(msg, ctx)
    else
      {:ok, %{}, []}
    end
  end

  defp handle_at_me(%Message{} = msg, ctx) do
    session_uri = session_from_ctx(ctx)
    text = extract_text(msg.body)
    count = ctx[:read].(:count, 0)

    case session_uri do
      nil ->
        {:ok, %{}, []}

      %URI{} = suri ->
        workers_summary = current_workers_summary(suri)

        case LLM.chat(
               [
                 %{"role" => "system", "content" => Prompts.meta_system_prompt(workers_summary)},
                 %{"role" => "user", "content" => text}
               ],
               temperature: 0.2,
               thinking_disabled: true,
               group: URI.to_string(suri)
             ) do
          # 用户中止 → 静默。
          {:error, :stopped} ->
            {:ok, %{}, []}

          {:ok, raw} ->
            case parse_op(raw) do
              {:ok, op} ->
                effects = execute_op(op, ctx, suri, msg)
                {:ok, %{}, [{:set, :count, count + 1}, {:set, :last_error, nil}] ++ effects}

              :error ->
                {:ok, %{},
                 [{:set, :last_error, :parse_failed}] ++
                   reply_text(ctx, msg, "我没看懂这条指令。再具体说一下,比如「加一个 painter,负责出配色和背景图建议」。")}
            end

          {:error, reason} ->
            {:ok, %{},
             [{:set, :last_error, reason}] ++
               reply_text(ctx, msg, human_friendly_api_error(reason))}
        end
    end
  end

  # 本地 Claude Code 调用故障的友好回复 — 不出 raw Erlang term。
  # (错误形状来自 `EzagentPluginLoom.LLM.chat/2`。)
  defp human_friendly_api_error(:claude_not_found),
    do: "本机没找到 claude 命令。让运维确认 Claude Code 已安装且在 PATH 上。"

  defp human_friendly_api_error(:timeout),
    do: "Claude Code 这次响应超时了(可能在算长 prompt),再说一遍试试。"

  defp human_friendly_api_error({:spawn, _}),
    do: "起不了 claude 进程,让运维看一下。"

  defp human_friendly_api_error({:exit, _status, _out}),
    do: "Claude Code 进程异常退出,等一下再试。"

  defp human_friendly_api_error({:claude_error, _}),
    do: "Claude Code 返回了错误,等一下再试。"

  defp human_friendly_api_error({:decode, _, _}),
    do: "Claude Code 返回的内容没法解析,再说一遍试试。"

  defp human_friendly_api_error({:decode, _}),
    do: "Claude Code 返回的内容没法解析,再说一遍试试。"

  defp human_friendly_api_error(other),
    do: "调用出错:#{inspect(other)}。再说一遍试试。"

  # ---------------------------------------------------------------
  # DeepSeek JSON parse
  # ---------------------------------------------------------------

  defp parse_op(raw) do
    case Span.extract_first_json_object(raw) do
      nil ->
        :error

      json_str ->
        case Jason.decode(json_str) do
          {:ok, %{"op" => "add", "theme" => theme} = obj} when is_binary(theme) and theme != "" ->
            {:ok,
             {:add,
              %{
                theme: theme,
                role_desc: to_string(obj["role_desc"] || theme),
                system_prompt: to_string(obj["system_prompt"] || "")
              }}}

          {:ok, %{"op" => "remove", "theme" => theme}} when is_binary(theme) and theme != "" ->
            {:ok, {:remove, theme}}

          {:ok, %{"op" => "list"}} ->
            {:ok, :list}

          {:ok, %{"op" => "unknown", "clarify" => clarify}} when is_binary(clarify) ->
            {:ok, {:unknown, clarify}}

          _ ->
            :error
        end
    end
  end

  # ---------------------------------------------------------------
  # Op executors → effect lists
  # ---------------------------------------------------------------

  defp execute_op({:add, %{theme: theme} = spec}, ctx, session_uri, msg) do
    cond do
      not theme_valid?(theme) ->
        reply_text(
          ctx,
          msg,
          "theme「#{theme}」不合法。只能用小写英文 + 数字 + 下划线(如 painter / lawyer / data_analyst)。"
        )

      theme in @builtin_themes or theme in @builtin_kinds ->
        reply_text(ctx, msg, "「#{theme}」是预制 worker,不需要再加,session 启动时已经在了。")

      true ->
        do_add(theme, spec, ctx, session_uri, msg)
    end
  end

  defp execute_op({:remove, theme}, ctx, session_uri, msg) do
    cond do
      theme in @builtin_themes ->
        reply_text(ctx, msg, "「#{theme}」是预制 worker,我不能删它。要删自定义加的 worker 才行。")

      theme in @builtin_kinds ->
        reply_text(ctx, msg, "「#{theme}」是预制 worker,我不能删它。")

      true ->
        do_remove(theme, ctx, session_uri, msg)
    end
  end

  defp execute_op(:list, ctx, session_uri, msg) do
    workers = workers_in_session(session_uri)

    text =
      case workers do
        [] ->
          "当前没有自定义 worker。预制的 policy / company / v0 一直都在。"

        list ->
          rows =
            Enum.map(list, fn w ->
              "• #{w.theme}#{if w.role != "" and w.role != "worker", do: " — " <> w.role, else: ""}"
            end)

          "当前 worker:\n" <> Enum.join(rows, "\n")
      end

    reply_text(ctx, msg, text)
  end

  defp execute_op({:unknown, clarify}, ctx, _session_uri, msg) do
    reply_text(ctx, msg, clarify)
  end

  # ---------------------------------------------------------------
  # add / remove 的实际副作用
  # ---------------------------------------------------------------

  defp do_add(theme, %{role_desc: role_desc, system_prompt: sp}, ctx, session_uri, msg) do
    {ws, sid} = session_parts(session_uri)
    new_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{theme}")

    resolved_sp =
      if sp == "" do
        # fallback:DeepSeek 没生成,自己拼一个最简版本
        "你是Loom 孵化器编排团队的【#{theme}】worker(#{role_desc})。编排器交给你一个子任务时,只产出对应方面的内容片段:中文、简洁、可合理虚构使其逼真,不寒暄,不输出卡片或 JSON,只回正文片段。"
      else
        sp
      end

    # 在 Behavior handle_receive 内直接同步调用 `Kind.spawn` —— 不走 effect 路径
    # (effect 是给 state-mutation / dispatch 用的,在 `:effect, fn, args` 的 3-tuple
    # 形式)。Kind.spawn 是 framework 同步 API,handler 里直接调安全。
    _ =
      case Ezagent.Kind.spawn(Ezagent.Entity.LoomWorker, %{
             uri: new_uri,
             role: theme,
             system_prompt: resolved_sp
           }) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning("meta: spawn worker #{theme} failed: #{inspect(reason)}")
      end

    card =
      Span.span("team_change", %{
        "op" => "add",
        "theme" => theme,
        "role_desc" => role_desc,
        "uri" => URI.to_string(new_uri),
        "text" => "已加入 #{theme} worker(#{role_desc})"
      })

    # chat.join 走 session-internal 主体(跟 Team.ensure_team 同款)
    [{:dispatch, join_cmd(session_uri, new_uri)}] ++ reply_with_body(ctx, msg, card)
  end

  defp do_remove(theme, ctx, session_uri, msg) do
    {ws, sid} = session_parts(session_uri)
    target_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{theme}")

    # 检查这条 URI 是不是真的在 session 里 — 不在的话回个友好提示
    workers = workers_in_session(session_uri)
    present? = Enum.any?(workers, fn w -> w.theme == theme end)

    if not present? do
      reply_text(ctx, msg, "「#{theme}」worker 当前不在 session 里,无需删除。")
    else
      # 同上 — terminate 走同步 framework API,不走 effect 系统。
      # 注意:terminate 必须在 chat.leave dispatch 之后才被调,但 Kind.terminate
      # 是同步的会立刻杀进程,而 dispatch 是 cast 异步。两者顺序可能颠倒。
      # 影响不大:就算 terminate 先发生,chat.leave 还是能 dispatch 成功
      # (Behavior.Chat.handle_leave 通过 URI 拆掉 members 那条),但 monitor 已经
      # 没机会触发 :DOWN(终止已发生)。最终 members 没那位,符合预期。
      card =
        Span.span("team_change", %{
          "op" => "remove",
          "theme" => theme,
          "uri" => URI.to_string(target_uri),
          "text" => "已移除 #{theme} worker"
        })

      effects =
        [{:dispatch, leave_cmd(session_uri, target_uri)}] ++ reply_with_body(ctx, msg, card)

      _ = Ezagent.Kind.terminate(target_uri)
      effects
    end
  end

  defp join_cmd(session_uri, member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    Cmd.new(target, :join, %{member: member_uri}, %{
      caller: Ezagent.SystemPrincipal.uri("session-internal"),
      caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
      reply: :ignore
    })
  end

  defp leave_cmd(session_uri, member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.leave")

    Cmd.new(target, :leave, %{member: member_uri}, %{
      caller: Ezagent.SystemPrincipal.uri("session-internal"),
      caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
      reply: :ignore
    })
  end

  # ---------------------------------------------------------------
  # 看当前 session 有什么 worker
  # ---------------------------------------------------------------

  defp current_workers_summary(session_uri) do
    workers = workers_in_session(session_uri)

    if workers == [] do
      "(只有预制的 policy、company、v0)"
    else
      base = "policy(政策侧),company(企业侧),v0(改页面)"
      custom = Enum.map(workers, fn w -> "#{w.theme}(#{w.role})" end) |> Enum.join(",")
      base <> ",以及:" <> custom
    end
  end

  # 扫 session 的 chat.members,只拿 loomworker_<sid>_<theme> 这种自定义(非预制)。
  defp workers_in_session(%URI{} = session_uri) do
    {_ws, sid} = session_parts(session_uri)

    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members}} when is_map(members) ->
        members
        |> Map.keys()
        |> Enum.flat_map(fn member_uri -> match_custom_worker(member_uri, sid) end)
        |> Enum.sort_by(& &1.theme)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp match_custom_worker(%URI{path: "/" <> rest} = uri, sid) do
    case String.split(rest, "/") do
      [_ws, name] ->
        prefix = "loomworker_#{sid}_"

        if String.starts_with?(name, prefix) do
          theme = String.replace_prefix(name, prefix, "")
          # 排除预制 theme(theme name 撞上 policy/company 的可能性微乎其微,
          # 因为预制 worker URI 本来就是 loomworker_<sid>_policy 命中,而我们 list 全列)
          if theme in @builtin_themes do
            [%{theme: theme, role: "(预制)", uri: uri}]
          else
            role = read_worker_role(uri)
            [%{theme: theme, role: role, uri: uri}]
          end
        else
          []
        end

      _ ->
        []
    end
  end

  defp match_custom_worker(_, _), do: []

  defp read_worker_role(worker_uri) do
    case Ezagent.Kind.get_slice(worker_uri, :loom_worker) do
      {:ok, %{role: r}} when is_binary(r) -> r
      _ -> ""
    end
  end

  # ---------------------------------------------------------------
  # validators
  # ---------------------------------------------------------------

  defp theme_valid?(theme) when is_binary(theme),
    do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, theme)

  defp theme_valid?(_), do: false

  # ---------------------------------------------------------------
  # URI 拆分
  # ---------------------------------------------------------------

  defp session_parts(%URI{path: "/" <> rest}) do
    case String.split(rest, "/") do
      [ws, sid | _] -> {ws, sid}
      _ -> {nil, nil}
    end
  end

  defp session_parts(_), do: {nil, nil}

  # ---------------------------------------------------------------
  # boilerplate(copy LoomBuilderWorker pattern)
  # ---------------------------------------------------------------

  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)

    Enum.any?(mentions, fn
      %URI{} = m -> URI.to_string(m) == self_str
      _ -> false
    end)
  end

  defp addressed_to_self?(_, _), do: false

  defp reply_text(ctx, msg, text) when is_binary(text), do: reply_with_body(ctx, msg, text)

  defp reply_with_body(ctx, %Message{} = subtask_msg, body_text) when is_binary(body_text) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{scheme: "session"} = session_uri <- session_from_ctx(ctx) do
      reply =
        Message.new(self_uri, %{text: body_text, attachments: []},
          ref_id: subtask_msg.id,
          mentions: [subtask_msg.sender]
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      cmd =
        Cmd.new(target, :send, %{message: reply}, %{
          caller: self_uri,
          caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
          reply: :ignore
        })

      [{:dispatch, cmd}]
    else
      _ -> []
    end
  end

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_from_ctx(_), do: nil

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  def data_owner(_), do: :no_owner
end
