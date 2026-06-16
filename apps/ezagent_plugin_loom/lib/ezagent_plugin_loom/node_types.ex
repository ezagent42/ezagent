defmodule EzagentPluginLoom.NodeTypes do
  @moduledoc """
  Loom vertical UI contract data.

  声明 loom vertical 期望的 node 族 + 角色,供 session template 持久化进
  `template_working_copy`,**不修改 core 或 socialware domain**。实际渲染器在
  domain/web 层(P5 socialware renderer + json-render)。

  node_types = loom scene-card 的卡片类型(对应旧 loom 的 `<span type>`:
  services/companies/detail/steps/form/choices/notice/application/intent + page)。
  """

  @node_types [
    %{"type" => "text", "label" => "Narrative"},
    %{"type" => "services", "label" => "Services"},
    %{"type" => "companies", "label" => "Companies"},
    %{"type" => "detail", "label" => "Detail"},
    %{"type" => "steps", "label" => "Steps"},
    %{"type" => "form", "label" => "Form"},
    %{"type" => "choices", "label" => "Choices"},
    %{"type" => "notice", "label" => "Notice"},
    %{"type" => "application", "label" => "Application"},
    %{"type" => "intent", "label" => "Intent"},
    %{"type" => "page", "label" => "Generated Page"}
  ]

  @default_roles [
    %{"role" => "orchestrator", "label" => "Coordinator"},
    %{"role" => "worker", "label" => "Theme Worker"},
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
      "type" => "services",
      "props" => %{"title" => "Services"},
      "children" => [
        %{"type" => "detail", "props" => %{"text" => "选择一项服务开始"}},
        %{"type" => "choices", "props" => %{"options" => []}}
      ]
    }
  end
end
