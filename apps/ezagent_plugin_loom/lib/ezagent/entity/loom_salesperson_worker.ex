defmodule Ezagent.Entity.LoomSalespersonWorker do
  @moduledoc """
  Loom salespersonworker Kind — the in-session **preview-side AI** worker(Salesperson + AiSpot)。
  和 `Ezagent.Entity.LoomBuilderWorker` 平级,只是 `type_name` 与绑定的 Behavior 不同。

  `entity://agent/<workspace>/loomsalesperson_<name>` — flavor `loomsalesperson`。Ephemeral
  (无状态;对话留在 session chat history)。2026-06-10。
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomsalesperson

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomSalespersonWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
