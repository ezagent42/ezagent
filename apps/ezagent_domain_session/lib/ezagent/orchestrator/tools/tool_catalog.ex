defmodule Ezagent.Orchestrator.Tools.ToolCatalog do
  @moduledoc false

  @fallback_tool_names [
    :add_managed_member,
    :add_participant,
    :update_member_template,
    :remove_member,
    :define_rule_set_rule,
    :define_prompt_template,
    :define_legend,
    :update_template,
    :save_template_as,
    :migrate_session,
    :list_templates,
    # kb-retrieval SPEC §5.3 option 1 — retrieve from / ingest into a kb-agent.
    :kb_query,
    :kb_ingest
  ]

  @doc """
  The canonical set of orchestrator management tool names.

  In normal cc runtime this is read from the orchestrator recipe contribution so
  the transport and executor validate the same contributed MCP surface. The
  fallback keeps the domain app loadable in pluginless test/runtime contexts.
  """
  @spec tool_names() :: [atom()]
  def tool_names do
    case recipe_tool_atoms() do
      {:ok, names} -> names
      :error -> @fallback_tool_names
    end
  end

  @doc """
  Whether `name` is a recognised orchestrator tool.

  Used as a fail-closed guard on the transport boundary: an inbound
  `tools/call` for an unknown name is rejected here, before any cap
  reconstruction or session dispatch, so a typo or a forged tool name never
  reaches an executor. The non-atom clause returns `false` rather than
  raising so malformed wire input is denied, not crashed.
  """
  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in tool_names()
  def tool?(_), do: false

  defp recipe_tool_atoms do
    module = Module.concat([Ezagent, Orchestrator, OrchestratorRecipe])

    if Code.ensure_loaded?(module) and function_exported?(module, :tool_atoms, 0) do
      {:ok, module.tool_atoms()}
    else
      :error
    end
  end
end
