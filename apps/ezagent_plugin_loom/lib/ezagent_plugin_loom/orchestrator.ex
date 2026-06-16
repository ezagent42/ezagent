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

  @doc """
  把 customer 意图编排成 Turn result_refs。
  返回 `{:ok, [%{kind: :chat, text: ...}, %{kind: :page, tree: ...}]}` | `{:error, reason}`。
  """
  @spec compose_scene(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def compose_scene(user_text, opts \\ []) when is_binary(user_text) do
    messages = [%{role: "user", content: user_text}]

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

  # LLM 可能用 ```json 包裹或夹带文字 — 抽第一个完整 JSON 对象。
  defp extract_json(text) do
    text = String.trim(text)

    candidate =
      cond do
        String.starts_with?(text, "{") -> text
        true -> slice_first_object(text)
      end

    case candidate && Jason.decode(candidate) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :no_json_object}
    end
  end

  defp slice_first_object(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        # 从第一个 { 到最后一个 } — 简单但对单对象足够
        case :binary.matches(text, "}") do
          [] -> nil
          matches -> {last, _} = List.last(matches); binary_part(text, start, last - start + 1)
        end

      :nomatch ->
        nil
    end
  end

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
