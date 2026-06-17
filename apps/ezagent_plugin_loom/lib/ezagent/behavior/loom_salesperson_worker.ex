defmodule Ezagent.Behavior.LoomSalespersonWorker do
  @moduledoc """
  Loom Salesperson **orchestrator** Behavior — the in-session preview-side AI.

  2026-06-12 rewrite (real workers): Salesperson is now an orchestrator over a fixed
  set of real worker Kinds (`loomsalespersonsub_<sid>_<role>`, role ∈
  chat/navigation/controls/content), spawned for every loom session by
  `EzagentPluginLoom.Team.ensure_team/2`. Per preview chat turn:

      route(1 DeepSeek) → fast(直接答) | deep(派发给相关 worker)
        deep: fan out subtasks @mentioning each worker → collect their
              `salesperson_part` deliverables (ref_id 关联,同 LoomOrchestrator 范式)
              → compose(1 DeepSeek)一条回复 → reply

  仍是预览侧快平面(直连 `EzagentPluginLoom.DeepSeek`),只是把一轮拆给多个 worker Kind。

  ## Two interaction modes (message body `salesperson.mode`)

  - `"salesperson"`: chat — the orchestration above.
  - `"aispot"`: ✨ card — kept as a single direct DeepSeek call (no fan-out).

  ## Reply frame

  `<span/>`-free: visible body is plain text; `salesperson_reply` meta field carries
  `%{mode, drive, drives, op, trace}`. `trace = %{roster, chain}` drives the
  **editor** Workers panel. `ref_id` = the original request msg id (so the
  frontend correlates the SSE frame back to its `/salesperson` POST).

  ## Decision trace

  A separate `salesperson_debug: true` message per turn shows the run
  (route → workers → compose) for the editor / admin timeline.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  alias Ezagent.{Cmd, Message}
  alias Ezagent.PluginLoom.Knowledge
  alias EzagentPluginLoom.{DeepSeek, Salesperson, SalespersonExperts}

  # 聚合兜底超时:worker 进程真死时才触发(正常完成是事件驱动的)。
  @agg_timeout_ms 60_000

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom Salesperson orchestrator — route a preview turn to sub-workers, aggregate, reply"
  )

  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomsalesperson, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_salesperson

  def init_slice(_args), do: %{count: 0, last_error: nil, pending: %{}}

  # ---------------------------------------------------------------
  # handle_receive — classify: deliverable / user-turn / ignore
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    pending = ctx[:read].(:pending, %{})

    cond do
      deliverable?(msg, pending) -> handle_deliverable(msg, ctx, pending)
      user_turn?(msg, ctx) -> handle_user_turn(msg, ctx, pending)
      true -> {:ok, %{}, []}
    end
  end

  defp user_turn?(%Message{sender: %URI{host: "user"}} = msg, ctx),
    do: addressed_to_self?(msg, ctx) and salesperson_payload(msg.body) != %{}

  defp user_turn?(_, _), do: false

  defp deliverable?(%Message{sender: %URI{host: "agent"}, ref_id: ref}, pending)
       when is_binary(ref),
       do: find_turn_by_subtask(pending, ref) != nil

  defp deliverable?(_, _), do: false

  # ---------------------------------------------------------------
  # user turn
  # ---------------------------------------------------------------

  defp handle_user_turn(%Message{} = msg, ctx, pending) do
    payload = salesperson_payload(msg.body)
    {ws, sid} = ws_sid(ctx)
    kb = if ws && sid, do: Knowledge.get(ws, sid), else: ""
    count = ctx[:read].(:count, 0)

    case Map.get(payload, "mode", "salesperson") do
      "aispot" ->
        aspot_turn(payload, kb, ctx, msg, count)

      _ ->
        # 2026-06-15 — Salesperson 接待模式:human → 不自动答访客,出一段给运营看的分析。
        if ws && sid && Ezagent.PluginLoom.WorkerConfig.get_salesperson_mode(ws, sid) == "human" do
          human_analysis_turn(payload, kb, ctx, msg, count)
        else
          salesperson_turn(payload, kb, ctx, msg, pending, count)
        end
    end
  end

  # === human(真人接待)模式:不答访客,产出给运营看的要点分析 ===
  # reply 标 mode "human" → preview 历史(GET /salesperson 过滤 mode=="salesperson")不收录,
  # 访客侧看不到这条;admin 会话时间线照常显示(运营看)。
  defp human_analysis_turn(payload, kb, ctx, msg, count) do
    text = to_string(Map.get(payload, "text", ""))

    sys = """
    当前会话是「真人接待」模式:你**不直接回答访客**,而是给运营 / 真人一段简短分析,帮 ta 决定怎么回复。
    #{if kb != "", do: "可参考的知识库:\n#{kb}\n", else: ""}
    访客刚说的话见 user。请只输出**给运营看的要点分析**(不要对访客说话、不要客服口吻、不要 JSON):
    1) 访客真实意图 / 想要什么;
    2) 关注点或潜在顾虑;
    3) 建议的回复要点(2-3 条)。
    简洁、要点式、纯文本。
    """

    case DeepSeek.chat(
           [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => text}],
           temperature: 0.4,
           thinking_disabled: true
         ) do
      {:ok, raw} ->
        analysis = "【真人模式 · 给运营的分析(访客看不到自动答复)】\n" <> String.trim(raw)

        {:ok, %{},
         [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
           reply_effect(ctx, msg, analysis, salesperson_meta(%{"mode" => "human"}))}

      {:error, reason} ->
        {:ok, %{},
         [{:set, :last_error, reason}] ++
           reply_effect(
             ctx,
             msg,
             "(分析暂时不可用:#{inspect(reason)})",
             salesperson_meta(%{"mode" => "human"})
           )}
    end
  end

  # === aspot: single direct call (unchanged behavior) ===

  defp aspot_turn(payload, kb, ctx, msg, count) do
    feature = to_string(Map.get(payload, "feature", ""))
    context = to_string(Map.get(payload, "context", ""))
    caps = Map.get(payload, "caps", []) |> normalize_caps()

    if feature == "" and context == "" do
      {:ok, %{}, reply_effect(ctx, msg, "(无)", %{"mode" => "aispot"})}
    else
      sys = Salesperson.aispot_prompt(feature, context, kb, caps)

      case DeepSeek.chat(
             [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => "生成。"}],
             temperature: 0.5,
             thinking_disabled: true
           ) do
        {:ok, raw} ->
          {decision, card} = Salesperson.split_decision(raw)

          _ = decision

          {:ok, %{},
           [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
             reply_effect(ctx, msg, card, %{"mode" => "aispot"})}

        {:error, reason} ->
          {:ok, %{},
           [{:set, :last_error, reason}] ++
             reply_effect(ctx, msg, "(增强助手暂时不可用:#{inspect(reason)})", %{"mode" => "aispot"})}
      end
    end
  end

  # === salesperson chat: route → fast | fan-out ===

  defp salesperson_turn(payload, kb, ctx, msg, pending, count) do
    text = to_string(Map.get(payload, "text", ""))
    caps = Map.get(payload, "caps", []) |> normalize_caps()
    history = Map.get(payload, "history", [])
    roster = SalespersonExperts.roster(caps)
    roster_view = SalespersonExperts.roster_view(roster)

    case DeepSeek.chat(SalespersonExperts.router_messages(roster, kb, history, text),
           temperature: 0.3,
           thinking_disabled: true
         ) do
      {:ok, raw} ->
        # 编排器永远不直接作答:无有效 plan → 兜底派给 chat worker,保证每轮都走 sub。
        plan =
          case SalespersonExperts.parse_router(raw, roster) do
            [] -> [%{key: "chat", task: text}]
            p -> p
          end

        fan_out(plan, text, caps, kb, roster, roster_view, ctx, msg, pending, count)

      {:error, reason} ->
        {:ok, %{},
         [{:set, :last_error, reason}] ++
           reply_effect(ctx, msg, "(增强助手暂时不可用:#{inspect(reason)})", salesperson_meta(%{}))}
    end
  end

  defp fan_out(plan, text, caps, kb, roster, roster_view, ctx, msg, pending, count) do
    self_uri = Map.get(ctx, :self_uri)
    session_uri = session_from_ctx(ctx)
    {ws, sid} = ws_sid(ctx)

    cond do
      is_nil(self_uri) or is_nil(session_uri) or is_nil(ws) ->
        {:ok, %{}, []}

      true ->
        # 每个子任务 @ 对应 sub-worker,body 带它该处理的 caps + 子任务 + 用户原话。
        subs =
          for %{key: key, task: task} <- plan do
            worker_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomsalespersonsub_#{sid}_#{key}")
            owned = bucket_caps(roster, key)

            body = %{
              text: "salesperson subtask: #{task}",
              attachments: [],
              salesperson_sub: %{"task" => task, "user_text" => text, "kb" => kb, "caps" => owned}
            }

            {key, Message.new(self_uri, body, mentions: [worker_uri])}
          end

        dispatch_effects =
          Enum.map(subs, fn {_k, sub} ->
            {:dispatch, send_chat_cmd(session_uri, self_uri, sub)}
          end)

        subtask_ids = Enum.map(subs, fn {_k, sub} -> sub.id end)

        turn = %{
          session_uri: session_uri,
          user_uri: msg.sender,
          text: text,
          caps_ids: cap_ids(caps),
          kb?: kb != "",
          roster_view: roster_view,
          plan_keys: Enum.map(plan, & &1.key),
          sub_keys: Map.new(subs, fn {k, sub} -> {sub.id, k} end),
          expected: MapSet.new(subtask_ids),
          collected: %{}
        }

        turn_id = msg.id
        Process.send_after(self(), {:salesperson_agg_timeout, turn_id}, @agg_timeout_ms)

        {:ok, %{},
         [
           {:set, :pending, Map.put(pending, turn_id, turn)},
           {:set, :count, count + 1},
           {:set, :last_error, nil}
         ] ++
           dispatch_effects}
    end
  end

  # caps a given worker role handles (from the roster annotations).
  defp bucket_caps(roster, key) do
    case Enum.find(roster, &(&1.key == key)) do
      %{caps: cs} -> cs
      _ -> []
    end
  end

  # ---------------------------------------------------------------
  # deliverable → collect, maybe compose
  # ---------------------------------------------------------------

  defp handle_deliverable(%Message{ref_id: ref} = msg, ctx, pending) do
    turn_id = find_turn_by_subtask(pending, ref)
    turn = Map.fetch!(pending, turn_id)
    part = part_of(msg.body, turn.sub_keys[ref])
    collected = Map.put(turn.collected, ref, part)

    if all_collected?(turn.expected, collected) do
      compose_and_reply(turn, collected, ctx, turn_id, pending)
    else
      {:ok, %{}, [{:set, :pending, Map.put(pending, turn_id, %{turn | collected: collected})}]}
    end
  end

  defp all_collected?(expected, collected),
    do: Enum.all?(expected, &Map.has_key?(collected, &1))

  defp compose_and_reply(turn, collected, ctx, turn_id, pending) do
    self_uri = Map.get(ctx, :self_uri)
    {reply_text, drives, chain} = compose(turn, collected)
    meta = salesperson_meta(%{"drives" => drives, "trace" => trace(turn.roster_view, chain)})

    effects =
      salesperson_reply_effect(
        self_uri,
        turn.session_uri,
        turn_id,
        turn.user_uri,
        reply_text,
        meta
      )

    {:ok, %{}, [{:set, :pending, Map.delete(pending, turn_id)}] ++ effects}
  end

  # ordered parts (by plan) → drives + compose call + chain.
  defp compose(turn, collected) do
    parts =
      turn.plan_keys
      |> Enum.flat_map(fn key ->
        case Enum.find(collected, fn {sub_id, _} -> turn.sub_keys[sub_id] == key end) do
          {_id, part} -> [part]
          _ -> []
        end
      end)

    drives = SalespersonExperts.drives_of(parts)

    reply =
      case DeepSeek.chat(SalespersonExperts.composer_messages(parts, turn.text),
             temperature: 0.5,
             thinking_disabled: true
           ) do
        {:ok, raw} -> SalespersonExperts.parse_composer(raw, parts)
        {:error, _} -> SalespersonExperts.compose_fallback(parts)
      end

    chain =
      [step("route", "deep", "派发 #{length(turn.plan_keys)} 个 worker")] ++
        Enum.map(parts, fn p ->
          step("#{p["icon"]} #{p["label"]}", p["kind"], p["say"])
        end) ++
        [
          step(
            "compose",
            "salesperson",
            "整理成一条回复#{if drives != [], do: " · 应用 #{length(drives)} 个动作", else: ""}"
          )
        ]

    {reply, drives, chain}
  end

  # ---------------------------------------------------------------
  # timeout (Kind.Server lifecycle hook — dispatch via Router directly)
  # ---------------------------------------------------------------

  def handle_kind_message({:salesperson_agg_timeout, turn_id}, slice, %{self_uri: self_uri}) do
    case Map.get(slice.pending || %{}, turn_id) do
      nil ->
        :ignore

      turn ->
        {reply_text, drives, chain} = compose(turn, turn.collected)
        meta = salesperson_meta(%{"drives" => drives, "trace" => trace(turn.roster_view, chain)})

        for cmd <-
              salesperson_reply_cmds(
                self_uri,
                turn.session_uri,
                turn_id,
                turn.user_uri,
                reply_text,
                meta
              ) do
          Ezagent.Router.dispatch(cmd)
        end

        {:ok, %{slice | pending: Map.delete(slice.pending, turn_id)}}
    end
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  # ---------------------------------------------------------------
  # trace (carried in the salesperson_reply meta; no longer a session message)
  # ---------------------------------------------------------------

  defp trace(roster_view, chain), do: %{"roster" => roster_view, "chain" => chain}

  defp step(label, kind, detail),
    do: %{
      "step" => to_string(label),
      "kind" => to_string(kind),
      "detail" => to_string(detail || "")
    }

  # ---------------------------------------------------------------
  # payload / helpers
  # ---------------------------------------------------------------

  defp salesperson_payload(body) when is_map(body),
    do: body["salesperson"] || body[:salesperson] || %{}

  defp salesperson_payload(_), do: %{}

  defp part_of(body, worker_key) when is_map(body) do
    p = body["salesperson_part"] || body[:salesperson_part] || %{}
    Map.put_new(p, "worker", worker_key)
  end

  defp part_of(_, worker_key),
    do: %{"kind" => "answer", "say" => "", "answer" => "", "worker" => worker_key}

  defp normalize_caps(caps) when is_list(caps) do
    caps |> Enum.filter(&(is_map(&1) and Map.get(&1, "id") not in [nil, ""])) |> Enum.take(40)
  end

  defp normalize_caps(_), do: []

  defp cap_ids(caps) when is_list(caps),
    do: caps |> Enum.map(&(&1["id"] || &1[:id])) |> Enum.reject(&(&1 in [nil, ""]))

  defp cap_ids(_), do: []

  defp salesperson_meta(map) do
    %{
      "mode" => Map.get(map, "mode", "salesperson"),
      "drive" => List.first(Map.get(map, "drives", []) || []),
      "drives" => Map.get(map, "drives", []),
      "op" => nil,
      "trace" => Map.get(map, "trace")
    }
  end

  defp find_turn_by_subtask(pending, subtask_id) when is_map(pending) do
    Enum.find_value(pending, fn {turn_id, turn} ->
      if MapSet.member?(turn.expected, subtask_id), do: turn_id, else: nil
    end)
  end

  defp ws_sid(ctx) do
    case session_from_ctx(ctx) do
      %URI{path: path} when is_binary(path) ->
        case path |> String.trim_leading("/") |> String.split("/") do
          [ws, sid | _] -> {ws, sid}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)

    Enum.any?(mentions, fn
      %URI{} = m -> URI.to_string(m) == self_str
      _ -> false
    end)
  end

  defp addressed_to_self?(_, _), do: false

  # === reply / dispatch builders ===

  # action-path reply (wrapped in {:dispatch, _}); reply to the request msg.
  defp reply_effect(ctx, %Message{} = req_msg, plain_text, meta)
       when is_binary(plain_text) and is_map(meta) do
    salesperson_reply_effect(
      Map.get(ctx, :self_uri),
      session_from_ctx(ctx),
      req_msg.id,
      req_msg.sender,
      plain_text,
      meta
    )
  end

  defp salesperson_reply_effect(self_uri, session_uri, ref_id, to_uri, text, meta),
    do:
      Enum.map(
        salesperson_reply_cmds(self_uri, session_uri, ref_id, to_uri, text, meta),
        &{:dispatch, &1}
      )

  defp salesperson_reply_cmds(
         %URI{} = self_uri,
         %URI{scheme: "session"} = session_uri,
         ref_id,
         %URI{} = to_uri,
         text,
         meta
       ) do
    reply =
      Message.new(self_uri, %{text: text, attachments: [], salesperson_reply: meta},
        ref_id: ref_id,
        mentions: [to_uri]
      )

    [send_chat_cmd(session_uri, self_uri, reply)]
  end

  defp salesperson_reply_cmds(_, _, _, _, _, _), do: []

  defp send_chat_cmd(%URI{} = session_uri, %URI{} = sender, %Message{} = m) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    Cmd.new(target, :send, %{message: m}, %{
      caller: sender,
      caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
      reply: :ignore
    })
  end

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_from_ctx(_), do: nil

  defp nz(nil, d), do: d
  defp nz("", d), do: d
  defp nz(v, _), do: v

  def data_owner(_), do: :no_owner
end
