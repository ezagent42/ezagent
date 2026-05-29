defmodule EzagentPluginLoom.Span do
  @moduledoc """
  Span normalization for the Loom plugin (loom v0.2) — the single
  source of truth for turning raw model output into a well-formed
  `<span type="...">{json}</span>` scene card (PRD §5.5). Used by:

  - `Ezagent.Behavior.Loom` `:say` (the v0.1 web brain), and
  - `Ezagent.Behavior.LoomOrchestrator` compose phase (G-D) — the
    orchestrator's deterministic componentization. **Component choice is
    a pure function here, NOT another LLM/worker** (PRD §护栏 #9).

  Ported verbatim from the original `Ezagent.Behavior.Loom` private
  `normalize/1` + `inferType` + `extractFirstJsonObject` so the card
  contract is byte-identical to v0.1.
  """

  @known_types ~w(text notice services detail companies steps form choices application intent)

  @doc "The closed set of card types the frontend renders."
  def known_types, do: @known_types

  @doc """
  Normalize raw model output into `{span_string, readable_text}`.

  - `span_string` — `<span type="X">{json}</span>` for the frontend card.
  - `readable_text` — a short human line for session/feishu mirror.

  Worst case degrades to `<span type="text">{...}</span>` — never raises,
  never returns malformed span.
  """
  @spec normalize(String.t() | nil) :: {String.t(), String.t()}
  def normalize(raw) do
    text = String.trim(raw || "")

    case extract_first_json_object(text) do
      nil ->
        readable = if text == "", do: "（无内容）", else: text
        {span("text", %{"text" => readable}), readable}

      json_str ->
        case Jason.decode(json_str) do
          {:ok, obj} when is_map(obj) ->
            obj = if is_binary(Map.get(obj, "text")), do: obj, else: Map.put(obj, "text", "")
            readable = if obj["text"] in [nil, ""], do: "（Loom已更新卡片）", else: obj["text"]
            {span(infer_type(obj), obj), readable}

          _ ->
            {span("text", %{"text" => text}), text}
        end
    end
  end

  @doc "Wrap a card object as a `<span type=...>` string."
  @spec span(String.t(), map()) :: String.t()
  def span(type, obj), do: ~s(<span type="#{type}">#{Jason.encode!(obj)}</span>)

  @doc "A renderable error card (notice/danger) — the silent-drop guard (PRD §8)."
  @spec error_span(term()) :: String.t()
  def error_span(reason),
    do:
      span("notice", %{
        "text" => "出错了",
        "tone" => "danger",
        "title" => "请求失败",
        "description" => inspect(reason)
      })

  @doc "Infer the card type from object field shape when `type` is missing."
  def infer_type(o) do
    cond do
      is_binary(o["type"]) and o["type"] in @known_types ->
        o["type"]

      is_list(o["fields"]) ->
        "form"

      is_list(o["steps"]) ->
        "steps"

      is_list(o["facts"]) ->
        "detail"

      is_map(o["sections"]) and Map.has_key?(o, "company") ->
        "intent"

      is_map(o["sections"]) ->
        "application"

      is_list(o["items"]) ->
        if Enum.any?(o["items"], &is_number(&1["fit"])), do: "companies", else: "services"

      is_list(o["options"]) ->
        "choices"

      o["tone"] || (o["title"] && o["description"]) ->
        "notice"

      true ->
        "text"
    end
  end

  @doc """
  Extract the first balanced `{...}` substring (skips ``` fences + leading
  prose; correctly handles strings + escapes). Returns the JSON substring
  or `nil` if none/unbalanced.
  """
  def extract_first_json_object(s) when is_binary(s) do
    case :binary.match(s, "{") do
      :nomatch -> nil
      {start, _} -> do_scan(s, start, start, 0, false, false)
    end
  end

  def extract_first_json_object(_), do: nil

  defp do_scan(s, _start, i, _depth, _in_str, _esc) when i >= byte_size(s), do: nil

  defp do_scan(s, start, i, depth, in_str, esc) do
    c = binary_part(s, i, 1)

    cond do
      in_str and esc -> do_scan(s, start, i + 1, depth, true, false)
      in_str and c == "\\" -> do_scan(s, start, i + 1, depth, true, true)
      in_str and c == "\"" -> do_scan(s, start, i + 1, depth, false, false)
      in_str -> do_scan(s, start, i + 1, depth, true, false)
      c == "\"" -> do_scan(s, start, i + 1, depth, true, false)
      c == "{" -> do_scan(s, start, i + 1, depth + 1, false, false)
      c == "}" and depth - 1 == 0 -> binary_part(s, start, i - start + 1)
      c == "}" -> do_scan(s, start, i + 1, depth - 1, false, false)
      true -> do_scan(s, start, i + 1, depth, false, false)
    end
  end
end
