defmodule Ezagent.Orchestrator.Tools.ToolCatalog do
  @moduledoc false

  @tool_names [
    :add_managed_member,
    :update_member_template,
    :remove_member,
    :define_rule_set_rule,
    :define_prompt_template,
    :define_legend,
    :update_template,
    :save_template_as,
    :list_templates
  ]

  @spec tool_names() :: [atom()]
  def tool_names, do: @tool_names

  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in @tool_names
  def tool?(_), do: false
end
