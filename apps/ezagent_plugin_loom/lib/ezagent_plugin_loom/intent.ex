defmodule EzagentPluginLoom.Intent do
  @moduledoc """
  Loom **意图推荐**(文档清单 B vertical 独有,旧 loom 的 `/intent`)。

  session-less:给一段自然语言意图 + 产品目录,LLM 硬选最匹配的 N 个并各给一句 pitch。
  纯 vertical 逻辑(用 loom 自己的 LLM client + curl 平面),不碰 socialware。
  """

  alias EzagentPluginLoom.{Json, LLM}

  @default_n 3

  @doc """
  从 `catalog`(产品列表,每项 `%{"id"=>..,"name"=>..,"desc"=>..}`)按 `intent_text`
  选 N 个 + pitch。返回 `{:ok, [%{"id","pitch"}]}` | `{:error, reason}`。
  """
  @spec recommend(String.t(), [map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def recommend(intent_text, catalog, opts \\ [])
      when is_binary(intent_text) and is_list(catalog) do
    n = opts[:n] || @default_n

    system = """
    你是 loom 推荐器。从给定产品目录里挑出最匹配用户意图的 #{n} 个,每个给一句中文 pitch。
    严格只输出 JSON,不要 markdown、不要解释,形如:
    {"picks": [{"id": "<目录里的 id>", "pitch": "一句中文推荐语"}]}
    id 必须取自目录;最多 #{n} 个;按匹配度排序。
    """

    content = "用户意图：#{intent_text}\n\n产品目录：\n#{format_catalog(catalog)}"

    with {:ok, text} <- LLM.chat([%{role: "user", content: content}], Keyword.put(opts, :system, system)),
         {:ok, %{"picks" => picks}} when is_list(picks) <- Json.extract_object(text) do
      valid_ids = catalog |> Enum.map(&(&1["id"] || &1[:id])) |> MapSet.new()

      picks =
        picks
        |> Enum.filter(&(is_map(&1) and MapSet.member?(valid_ids, &1["id"])))
        |> Enum.take(n)

      {:ok, picks}
    else
      _ -> {:error, :recommend_failed}
    end
  end

  defp format_catalog(catalog) do
    catalog
    |> Enum.map_join("\n", fn item ->
      id = item["id"] || item[:id]
      name = item["name"] || item[:name] || id
      desc = item["desc"] || item[:desc] || ""
      "- #{id}｜#{name}：#{desc}"
    end)
  end
end
