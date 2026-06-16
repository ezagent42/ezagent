defmodule EzagentPluginLoom.Orchestrator do
  @moduledoc """
  Loom 编排器逻辑（multi-agent wiring 第一片：compose 半边）。

  `compose_scene/1` 把一个 customer 意图经一次 LLM 调用变成 Turn 的 `result_refs`:
  - 一条 scene-card 风格 chat 回复(`%{kind: :chat, text}`)
  - 一棵页面 UI-tree(`%{kind: :page, tree}`),节点形如 `%{type, props, children}`,
    type 取自 `EzagentPluginLoom.NodeTypes`。

  这是 multi-agent 编排的最小可跑核心(单 agent 直出 chat+page)。后续轮次再加
  decompose → fan-out themed worker → 收集 → compose 的完整 wiring,以及 turn.open 触发。
  纯逻辑 + LLM 调用,产出可直接喂 `Turn.compose(result_refs)`。
  """

  alias EzagentPluginLoom.LLM

  @system """
  你是 loom 编排器。用户给你一个意图,你产出一个网页雏形 + 一句简短中文引导语。
  严格只输出一个 JSON 对象,不要 markdown 代码块、不要解释,形如:
  {
    "chat": "一句简短中文引导语",
    "page": {
      "type": "services",
      "props": {"title": "标题"},
      "children": [
        {"type": "detail", "props": {"text": "..."}, "children": []},
        {"type": "choices", "props": {"options": ["选项A","选项B"]}, "children": []}
      ]
    }
  }
  page 是一棵 UI-tree,每个节点有 type/props/children 三个键(children 可为空数组)。
  type 只能取: text, services, companies, detail, steps, form, choices, notice, application, intent, page。
  根据用户意图选择合适的节点组合,内容用中文。
  """

  @decompose_system """
  你是 loom 编排器。把用户的网页意图拆成 2-3 个互补的内容主题(themes)。
  严格只输出 JSON,不要 markdown、不要解释,形如: {"themes": ["主题一", "主题二"]}
  """

  @max_themes 3
  @worker_timeout_ms 120_000

  @doc """
  完整多 agent 编排:decompose → 并发 themed worker → 聚合 compose → Turn result_refs。
  decompose 失败时回退到单 agent `compose_scene/1`。
  返回 `{:ok, [%{kind: :chat, text}, %{kind: :page, tree}]}` | `{:error, reason}`。
  """
  @spec run(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(user_text, opts \\ []) when is_binary(user_text) do
    case decompose(user_text, opts) do
      {:ok, [_ | _] = themes} ->
        fragments = gather(user_text, themes, opts)
        compose_multi(user_text, fragments, opts)

      _ ->
        # decompose 失败/空 → 单 agent 兜底
        compose_scene(user_text, opts)
    end
  end

  @doc """
  单 agent 直出:一次 LLM 调用产 scene-card chat + page。`run/1` 的回退路径。
  """
  @spec compose_scene(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def compose_scene(user_text, opts \\ []) when is_binary(user_text) do
    compose_from([%{role: "user", content: user_text}], opts)
  end

  # --- 多 agent 各阶段 ------------------------------------------------------

  # 编排器:拆主题
  defp decompose(user_text, opts) do
    messages = [%{role: "user", content: user_text}]

    with {:ok, text} <- LLM.chat(messages, Keyword.put(opts, :system, @decompose_system)),
         {:ok, %{"themes" => themes}} when is_list(themes) <- extract_json(text) do
      {:ok, themes |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.take(@max_themes)}
    else
      _ -> {:error, :decompose_failed}
    end
  end

  # themed worker 并发产片段
  defp gather(user_text, themes, opts) do
    themes
    |> Task.async_stream(fn theme -> {theme, worker_fragment(user_text, theme, opts)} end,
      timeout: @worker_timeout_ms,
      max_concurrency: @max_themes,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {theme, {:ok, fragment}}} -> %{theme: theme, fragment: fragment}
      {:ok, {theme, _}} -> %{theme: theme, fragment: ""}
      _ -> %{theme: "", fragment: ""}
    end)
  end

  defp worker_fragment(user_text, theme, opts) do
    system = "你是 loom 主题 worker,负责「#{theme}」。针对用户意图产出该主题的简短中文内容(2-4 句),只输出纯文本。"
    LLM.chat([%{role: "user", content: user_text}], Keyword.put(opts, :system, system))
  end

  # 编排器:聚合各主题片段 → scene-card chat + page
  defp compose_multi(user_text, fragments, opts) do
    material =
      fragments
      |> Enum.reject(&(&1.fragment == ""))
      |> Enum.map_join("\n", &"【#{&1.theme}】#{&1.fragment}")

    content = "用户意图：#{user_text}\n\n各主题素材：\n#{material}"
    compose_from([%{role: "user", content: content}], opts)
  end

  # 共享:一次 LLM 调用产 {chat, page} JSON → result_refs
  defp compose_from(messages, opts) do
    with {:ok, text} <- LLM.chat(messages, Keyword.put(opts, :system, @system)),
         {:ok, %{"chat" => chat, "page" => page}} <- extract_json(text),
         true <- is_binary(chat) and is_map(page) do
      {:ok,
       [
         %{kind: :chat, text: chat},
         %{kind: :page, tree: normalize_tree(page)}
       ]}
    else
      false -> {:error, :malformed_scene}
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  end

  defp extract_json(text), do: EzagentPluginLoom.Json.extract_object(text)

  # 统一成字符串键的 %{type, props, children},剔除未知 type。
  defp normalize_tree(%{"type" => type} = node) do
    children = node["children"] || []

    %{
      "type" => to_string(type),
      "props" => node["props"] || %{},
      "children" => children |> List.wrap() |> Enum.map(&normalize_tree/1)
    }
  end

  defp normalize_tree(_), do: %{"type" => "text", "props" => %{}, "children" => []}
end
