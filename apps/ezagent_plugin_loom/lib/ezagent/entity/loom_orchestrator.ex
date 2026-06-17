defmodule Ezagent.Entity.LoomOrchestrator do
  @moduledoc """
  Loom orchestrator Kind (loom v0.2, G-D) — the DeepSeek-brained
  session member that decomposes a user turn, fans out to workers,
  aggregates, and composes the reply. Composes only
  `Ezagent.Behavior.LoomOrchestrator`.

  `entity://agent/<workspace>/loomorch_<name>` — flavor `loomorch` prefix.
  Lives under the chat domain's AgentSupervisor.

  Persistence is `{:snapshot, :on_change}` so the aggregation state (the
  `:loom_orchestrator` slice's `pending` turns) survives a graceful
  restart — per PRD §5.3 (待聚合状态持久化). Note the in-memory timeout
  timer is NOT persisted; a restart loses it (PRD §9 known limitation).
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomorch

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomOrchestrator]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
