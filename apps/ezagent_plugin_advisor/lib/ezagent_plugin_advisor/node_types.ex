defmodule EzagentPluginAdvisor.NodeTypes do
  @moduledoc """
  Advisor vertical UI contract data.

  P5 keeps the actual socialware renderer in the domain/web layers. This
  module declares the node families and roles the advisor vertical expects,
  so the session template can persist them in `template_working_copy` without
  modifying core or the socialware domain.
  """

  @node_types [
    %{"type" => "text", "label" => "Narrative"},
    %{"type" => "table", "label" => "Comparison Table"},
    %{"type" => "code", "label" => "Executable Example"},
    %{"type" => "advisor.summary", "label" => "Advisor Summary"}
  ]

  @default_roles [
    %{"role" => "orchestrator", "label" => "Coordinator"},
    %{"role" => "nl", "label" => "Answer Writer"},
    %{"role" => "page", "label" => "Page Builder"},
    %{"role" => "operator", "label" => "Human Operator"}
  ]

  @spec node_types() :: [map()]
  def node_types, do: @node_types

  @spec default_roles() :: [map()]
  def default_roles, do: @default_roles

  @spec sample_tree() :: map()
  def sample_tree do
    %{
      "type" => "advisor.summary",
      "props" => %{"title" => "Advisor Summary"},
      "children" => [
        %{"type" => "text", "props" => %{"text" => "Recommendation"}},
        %{"type" => "table", "props" => %{"columns" => ["Option", "Fit"], "rows" => []}}
      ]
    }
  end
end
