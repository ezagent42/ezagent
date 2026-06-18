defmodule Ezagent.PluginLoom.PageGen do
  @moduledoc """
  Real LLM page generator for the loom socialware vertical (P1b).

  Wraps loom's existing builder codegen — `EzagentPluginLoom.Prompts.page_gen_system_prompt/0`
  + `EzagentPluginLoom.LLM.chat/1` + the proven `extract_files_and_summary/1`
  parser — into the `(request -> {:ok, %{tree, reply}})` shape that
  `Ezagent.PluginLoom.TurnManager` injects. The LLM backend (claude_code /
  deepseek) is whatever `EzagentPluginLoom.LLM` is configured with.

  Page edits: pass the current page files map as `current_tree` so the model
  edits the existing source instead of starting from scratch.
  """

  alias EzagentPluginLoom.{LLM, Prompts}

  @type tree :: map()

  @doc "Generate (or edit) the page from an authoring `request`."
  @spec generate(term(), tree() | nil) :: {:ok, %{tree: tree(), reply: String.t()}} | {:error, term()}
  def generate(request, current_tree \\ nil) do
    messages = [
      %{"role" => "system", "content" => Prompts.page_gen_system_prompt()},
      %{"role" => "user", "content" => user_prompt(request, current_tree)}
    ]

    case LLM.chat(messages) do
      {:ok, text} ->
        case Ezagent.Behavior.LoomBuilderWorker.extract_files_and_summary(text) do
          {files, summary} when is_map(files) and map_size(files) > 0 ->
            {:ok, %{tree: files, reply: to_string(summary)}}

          _ ->
            {:error, :page_parse_failed}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc "A `(request -> result)` generator closure for `TurnManager.build_page/4`."
  @spec generator(tree() | nil) :: (term() -> {:ok, map()} | {:error, term()})
  def generator(current_tree \\ nil), do: fn request -> generate(request, current_tree) end

  defp user_prompt(request, tree) when is_map(tree) and map_size(tree) > 0 do
    "当前页面源码(在此基础上修改):\n" <>
      inspect(tree, limit: :infinity, printable_limit: :infinity) <>
      "\n\n用户要求:\n" <> to_string(request)
  end

  defp user_prompt(request, _no_current), do: to_string(request)
end
