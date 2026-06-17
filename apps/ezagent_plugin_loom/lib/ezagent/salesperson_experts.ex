defmodule EzagentPluginLoom.SalespersonExperts do
  @moduledoc """
  Salesperson worker roster + prompts + parsers (2026-06-12, real-worker rewrite).

  Salesperson runs as an **orchestrator** (`loomsalesperson_<sid>`) over a fixed set of
  **real worker Kinds** spawned with every loom session
  (`loomsalespersonsub_<sid>_<role>`, see `Ezagent.Behavior.LoomSalespersonSubWorker`).
  Per preview turn the orchestrator: routes → dispatches to the relevant
  workers → collects each worker's result → composes one reply. This module
  holds the **transport-agnostic** pieces both sides share:

    - `roster/1`        fixed worker set (chat / navigation / controls / content),
                        each annotated with the page capabilities it handles.
    - `router_messages` + `parse_router/2`   (orchestrator: route → fast | plan).
    - `worker_messages` + `parse_part/1`     (worker: handle a subtask → result).
    - `composer_messages` + `parse_composer` (orchestrator: parts → one reply).

  Naming is plain English (`chat / navigation / controls / content`) — no
  "expert" / "consultation" metaphors. Worker output is one of: `answer`
  (text), `act` (a page drive), or `none`.
  """

  # Fixed roster. `caps_for` decides which page caps each worker handles.
  @roles [
    %{key: "chat", label: "Chat", icon: "💬", desc: "general questions & small talk"},
    %{key: "navigation", label: "Navigation", icon: "🧭", desc: "switch view, compare"},
    %{key: "controls", label: "Controls", icon: "🎚", desc: "filter, highlight, step, reveal"},
    %{key: "content", label: "Content", icon: "📖", desc: "explain page content"}
  ]

  @doc "The fixed worker keys, in order (used by Team.ensure_team to spawn them)."
  @spec role_keys() :: [String.t()]
  def role_keys, do: Enum.map(@roles, & &1.key)

  @doc "Role metadata for one key (or nil)."
  @spec role(String.t()) :: map() | nil
  def role(key), do: Enum.find(@roles, &(&1.key == key))

  # ---- roster (fixed 4 + the caps each handles) ---------------------------

  @doc """
  The full worker roster for this page: the fixed 4, each annotated with the
  page capabilities it handles (`caps` + `owns` labels). Workers are always
  present (spawned per session); `caps` just tells the router/worker which
  page capabilities map to which worker.
  """
  @spec roster([map()]) :: [map()]
  def roster(caps) when is_list(caps) do
    Enum.map(@roles, fn r ->
      cs = if r.key == "chat", do: [], else: Enum.filter(caps, &(bucket_for(cap_type(&1)) == r.key))
      Map.merge(r, %{caps: cs, owns: Enum.map(cs, &cap_label/1) |> Enum.reject(&(&1 in [nil, ""]))})
    end)
  end

  def roster(_), do: roster([])

  @doc "Frontend view of the roster (for the editor Workers panel)."
  @spec roster_view([map()]) :: [map()]
  def roster_view(roster) do
    Enum.map(roster, fn r ->
      %{"key" => r.key, "label" => r.label, "icon" => r.icon, "owns" => r.owns}
    end)
  end

  defp cap_type(cap) when is_map(cap) do
    t = cap["type"] || cap[:type]

    cond do
      is_binary(t) and t != "" -> t
      true -> (cap["id"] || cap[:id] || "") |> to_string() |> String.split(":") |> hd()
    end
    |> String.downcase()
  end

  defp cap_type(_), do: ""

  defp bucket_for(type) do
    cond do
      type in ["datascope", "multiview", "view", "nav", "navigation"] -> "navigation"
      type in ["filter", "filterable", "spotlight", "stepper", "reveal", "revealable"] -> "controls"
      true -> "content"
    end
  end

  defp cap_label(cap) when is_map(cap), do: cap["label"] || cap[:label] || cap["id"] || cap[:id]
  defp cap_label(_), do: nil

  # ---- router (orchestrator) ----------------------------------------------

  defp roster_brief(roster) do
    roster
    |> Enum.map(fn r ->
      owns = if r.owns == [], do: "", else: " — handles: #{Enum.join(r.owns, "、")}"
      "- #{r.key}(#{r.desc})#{owns}"
    end)
    |> Enum.join("\n")
  end

  defp kb_block(kb) do
    case String.trim(kb || "") do
      "" -> "(本页没有提供知识库)"
      k -> k
    end
  end

  @doc """
  Messages for the route call. The orchestrator **never answers directly** —
  it always routes the turn to one or more workers (`chat` for pure
  chit-chat / questions with no matching capability), so every turn goes
  through a worker.
  """
  def router_messages(roster, kb, history, text) do
    sys = """
    你是页面助手 Salesperson 的调度器。看用户这句话 + 下面可用的 worker,**选出要处理这条消息的
    worker**(一个或多个),各给一句子任务 task。

    【可用 worker】
    #{roster_brief(roster)}

    规则:
    - 涉及页面能力(切换 / 对比 / 筛选 / 高亮 / 调数值 / 展开 / 讲解某块内容)→ 选对应 worker;
      可同时选多个(例如既要切视图又要讲解)。
    - 纯打招呼 / 闲聊 / 泛泛提问 / 没有对应页面能力 → 选 `chat`。
    - **总是至少选一个 worker(不要自己直接回答)。**

    **只输出一个 JSON,不要解释、不要 markdown 围栏:**
    {"plan":[{"worker":"<key>","task":"<给该 worker 的一句子任务>"}]}

    【知识库】#{kb_block(kb)}
    """

    [%{"role" => "system", "content" => sys}] ++ history_messages(history) ++
      [%{"role" => "user", "content" => text}]
  end

  @doc "Parse the route reply → a plan `[%{key, task}]` (possibly empty)."
  def parse_router(raw, roster) do
    keys = Enum.map(roster, & &1.key)

    case json_object(raw) do
      %{"plan" => plan} when is_list(plan) ->
        for item <- plan,
            is_map(item),
            k = to_string(item["worker"] || item[:worker] || ""),
            k in keys,
            into: [],
            do: %{key: k, task: to_string(item["task"] || item[:task] || "")}

      _ ->
        []
    end
  end

  # ---- worker (one sub-worker handling its subtask) -----------------------

  @doc """
  Messages for a worker handling a subtask. `role_meta` = the worker's role map;
  `caps` = the page capabilities this worker handles (already filtered).
  """
  def worker_messages(role_meta, caps, kb, task, user_text) do
    caps_json = if caps == [], do: "[]", else: Jason.encode!(caps)

    sys = """
    你是页面助手 Salesperson 调度下的一个 worker,负责:#{role_meta.desc}(#{role_meta.label})。
    读用户原话 + 你的子任务,输出**二选一**:

    1) 操作页面 —— 当子任务对应你管的某能力的某 command:
       {"kind":"act","say":"<一句自述,如:已切到1955vs2028对比>",
        "drive":{"id":"<能力id>","action":"<command.action>","params":<据 options 的 key 构造的真实参数>}}
    2) 给内容 —— 你直接回答 / 讲解:
       {"kind":"answer","say":"<给同事的一句自述,如:讲了两代差异>",
        "answer":"<真正要给用户看的话:自然、第一人称、简洁中文。不要写成「回复用户说…」这种转述>"}

    规则:params 用 options 里的 **key**(不是 label、不是占位符);options 里没有的值别硬造。
    若这事不归你管 / 你没有对应能力,就 {"kind":"answer","say":"不适用","answer":""}。
    **只输出一个 JSON,不要解释、不要 markdown 围栏。**

    【你管的能力】(JSON;含 id/label、options[{key,label}]、commands[{action,desc}]):
    #{caps_json}

    【知识库】#{kb_block(kb)}
    """

    [
      %{"role" => "system", "content" => sys},
      %{"role" => "user", "content" => "用户原话:#{user_text}\n你的子任务:#{task}"}
    ]
  end

  @doc "Parse a worker reply → `%{kind, say, drive, answer}` (always succeeds)."
  def parse_part(raw) do
    case json_object(raw) do
      %{"kind" => "act", "drive" => %{"id" => _, "action" => _} = d} = m ->
        %{"kind" => "act", "say" => nz(m["say"], "已操作页面"), "drive" => d, "answer" => nil}

      %{"kind" => "answer"} = m ->
        %{"kind" => "answer", "say" => nz(m["say"], "作答"), "drive" => nil, "answer" => nz(m["answer"], "")}

      _ ->
        %{"kind" => "answer", "say" => "作答", "drive" => nil, "answer" => reply_of(raw)}
    end
  end

  # ---- composer (orchestrator) --------------------------------------------

  @doc "Messages for the final compose call (parts → one natural reply TO the user)."
  def composer_messages(parts, user_text) do
    sys = """
    你是页面助手 Salesperson,正在**直接跟用户对话**。下面是为了回应用户这句话、内部收集到的信息
    和已经做的页面操作。请**自然地用一段话回复用户**(第一人称、友好、简洁、中文),就像聊天:
    - 做了页面操作 → 顺带轻描淡写说一下(如「帮你切到 1955 和 2028 对比了」);
    - 是讲解 / 回答 → 把答案自然说出来;
    - 没太明白用户的意思 → 自然地请他说清楚(如「嗯?这个我没太get到,你想看点啥?」)。

    **严禁**汇报式措辞:不许说「我已经处理了你的请求」「结果是…」「已完成」「收到,正在…」这类话。
    **严禁**提到内部 worker / 步骤 / 流程 —— 就当下面的信息是你自己知道的,直接回用户。

    **只输出一个 JSON:** {"reply":"<给用户的话>"}

    【可参考的内部信息(别照搬措辞,只取其意)】
    #{parts_brief(parts)}
    """

    [
      %{"role" => "system", "content" => sys},
      %{"role" => "user", "content" => "用户刚说:#{user_text}"}
    ]
  end

  @doc "Parse the compose reply → reply text (falls back to a join of parts)."
  def parse_composer(raw, parts) do
    case json_object(raw) do
      %{"reply" => r} when is_binary(r) and r != "" -> r
      _ -> nz(reply_of(raw), compose_fallback(parts))
    end
  end

  @doc "Deterministic fallback reply if the compose call is unavailable."
  def compose_fallback(parts) do
    acts = parts |> Enum.filter(&(&1["kind"] == "act")) |> Enum.map(& &1["say"])
    answers = parts |> Enum.filter(&(&1["kind"] == "answer")) |> Enum.map(& &1["answer"])

    [Enum.join(acts, ";"), Enum.join(answers, "\n")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> case do
      "" -> "好的。"
      s -> s
    end
  end

  @doc "Collect the page drives from worker parts (each `act` part's drive)."
  def drives_of(parts) do
    parts
    |> Enum.filter(&(&1["kind"] == "act" and is_map(&1["drive"])))
    |> Enum.map(& &1["drive"])
  end

  defp parts_brief([]), do: "(没有 worker 产出)"

  defp parts_brief(parts) do
    parts
    |> Enum.map(fn p ->
      label = p["label"] || p["worker"] || "worker"

      tail =
        case p["kind"] do
          "act" -> "[指令] #{p["say"]}"
          "answer" -> "[内容] #{p["say"]}#{if p["answer"] not in [nil, ""], do: " — " <> String.slice(to_string(p["answer"]), 0, 240), else: ""}"
          _ -> to_string(p["say"])
        end

      "- #{label}:#{tail}"
    end)
    |> Enum.join("\n")
  end

  defp history_messages(history) when is_list(history) do
    history
    |> Enum.take(-6)
    |> Enum.flat_map(fn h ->
      role = to_string(h["role"] || h[:role] || "user")
      t = to_string(h["text"] || h[:text] || "")
      if t == "", do: [], else: [%{"role" => if(role == "assistant", do: "assistant", else: "user"), "content" => t}]
    end)
  end

  defp history_messages(_), do: []

  # ---- JSON extraction (tolerant of fences / noise) -----------------------

  @doc false
  def json_object(raw) when is_binary(raw) do
    cleaned = raw |> String.replace(~r/```json|```/, "") |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, m} when is_map(m) ->
        m

      _ ->
        with {:ok, slice} <- first_brace_slice(cleaned),
             {:ok, m} when is_map(m) <- Jason.decode(slice) do
          m
        else
          _ -> nil
        end
    end
  end

  def json_object(_), do: nil

  defp first_brace_slice(s) do
    case :binary.match(s, "{") do
      {start, _} ->
        case last_brace(s) do
          stop when stop > start -> {:ok, binary_part(s, start, stop - start + 1)}
          _ -> :error
        end

      :nomatch ->
        :error
    end
  end

  defp last_brace(s) do
    case :binary.matches(s, "}") do
      [] -> -1
      ms -> ms |> List.last() |> elem(0)
    end
  end

  @doc false
  def reply_of(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/```json|```/, "")
    |> String.replace(~r/\{[\s\S]*\}/, "")
    |> String.trim()
    |> case do
      "" -> "好的。"
      t -> t
    end
  end

  def reply_of(_), do: "好的。"

  defp nz(nil, d), do: d
  defp nz("", d), do: d
  defp nz(v, _), do: v
end
