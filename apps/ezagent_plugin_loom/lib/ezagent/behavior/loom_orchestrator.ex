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
  alias EzagentPluginLoom.{DeepSeek, Span, Prompts}

  # Bumped 12s → 45s (2026-06-01): v0worker calls DeepSeek to generate full
  # pages, which routinely takes 10-20s. Old 12s timeout was firing before v0
  # returned, leaving the user with a "partial" notice and then a silent late
  # page_update. 45s comfortably covers v0; for business turns (policy/company)
  # this slightly delays the "partial" notice but those workers reply in 1-3s
  # anyway, so the timeout only fires on real failures.
  @agg_timeout_ms 45_000

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
      # 2026-06-01 redesign: cached page source. Updated whenever v0 emits a
      # `<span type="page_update">` reply (handle_receive page-update branch).
      # Seeded from args :initial_loom_source (LoomSavedSession uses saved
      # snapshot; LoomSession uses Prompts.loom_seed_source()).
      loom_source:
        to_string(
          Map.get(args, :initial_loom_source) || Map.get(args, "initial_loom_source") ||
            Prompts.loom_seed_source()
        )
    }
  end

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    pending = ctx[:read].(:pending, %{})
    page_src = page_update_source(msg)

    cond do
      # 2026-06-01 redesign: v0 page_update reply — cache new source on slice +
      # close any matching pending turn. Skip the compose path: v0's chat
      # message is already in the session, the loom-view bridge will render
      # it directly. (If v0 was bundled with policy/company in the same
      # dispatch — shouldn't happen per the prompt — the others' replies
      # become orphans and get dropped silently. v1 trade-off.)
      page_src -> handle_page_update(msg, page_src, pending)
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
    workers = effective_workers(ctx, session_uri)
    count = ctx[:read].(:count, 0)

    cond do
      is_nil(self_uri) or is_nil(session_uri) ->
        {:ok, %{}, []}

      workers == [] ->
        direct_answer(persona, msg, self_uri, session_uri, count)

      true ->
        loom_source = ctx[:read].(:loom_source, "")

        case DeepSeek.chat(dispatch_messages(workers, text_of(msg)),
               temperature: 0.4,
               thinking_disabled: true
             ) do
          {:ok, raw} ->
            case parse_dispatch(raw, workers) do
              {:ok, entries} ->
                fan_out(msg, entries, self_uri, session_uri, persona, pending, count, loom_source)

              :error ->
                direct_answer(persona, msg, self_uri, session_uri, count)
            end

          {:error, _reason} ->
            direct_answer(persona, msg, self_uri, session_uri, count)
        end
    end
  end

  defp effective_workers(ctx, session_uri) do
    case ctx[:read].(:workers, []) do
      w when is_list(w) and w != [] ->
        normalize_workers(w)

      _ ->
        case session_uri do
          %URI{} = s -> discover_workers(s)
          _ -> []
        end
    end
  end

  @doc """
  Discover worker agents (`loomworker_*`) currently joined to `session_uri`
  by reading its `:chat` slice members (the sanctioned cross-Kind read).
  Returns `[%{uri, label}]`.
  """
  @spec discover_workers(URI.t()) :: [map()]
  def discover_workers(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
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
      String.contains?(s, "/loomv0_") ->
        "v0"

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
         loom_source
       ) do
    turn_id = user_msg.id

    subs =
      for %{uri: worker_uri, task: task} <- entries do
        text = if v0?(worker_uri), do: v0_task(task, loom_source), else: task
        Message.new(self_uri, %{text: text, attachments: []}, mentions: [worker_uri])
      end

    dispatch_effects =
      Enum.map(subs, fn sub -> {:dispatch, send_chat_cmd(session_uri, self_uri, sub)} end)

    subtask_ids = Enum.map(subs, & &1.id)

    turn = %{
      session_uri: session_uri,
      user_uri: user_msg.sender,
      persona: persona,
      expected: MapSet.new(subtask_ids),
      collected: %{}
    }

    # The handler runs IN the Kind.Server process, so self() is the
    # orchestrator Kind — the timer message lands in handle_kind_message/3.
    Process.send_after(self(), {:agg_timeout, turn_id}, @agg_timeout_ms)

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
    span = compose_span(turn, collected, partial)
    reply = Message.new(self_uri, %{text: span, attachments: []}, mentions: [turn.user_uri])
    send_chat_cmd(session_uri, self_uri, reply)
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
        case DeepSeek.chat(compose_messages(turn.persona, frags, partial),
               temperature: 0.6,
               thinking_disabled: true
             ) do
          {:ok, raw} -> elem(Span.normalize(raw), 0)
          {:error, reason} -> Span.error_span(reason)
        end
    end
  end

  # === direct-answer degradation (dispatch parse failed / no roster) ===

  defp direct_answer(persona, %Message{} = msg, self_uri, session_uri, count) do
    span =
      case DeepSeek.chat(
             [
               %{"role" => "system", "content" => Prompts.web_system_prompt()},
               %{"role" => "system", "content" => Prompts.persona_line(persona)},
               %{"role" => "user", "content" => text_of(msg)}
             ],
             temperature: 0.6,
             thinking_disabled: true
           ) do
        {:ok, raw} -> elem(Span.normalize(raw), 0)
        {:error, reason} -> Span.error_span(reason)
      end

    reply = Message.new(self_uri, %{text: span, attachments: []}, mentions: [msg.sender])

    {:ok, %{},
     [{:set, :count, count + 1}, {:dispatch, send_chat_cmd(session_uri, self_uri, reply)}]}
  end

  # === prompts ===

  defp dispatch_messages(workers, user_text) do
    roster = workers |> Enum.map(&"- #{&1.label} #{worker_hint(&1)}") |> Enum.join("\n")

    sys = """
    你是Loom 孵化器助手「Loom」的编排器。你手下有这些 worker(按 label):
    #{roster}

    用户这轮的话见下。把这轮任务拆成给 worker 的子任务并派发出去(不要自己直接回答用户)。

    **分类规则**:
    - 当用户的请求是关于**生成、修改、设计页面 / UI**(例如"做一个登录页"、"把按钮改深色"、"加一个登录表单"),只派给 `v0`(它已有当前页面源码,会输出新的 jsx)。**不要**同时派给业务类 worker。
    - 当用户的请求是关于**业务咨询、政策、企业匹配**等,派给上面括号里描述匹配的业务 worker(可一条或多条);**不要**派给 v0。
    - **不要**派给 `meta`(团队管家)—— 它只处理 @-mention,不接编排器分配。
    - 用户加入的新 worker(label 不在 policy/company/v0/meta 中)也可以派,只要其括号里的描述跟用户请求对得上。

    只输出一个 JSON 对象,形如:
    {"dispatch":[{"to":"<worker label>","task":"<给该 worker 的具体子任务,中文>"}]}
    标签外不要写任何字。
    """

    [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => user_text}]
  end

  # `dispatch_messages/2` 已经按 `&"- #{&1.label} #{worker_hint(&1)}"` 调用,
  # 收到的是 `%{uri, label, role}` map(2026-06-01 加了 role 字段)。
  defp worker_hint(%{label: "v0"}), do: "(页面生成/修改:UI/页面相关请求)"
  defp worker_hint(%{label: "policy"}), do: "(政策/资源面)"
  defp worker_hint(%{label: "company"}), do: "(企业匹配/对接面)"

  defp worker_hint(%{role: role}) when is_binary(role) and role != "" and role != "worker",
    do: "(#{role})"

  defp worker_hint(_), do: ""

  # 自定义 worker 的 role 从 :loom_worker slice 里读;预制 worker 不用读
  # (worker_hint 直接 hard-code)。
  defp read_worker_role(label, _uri) when label in ["v0", "policy", "company"], do: ""

  defp read_worker_role(_label, %URI{} = uri) do
    case Ezagent.Kind.get_slice(uri, :loom_worker) do
      {:ok, %{role: r}} when is_binary(r) -> r
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp read_worker_role(_, _), do: ""

  defp compose_messages(persona, frags, partial) do
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
      %{"role" => "system", "content" => Prompts.persona_line(persona)},
      %{"role" => "user", "content" => composer}
    ]
  end

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
        %{uri: to_uri(u), label: to_string(l), role: to_string(Map.get(m, :role) || Map.get(m, "role") || "")}

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
    case URI.new(s) do
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
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

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
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp ctx_session(_), do: nil

  defp text_of(%Message{body: %{text: t}}) when is_binary(t), do: t
  defp text_of(%Message{body: %{"text" => t}}) when is_binary(t), do: t
  defp text_of(_), do: ""

  # === 2026-06-01 redesign: page_update span handling ===

  # Return the embedded `source` string from a `<span type="page_update">{...}</span>`
  # message body, or nil if absent / malformed.
  #
  # Greedy match (`[\s\S]*` NOT `[\s\S]*?`) is essential: v0's generated JSX often
  # contains nested `</span>` tokens; a non-greedy match terminates on the FIRST
  # inner `</span>` and yields malformed JSON. Greedy + the closing `</span>`
  # naturally anchors on the LAST occurrence which is the outer span's close.
  defp page_update_source(%Message{body: body}) do
    text = body_text(body)

    case Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text) do
      [_full, inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"source" => src}} when is_binary(src) -> src
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp page_update_source(_), do: nil

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # Cache the new source on slice; close the pending turn (if any) so the
  # aggregator no-ops and the compose path is skipped — v0's message already
  # rendered to the session.
  defp handle_page_update(%Message{ref_id: ref}, source, pending) when is_binary(ref) do
    case find_turn_by_subtask(pending, ref) do
      nil ->
        {:ok, %{}, [{:set, :loom_source, source}]}

      turn_id ->
        {:ok, %{}, [{:set, :loom_source, source}, {:set, :pending, Map.delete(pending, turn_id)}]}
    end
  end

  defp handle_page_update(_msg, source, _pending) do
    {:ok, %{}, [{:set, :loom_source, source}]}
  end

  defp v0?(%URI{} = uri), do: String.contains?(URI.to_string(uri), "/loomv0_")
  defp v0?(_), do: false

  # Compose the v0 subtask text:current source + user's modification request.
  # v0's system prompt (`Prompts.page_gen_system_prompt`) handles output rules.
  defp v0_task(user_request, current_source) do
    """
    # 当前页面源码(jsx)
    ```jsx
    #{current_source}
    ```

    # 用户的修改/创建需求
    #{user_request}

    按系统提示词的规则,只输出一个 jsx 代码块表示新的完整 App;代码块前可以有 1 句对话说明你做了什么(会作为 page_update 的 summary)。
    """
  end

  def data_owner(_), do: :no_owner
end
