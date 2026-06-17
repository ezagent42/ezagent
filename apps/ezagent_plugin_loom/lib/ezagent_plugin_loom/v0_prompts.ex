defmodule EzagentPluginLoom.V0Prompts do
  @moduledoc """
  v0 页面生成的 system prompt(loom 原本提示词,迁移自 loom-stitch `Prompts.page_gen_system_prompt`)。

  模板太长(~390 行)→ 存为 priv 资产 `priv/prompts/page_gen_system_prompt.txt`(loom 原文逐字),
  运行时读 + 替换 `#DYNAMIC_TOOL_AND_PRESET_BLOCK#`(当前 loom 无 ToolRegistry.prompt_block →
  用 FetchProxy.prompt_block 若有,否则空)。前端 Sandpack 提供 loom-kit / 技术栈。
  """

  @placeholder "#DYNAMIC_TOOL_AND_PRESET_BLOCK#"

  @doc "页面生成 system prompt(loom 原文 + 动态块替换)。"
  @spec page_gen_system_prompt() :: String.t()
  def page_gen_system_prompt do
    String.replace(template(), @placeholder, dynamic_block())
  end

  defp template do
    path = Application.app_dir(:ezagent_plugin_loom, "priv/prompts/page_gen_system_prompt.txt")

    case File.read(path) do
      {:ok, txt} ->
        txt

      _ ->
        "你是一个 AI UI 生成助手。输出 ```jsx file=/App.jsx``` 代码块,export default function App(),用 Tailwind。"
    end
  end

  # tools + presets 块(替换 page_gen 模板的 #DYNAMIC_TOOL_AND_PRESET_BLOCK#)。
  defp dynamic_block do
    [EzagentPluginLoom.Tool.prompt_block(), EzagentPluginLoom.FetchProxy.prompt_block()]
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.join("\n\n")
  rescue
    _ -> ""
  end
end
