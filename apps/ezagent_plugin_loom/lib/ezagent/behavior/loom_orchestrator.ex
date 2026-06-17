defmodule Ezagent.Behavior.LoomOrchestrator do
  @moduledoc """
  Loom orchestrator Behavior (loom v0.2, G-D) — a DeepSeek-brained
  session member that, per user turn, **decomposes → fans out to workers
  → aggregates → composes one scene-card reply**.

  ## New-contract migration (2026-05-29)

  `use Ezagent.Behavior` + `action :receive`; `invoke(:receive, ...)` →
  `handle_receive(args, ctx)` returning effects. Slice reads via
  `ctx[:read]`; fan-out subtasks + the composed reply are `{:dispatch,
  %Cmd{}}` effects in the action path. The aggregation TIMEOUT still uses
  `Process.send_after(self(), {:agg_timeout, turn_id}, _)` (the handler
  runs in the Kind.Server process) caught by `handle_kind_message/3` (a
  Kind.Server lifecycle hook — NOT an action handler, so it dispatches the
  partial-result reply via `Ezagent.Router.dispatch/1` directly).

  ## Two-phase brain (PRD §5.3)

  1. **Dispatch** — one DeepSeek call emits `{"dispatch":[{"to":...,
     "task":...}]}`, parsed by `parse_dispatch/2`. Every turn MUST dispatch;
     only parse failure / empty / no-roster degrades to a direct answer.
  2. **Compose** — when worker deliverables are collected (or on timeout),
     one DeepSeek call folds the fragments into ONE scene card;
     `Span.normalize/1` does the componentization.

  ## Fan-out + aggregation (PRD §5.3 方案 B, §8)

  Subtasks go out @mentioning each worker; workers reply with
  `ref_id = subtask_id`. The pending turn lives in the `:loom_orchestrator`
  slice keyed by `turn_id` (= user message id). On completion the pending
  turn is deleted so the later timeout finds nothing and no-ops.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginLoom.{LLM, Span, Prompts}

  # 聚合**兜底**超时(2026-06-02 重构):正常完成是**事件驱动**的 —— worker 不管
  # 成功/失败都必回一条 deliverable,`handle_deliverable` 收齐即合成,**与 model 多慢
  # 无关**。这个超时只在 worker 进程**真死了、永不回复**时兜底,所以不该手猜一个跟
  # model 速度赛跑的常数,而是从 worker 自己的时间上界推导:`LLM.max_run_ms()`
  # (单次调用最大墙钟 = 超时 × 尝试 + 退避)再加余量。这样换慢 model / 调大 worker
  # 超时,兜底自动跟着放大,永远只在真异常时触发。
  @agg_margin_ms 30_000

  defp agg_timeout_ms, do: EzagentPluginLoom.LLM.max_run_ms() + @agg_margin_ms

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom orchestrator — decompose a user turn, fan out to workers, aggregate, reply one scene card"
  )

  # Pin the kind axis `:loomorch` (macro's auto-derived default is `:any`).
  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomorch, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_orchestrator

  def init_slice(args) do
    %{
      persona: to_string(Map.get(args, :persona) || Map.get(args, "persona") || "visitor"),
      workers: normalize_workers(Map.get(args, :workers) || Map.get(args, "workers") || []),
      pending: %{},
      count: 0,
      last_error: nil,
      # 2026-06-01 redesign / 2026-06-02 多文件: cached page source —— 现为
      # **files map** `%{path => content}`。每当 v0 发 `<span type="page_update">`
      # 就整体替换(handle_page_update)。Seeded from args :initial_loom_source
      # (LoomSavedSession 传 saved snapshot;LoomSession 用 seed)。旧字符串值经
      # `normalize_source` 归一成 `%{"/App.jsx" => str}`,兼容旧快照/saved template。
      loom_source:
        Prompts.normalize_source(
          Map.get(args, :initial_loom_source) || Map.get(args, "initial_loom_source") ||
            Prompts.loom_seed_files()
        ),
      # 2026-06-10 — 页面助手(Salesperson)样式。v0 在 page_update span 里可选带
      # `salespersonConfig`(位置/外观),缓存到 slice → publish/snapshot 读 orchestrator
      # slice 时带走,seed 给消费会话(published/pub)也保留。nil = 用前端默认。
      salesperson_config:
        Map.get(args, :initial_salesperson_config) || Map.get(args, "initial_salesperson_config"),
      # 2026-06-15 — 弹幕样式(随 publish/snapshot 带走,跟 salesperson_config 同)。
      danmaku_config:
        Map.get(args, :initial_danmaku_config) || Map.get(args, "initial_danmaku_config")
    }
  end

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    pending = ctx[:read].(:pending, %{})
    page_files = page_update_files(msg)

    cond do
      # 2026-06-01 redesign: v0 page_update reply — cache new source on slice +
      # close any matching pending turn. Skip the compose path: v0's chat
      # message is already in the session, the loom-view bridge will render
      # it directly. (If v0 was bundled with policy/company in the same
      # dispatch — shouldn't happen per the prompt — the others' replies
      # become orphans and get dropped silently. v1 trade-off.)
      page_files -> handle_page_update(msg, page_files, pending, ctx)
      worker_deliverable?(msg, pending) -> handle_deliverable(msg, ctx, pending)
      user_turn?(msg) -> handle_user_turn(msg, ctx, pending)
      # loop-guard: stray / un-addressed / worker chatter → ignore.
      true -> {:ok, %{}, []}
    end
  end

  # === classification ===

  defp user_turn?(%Message{sender: %URI{host: "user"}}), do: true
  defp user_turn?(_), do: false

  defp worker_deliverable?(%Message{sender: %URI{host: "agent"}, ref_id: ref}, pending)
       when is_binary(ref),
       do: find_turn_by_subtask(pending, ref) != nil

  defp worker_deliverable?(_, _), do: false

  # === user turn → dispatch phase ===

  defp handle_user_turn(%Message{} = msg, ctx, pending) do
    self_uri = ctx_self(ctx)
    session_uri = ctx_session(ctx)
    persona = ctx[:read].(:persona, "visitor")

    # 2026-06-15 — 编排器自定义指令(用户在「团队」面板配),注入 decompose / compose /
    # direct-answer 提示词。读旁路文件,不碰 slice(slice 持有 loom_source)。
    instr = orch_instruction(session_uri)
    workers = effective_workers(ctx, session_uri)
    count = ctx[:read].(:count, 0)

    cond do
      is_nil(self_uri) or is_nil(session_uri) ->
        {:ok, %{}, []}

      # 单活跃生成守卫(2026-06-03):已有在飞回合(pending 非空)→ 不派新回合,
      # 提示先停止。前端也会锁输入,这里是后端防御(防绕过/竞态)。
      pending != %{} ->
        busy_notice(self_uri, session_uri, msg)

      workers == [] ->
        direct_answer(persona, msg, self_uri, session_uri, count, instr)

      true ->
        loom_source = Prompts.normalize_source(ctx[:read].(:loom_source, %{}))

        case LLM.chat(dispatch_messages(workers, text_of(msg), instr),
               temperature: 0.4,
               thinking_disabled: true,
               group: URI.to_string(session_uri)
             ) do
          {:ok, raw} ->
            case parse_dispatch(raw, workers) do
              {:ok, entries} ->
                fan_out(
                  msg,
                  entries,
                  self_uri,
                  session_uri,
                  persona,
                  pending,
                  count,
                  loom_source,
                  instr
                )

              :error ->
                direct_answer(persona, msg, self_uri, session_uri, count, instr)
            end

          {:error, _reason} ->
            direct_answer(persona, msg, self_uri, session_uri, count, instr)
        end
    end
  end

  defp effective_workers(ctx, session_uri) do
    raw =
      case ctx[:read].(:workers, []) do
        w when is_list(w) and w != [] ->
          normalize_workers(w)

        _ ->
          case session_uri do
            %URI{} = s -> discover_workers(s)
            _ -> []
          end
      end

    # 2026-06-05 — v0 从编排器解耦(同 loommeta 的 mention-gated 模型):builder 不进编排器
    # 可派发的 worker 列表。只有**直接 @loombuilder** 才改页;@编排器说"改页"无效(编排器
    # 不再把改页派给 v0)。v0 仍是 session 成员、回复仍 @编排器(见 LoomBuilderWorker),
    # 让编排器继续缓存 loom_source(publish/snapshot 依赖)。
    Enum.reject(raw, fn w -> w[:label] == "builder" end)
  end

  @doc """
  Discover worker agents (`loomworker_*`) currently joined to `session_uri`
  by reading its `:session` slice members (the sanctioned cross-Kind read).
  Returns `[%{uri, label}]`.
  """
  @spec discover_workers(URI.t()) :: [map()]
  def discover_workers(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        members
        |> Map.keys()
        |> Enum.flat_map(fn uri ->
          case worker_label(uri) do
            nil ->
              []

            label ->
              # 2026-06-01 — 自定义 worker(painter / lawyer 等)从 worker 自己
              # 的 :loom_worker slice 里读 role,供 dispatch_messages 拼进
              # system prompt。预制 worker 的 role 不读(label 命中 v0/policy/
              # company,worker_hint/1 已经有 hardcoded 描述)。
              role = read_worker_role(label, uri)
              [%{uri: to_uri(uri), label: label, role: role}]
          end
        end)
        |> Enum.reject(&is_nil(&1.uri))

      _ ->
        []
    end
  end

  @doc "Theme label of an `loomworker_*` member URI, or nil if not a worker."
  @spec worker_label(URI.t() | String.t()) :: String.t() | nil
  def worker_label(%URI{} = uri), do: worker_label(URI.to_string(uri))

  def worker_label(s) when is_binary(s) do
    cond do
      String.contains?(s, "/loombuilder_") ->
        "builder"

      not String.contains?(s, "/loomworker_") ->
        # loommeta_ / loomorch_ / user URIs / 等等 — 不算 worker
        nil

      # 2026-06-01 — 提取 `loomworker_<sid>_<theme>` 末段的 <theme> 作 label。
      # 这样 painter / lawyer 等自定义 worker 在 fan_out prompt 里有可区分
      # 的名字,而不是全部叫 "worker"。policy / company 走同一路径,自然
      # 还是出 "policy" / "company",所以预制行为不变。
      true ->
        extract_worker_theme(s) || "worker"
    end
  end

  defp extract_worker_theme(uri_str) do
    case Regex.run(~r{loomworker_[^_/]+_([a-z][a-z0-9_]*)$}, uri_str) do
      [_full, theme] -> theme
      _ -> nil
    end
  end

  def worker_label(_), do: nil

  defp fan_out(
         %Message{} = user_msg,
         entries,
         self_uri,
         session_uri,
         persona,
         pending,
         count,
         loom_source,
         instr
       ) do
    turn_id = user_msg.id

    subs =
      for %{uri: worker_uri, task: task} <- entries do
        # 2026-06-02 修意图丢失:builder(页面生成)直接拿**用户原话**,不用编排器转述的
        # `task`(转述会丢 URL / "1:1" / 行业等关键细节,导致 v0 跑偏)。业务 worker
        # 仍用编排器拆出的子任务。
        text =
          if builder?(worker_uri),
            do: builder_task(text_of(user_msg), task, loom_source),
            else: task

        Message.new(self_uri, %{text: text, attachments: []}, mentions: [worker_uri])
      end

    dispatch_effects =
      Enum.map(subs, fn sub -> {:dispatch, send_chat_cmd(session_uri, self_uri, sub)} end)

    subtask_ids = Enum.map(subs, & &1.id)

    turn = %{
      session_uri: session_uri,
      user_uri: user_msg.sender,
      persona: persona,
      orch_instruction: instr,
      expected: MapSet.new(subtask_ids),
      collected: %{}
    }

    # The handler runs IN the Kind.Server process, so self() is the
    # orchestrator Kind — the timer message lands in handle_kind_message/3.
    Process.send_after(self(), {:agg_timeout, turn_id}, agg_timeout_ms())

    {:ok, %{},
     [
       {:set, :pending, Map.put(pending, turn_id, turn)},
       {:set, :count, count + 1},
       {:set, :last_error, nil}
     ] ++ dispatch_effects}
  end

  # === worker deliverable → collect, maybe compose ===

  defp handle_deliverable(%Message{ref_id: ref} = msg, ctx, pending) do
    turn_id = find_turn_by_subtask(pending, ref)
    turn = Map.fetch!(pending, turn_id)
    collected = Map.put(turn.collected, ref, text_of(msg))
    self_uri = ctx_self(ctx)

    if all_collected?(turn.expected, collected) do
      reply = reply_cmd_effect(turn, collected, self_uri, turn.session_uri, false)
      {:ok, %{}, [{:set, :pending, Map.delete(pending, turn_id)}] ++ reply}
    else
      {:ok, %{}, [{:set, :pending, Map.put(pending, turn_id, %{turn | collected: collected})}]}
    end
  end

  defp all_collected?(expected, collected),
    do: Enum.all?(expected, &Map.has_key?(collected, &1))

  # === timeout (Kind.Server forwards unmatched messages to handle_kind_message/3) ===

  def handle_kind_message({:agg_timeout, turn_id}, slice, %{self_uri: self_uri}) do
    case Map.get(slice.pending, turn_id) do
      nil ->
        # already completed (pending deleted) → the timer is a no-op.
        :ignore

      turn ->
        # Lifecycle callback — no effect pipeline; dispatch the
        # partial-result reply directly via Router.
        case build_reply_cmd(turn, turn.collected, self_uri, turn.session_uri, true) do
          nil -> :ok
          %Cmd{} = cmd -> Ezagent.Router.dispatch(cmd)
        end

        {:ok, %{slice | pending: Map.delete(slice.pending, turn_id)}}
    end
  end

  # 用户中止(web_plug /stop 发来):清空在飞回合 → 迟到的 worker deliverable 变
  # stray 被丢、不 compose、不出"部分结果"卡 → 这一轮彻底丢弃。
  def handle_kind_message({:cancel, _}, slice, _ctx) do
    {:ok, %{slice | pending: %{}}}
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  # === compose ===

  # For the action-handler path: wrap the reply Cmd in a `{:dispatch, _}`
  # effect (or `[]` when self/session unavailable).
  defp reply_cmd_effect(turn, collected, self_uri, session_uri, partial) do
    case build_reply_cmd(turn, collected, self_uri, session_uri, partial) do
      nil -> []
      %Cmd{} = cmd -> [{:dispatch, cmd}]
    end
  end

  defp build_reply_cmd(_turn, _collected, nil, _session, _partial), do: nil
  defp build_reply_cmd(_turn, _collected, _self, nil, _partial), do: nil

  defp build_reply_cmd(turn, collected, %URI{} = self_uri, %URI{} = session_uri, partial) do
    case compose_span(turn, collected, partial) do
      # compose 被用户中止 → 不发任何回复(丢弃)。
      nil ->
        nil

      span ->
        reply = Message.new(self_uri, %{text: span, attachments: []}, mentions: [turn.user_uri])
        send_chat_cmd(session_uri, self_uri, reply)
    end
  end

  defp compose_span(turn, collected, partial) do
    frags = Map.values(collected)

    cond do
      frags == [] ->
        Span.span("notice", %{
          "text" => "这轮还没拿到结果,我再去催一下,稍等",
          "tone" => "warn",
          "title" => "部分结果",
          "actions" => ["再试一次", "换个问法"]
        })

      true ->
        case LLM.chat(
               compose_messages(
                 turn.persona,
                 frags,
                 partial,
                 Map.get(turn, :orch_instruction, "")
               ),
               temperature: 0.6,
               thinking_disabled: true,
               group: URI.to_string(turn.session_uri)
             ) do
          {:ok, raw} -> elem(Span.normalize(raw), 0)
          {:error, :stopped} -> nil
          {:error, reason} -> Span.error_span(reason)
        end
    end
  end

  # === direct-answer degradation (dispatch parse failed / no roster) ===

  defp direct_answer(persona, %Message{} = msg, self_uri, session_uri, count, instr \\ "") do
    case LLM.chat(
           [
             %{"role" => "system", "content" => Prompts.web_system_prompt()},
             %{"role" => "system", "content" => Prompts.persona_line(persona)}
           ] ++
             instr_sys(instr) ++
             [%{"role" => "user", "content" => text_of(msg)}],
           temperature: 0.6,
           thinking_disabled: true,
           group: URI.to_string(session_uri)
         ) do
      # 用户中止 → 不发任何回复(丢弃)。
      {:error, :stopped} ->
        {:ok, %{}, []}

      result ->
        span =
          case result do
            {:ok, raw} -> elem(Span.normalize(raw), 0)
            {:error, reason} -> Span.error_span(reason)
          end

        reply = Message.new(self_uri, %{text: span, attachments: []}, mentions: [msg.sender])

        {:ok, %{},
         [{:set, :count, count + 1}, {:dispatch, send_chat_cmd(session_uri, self_uri, reply)}]}
    end
  end

  # 已有在飞生成时,对新用户回合回一张"生成中"提示卡(不派新回合)。
  defp busy_notice(self_uri, session_uri, %Message{} = msg) do
    span =
      Span.span("notice", %{
        "text" => "正在生成中,点上方「停止」后再发新的请求。",
        "tone" => "warn",
        "title" => "生成中"
      })

    reply = Message.new(self_uri, %{text: span, attachments: []}, mentions: [msg.sender])
    {:ok, %{}, [{:dispatch, send_chat_cmd(session_uri, self_uri, reply)}]}
  end

  # === prompts ===

  defp dispatch_messages(workers, user_text, instr \\ "") do
    roster = workers |> Enum.map(&"- #{&1.label} #{worker_hint(&1)}") |> Enum.join("\n")

    sys = """
    你是Loom 孵化器助手「Loom」的编排器。你手下有这些 worker(按 label):
    #{roster}

    用户这轮的话见下。把这轮任务拆成给 worker 的子任务并派发出去(不要自己直接回答用户)。

    **分类规则**:
    - 当用户的请求是关于**生成、修改、设计页面 / UI**(例如"做一个登录页"、"把按钮改深色"、"加一个登录表单"),只派给 `builder`(它已有当前页面源码,会输出新的 jsx)。**不要**同时派给业务类 worker。
    - 当用户的请求是关于**业务咨询、政策、企业匹配**等,派给上面括号里描述匹配的业务 worker(可一条或多条);**不要**派给 v0。
    - **不要**派给 `meta`(团队管家)—— 它只处理 @-mention,不接编排器分配。
    - 用户加入的新 worker(label 不在 policy/company/v0/meta 中)也可以派,只要其括号里的描述跟用户请求对得上。

    只输出一个 JSON 对象,形如:
    {"dispatch":[{"to":"<worker label>","task":"<给该 worker 的具体子任务,中文>"}]}
    标签外不要写任何字。
    """

    [%{"role" => "system", "content" => sys}] ++
      instr_sys(instr) ++ [%{"role" => "user", "content" => user_text}]
  end

  # `dispatch_messages/2` 已经按 `&"- #{&1.label} #{worker_hint(&1)}"` 调用,
  # 收到的是 `%{uri, label, role}` map(2026-06-01 加了 role 字段)。
  defp worker_hint(%{label: "builder"}), do: "(页面生成/修改:UI/页面相关请求)"
  defp worker_hint(%{label: "policy"}), do: "(政策/资源面)"
  defp worker_hint(%{label: "company"}), do: "(企业匹配/对接面)"

  defp worker_hint(%{role: role}) when is_binary(role) and role != "" and role != "worker",
    do: "(#{role})"

  defp worker_hint(_), do: ""

  # 自定义 worker 的 role 从 :loom_worker slice 里读;预制 worker 不用读
  # (worker_hint 直接 hard-code)。
  defp read_worker_role(label, _uri) when label in ["builder", "policy", "company"], do: ""

  defp read_worker_role(_label, %URI{} = uri) do
    case Ezagent.Kind.get_slice(uri, :loom_worker) do
      {:ok, %{role: r}} when is_binary(r) -> r
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp read_worker_role(_, _), do: ""

  defp compose_messages(persona, frags, partial, instr \\ "") do
    joined =
      frags
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} -> "【片段#{i}】\n#{f}" end)
      |> Enum.join("\n\n")

    note =
      if partial,
        do: "\n注意:部分 worker 未及时返回。请基于已有片段给一张『部分结果』卡片,并在 text 里说明还在补充。",
        else: ""

    composer = """
    下面是你的 worker 们为这轮任务产出的内容片段。把它们整合成**一张**给用户的场景卡片(严格遵守上面的输出格式铁律,只输出一个 JSON 对象)。#{note}

    #{joined}
    """

    [
      %{"role" => "system", "content" => Prompts.web_system_prompt()},
      %{"role" => "system", "content" => Prompts.persona_line(persona)}
    ] ++
      instr_sys(instr) ++ [%{"role" => "user", "content" => composer}]
  end

  # 编排器自定义指令 → 一条 system 消息(空则不加)。注入 decompose / compose / direct-answer。
  defp instr_sys(instr) when is_binary(instr) do
    case String.trim(instr) do
      "" -> []
      t -> [%{"role" => "system", "content" => "【本会话编排器的额外指令(用户配置,优先遵守)】\n" <> t}]
    end
  end

  defp instr_sys(_), do: []

  # 从 session_uri 读这个会话的编排器自定义指令(旁路文件)。
  defp orch_instruction(%URI{path: path}) when is_binary(path) do
    case path |> String.trim_leading("/") |> String.split("/") do
      [ws, sid | _] -> Ezagent.PluginLoom.WorkerConfig.get_orchestrator(ws, sid)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp orch_instruction(_), do: ""

  # === pure helpers (unit-tested) ===

  @doc """
  Parse a DeepSeek dispatch reply into `[%{uri: %URI{}, task: String}]`.
  Returns `:error` (→ degrade) when JSON is malformed / has no `dispatch`
  array / maps to zero known workers.
  """
  @spec parse_dispatch(String.t(), [map()]) :: {:ok, [map()]} | :error
  def parse_dispatch(raw, workers) when is_binary(raw) and is_list(workers) do
    with json when is_binary(json) <- Span.extract_first_json_object(raw),
         {:ok, %{"dispatch" => list}} when is_list(list) <- Jason.decode(json) do
      entries =
        for %{"to" => to, "task" => task} <- list,
            is_binary(task),
            String.trim(task) != "",
            uri = match_worker(workers, to),
            not is_nil(uri) do
          %{uri: uri, task: task}
        end

      if entries == [], do: :error, else: {:ok, entries}
    else
      _ -> :error
    end
  end

  def parse_dispatch(_, _), do: :error

  defp match_worker(workers, to) when is_binary(to) do
    tod = to |> String.trim() |> String.downcase()

    Enum.find_value(workers, fn %{label: label, uri: uri} ->
      ld = String.downcase(label)
      if ld == tod or String.contains?(tod, ld) or String.contains?(ld, tod), do: uri, else: nil
    end)
  end

  defp match_worker(_, _), do: nil

  @doc "Find the turn_id whose pending subtask set contains `subtask_id`, or nil."
  @spec find_turn_by_subtask(map(), String.t()) :: term() | nil
  def find_turn_by_subtask(pending, subtask_id) when is_map(pending) do
    Enum.find_value(pending, fn {turn_id, turn} ->
      if MapSet.member?(turn.expected, subtask_id), do: turn_id, else: nil
    end)
  end

  # 2026-06-01 — 保留可选 :role 字段,如果传进来的 map 有的话(给 worker_hint
  # 用)。slice 里持久化的 workers 列表通常没有 role,运行时 discover_workers
  # 会产出含 role 的 map。
  defp normalize_workers(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{uri: u, label: l} = m ->
        %{
          uri: to_uri(u),
          label: to_string(l),
          role: to_string(Map.get(m, :role) || Map.get(m, "role") || "")
        }

      %{"uri" => u, "label" => l} = m ->
        %{uri: to_uri(u), label: to_string(l), role: to_string(Map.get(m, "role") || "")}

      _ ->
        nil
    end)
    |> Enum.reject(&(is_nil(&1) or is_nil(&1.uri)))
  end

  defp normalize_workers(_), do: []

  defp to_uri(%URI{} = u), do: u

  defp to_uri(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp to_uri(_), do: nil

  # === send + ctx helpers ===

  # Build (NOT dispatch) the chat.send Cmd — callers wrap it in a
  # `{:dispatch, _}` effect (action path) or `Router.dispatch/1` it
  # directly (lifecycle path).
  defp send_chat_cmd(%URI{} = session_uri, %URI{} = sender, %Message{} = m) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    Cmd.new(target, :send, %{message: m}, %{
      caller: sender,
      caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
      reply: :ignore
    })
  end

  defp ctx_self(%{self_uri: %URI{} = u}), do: u
  defp ctx_self(_), do: nil

  defp ctx_session(%{caller: %URI{} = u}), do: u

  defp ctx_session(%{caller: s}) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp ctx_session(_), do: nil

  defp text_of(%Message{body: %{text: t}}) when is_binary(t), do: t
  defp text_of(%Message{body: %{"text" => t}}) when is_binary(t), do: t
  defp text_of(_), do: ""

  # === 2026-06-01 redesign: page_update span handling ===

  # Return the embedded **files map** from a `<span type="page_update">{...}</span>`
  # message body, or nil if absent / malformed.
  #
  # 2026-06-02 多文件:优先读 `files` map;只有旧 `source` 字符串则归一成
  # `%{"/App.jsx" => src}`(兼容旧 span / 旧快照重放)。
  #
  # Greedy match (`[\s\S]*` NOT `[\s\S]*?`) is essential: v0's generated JSX often
  # contains nested `</span>` tokens; a non-greedy match terminates on the FIRST
  # inner `</span>` and yields malformed JSON. Greedy + the closing `</span>`
  # naturally anchors on the LAST occurrence which is the outer span's close.
  defp page_update_files(%Message{body: body}) do
    text = body_text(body)

    case Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text) do
      [_full, inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"files" => files}} when is_map(files) and map_size(files) > 0 ->
            Prompts.normalize_source(files)

          {:ok, %{"source" => src}} when is_binary(src) and src != "" ->
            Prompts.normalize_source(src)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp page_update_files(_), do: nil

  # 2026-06-17 — page_update 里 builder 打的「这条改的是哪一页」(页 id)。无 → nil(老消息)。
  defp page_update_page(%Message{body: body}) do
    text = body_text(body)

    case Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text) do
      [_full, inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"page" => p}} when is_binary(p) and p != "" -> p
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp page_update_page(_), do: nil

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # Cache the new source on slice; close the pending turn (if any) so the
  # aggregator no-ops and the compose path is skipped — v0's message already
  # rendered to the session.
  defp handle_page_update(%Message{ref_id: ref} = msg, files, pending, ctx) when is_binary(ref) do
    sync_active_page_source(ctx, files, page_update_page(msg))
    cfg = salesperson_config_effects(msg) ++ danmaku_config_effects(msg)

    case find_turn_by_subtask(pending, ref) do
      nil ->
        {:ok, %{}, [{:set, :loom_source, files}] ++ cfg}

      turn_id ->
        {:ok, %{},
         [{:set, :loom_source, files}, {:set, :pending, Map.delete(pending, turn_id)}] ++ cfg}
    end
  end

  defp handle_page_update(msg, files, _pending, ctx) do
    sync_active_page_source(ctx, files, page_update_page(msg))

    {:ok, %{},
     [{:set, :loom_source, files}] ++
       salesperson_config_effects(msg) ++ danmaku_config_effects(msg)}
  end

  # 2026-06-16 多页:builder 改的是「活动页」→ 把这次源码**服务端**写进多页旁路的活动页,
  # 让旁路始终是最新的(不依赖前端回存,避免切页渲染到陈旧源)。best-effort,失败不影响主流程。
  # 2026-06-17 — 回写到**这条 page_update 标的页**(builder 打的 `page`),而非盲目写活动页。
  # 这样切页竞态 / 回退别的页都不会串源;老消息无 `page` → 兜底用活动页(旧行为)。
  defp sync_active_page_source(ctx, files, page) do
    case orch_ws_sid(ctx) do
      {ws, sid} ->
        target =
          if is_binary(page) and page != "",
            do: page,
            else: Ezagent.PluginLoom.Pages.active_id(ws, sid)

        # 一次性记下这页**第一次构建前**的源码 = 初始版本(回退历史永远能回到最初)。
        _ =
          Ezagent.PluginLoom.PageInit.capture(
            ws,
            sid,
            target,
            Ezagent.PluginLoom.Pages.page_source(ws, sid, target) || %{}
          )

        Ezagent.PluginLoom.Pages.put_source(ws, sid, target, files)

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp orch_ws_sid(ctx) do
    with %URI{path: path} <- Map.get(ctx, :self_uri),
         [ws, agent | _] <- path |> to_string() |> String.trim_leading("/") |> String.split("/"),
         "loomorch_" <> sid <- agent,
         true <- ws != "" and sid != "" do
      {ws, sid}
    else
      _ -> nil
    end
  end

  # page_update span 里可选 `salespersonConfig`(页面助手样式)。带了才 set —— 后续不带
  # cfg 的编辑不清掉已存样式(v0 不必每次都重发样式块)。
  defp salesperson_config_effects(%Message{} = msg) do
    case page_update_salesperson_config(msg) do
      cfg when is_map(cfg) and map_size(cfg) > 0 -> [{:set, :salesperson_config, cfg}]
      _ -> []
    end
  end

  defp salesperson_config_effects(_), do: []

  defp page_update_salesperson_config(%Message{body: body}) do
    text = body_text(body)

    case Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text) do
      [_full, inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"salespersonConfig" => cfg}} when is_map(cfg) -> cfg
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp page_update_salesperson_config(_), do: nil

  # 2026-06-15 — 弹幕样式 danmakuConfig,跟 salespersonConfig 同机制:带了才 set,缓存到 slice。
  defp danmaku_config_effects(%Message{} = msg) do
    case page_update_danmaku_config(msg) do
      cfg when is_map(cfg) and map_size(cfg) > 0 -> [{:set, :danmaku_config, cfg}]
      _ -> []
    end
  end

  defp danmaku_config_effects(_), do: []

  defp page_update_danmaku_config(%Message{body: body}) do
    text = body_text(body)

    case Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text) do
      [_full, inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"danmakuConfig" => cfg}} when is_map(cfg) -> cfg
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp page_update_danmaku_config(_), do: nil

  defp builder?(%URI{} = uri), do: String.contains?(URI.to_string(uri), "/loombuilder_")
  defp builder?(_), do: false

  # Compose the v0 subtask text:current files + user's modification request +
  # 用户上传的素材(参考 HTML/文本 → 内容;图片 → 可引用的 URL)。
  # v0's system prompt (`Prompts.page_gen_system_prompt`) handles output rules.
  # 2026-06-02 多文件:current_source 现为 files map,逐文件渲染成带 file= 的代码块。
  # 2026-06-12:把用户消息的 attachments(resource://uploads/…)解析进来喂给 v0。
  defp builder_task(user_request, dispatch_hint, current_files) do
    files_block =
      current_files
      |> Prompts.normalize_source()
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.map_join("\n\n", fn {path, src} -> "```jsx file=#{path}\n#{src}\n```" end)

    """
    # 用户的需求(这是权威,以此为准)
    #{user_request}

    (编排器对这条需求的理解,仅供参考:#{dispatch_hint})

    # 当前页面的全部文件(仅作参考 —— 如果用户要的是一个全新页面,就**完全重做**,
    #  不要被下面已有内容的主题/品牌带偏;如果用户只是小改,才在此基础上改)
    #{files_block}

    按系统提示词的规则输出新的页面:每个文件一个 ```jsx file=/路径``` 块,**带上整个页面的全部文件**
    (改过的 + 没改的都要,平台整体替换),入口必须是 /App.jsx。代码块前可有 1 句对话说明你做了什么
    (会作为 page_update 的 summary)。不要输出 /platform.js 或 /ezagent-ui.js。
    """
  end

  def data_owner(_), do: :no_owner
end
