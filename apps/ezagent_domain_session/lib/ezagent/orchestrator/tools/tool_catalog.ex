defmodule Ezagent.Orchestrator.Tools.ToolCatalog do
  @moduledoc false

  @tool_names [
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
    :list_templates
  ]

  @doc """
  The canonical set of orchestrator management tool names.

  This is the single source of truth the transport layer and `SessionManager`
  use to enumerate / validate the MCP `tools/call` surface, so the list lives
  here rather than being re-derived per call site (which would let the cc
  transport and the session executor drift out of sync).
  """
  @spec tool_names() :: [atom()]
  def tool_names, do: @tool_names

  @doc """
  Whether `name` is a recognised orchestrator tool.

  Used as a fail-closed guard on the transport boundary: an inbound
  `tools/call` for an unknown name is rejected here, before any cap
  reconstruction or session dispatch, so a typo or a forged tool name never
  reaches an executor. The non-atom clause returns `false` rather than
  raising so malformed wire input is denied, not crashed.
  """
  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in @tool_names
  def tool?(_), do: false
end
