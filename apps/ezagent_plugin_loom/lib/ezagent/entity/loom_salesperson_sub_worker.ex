defmodule Ezagent.Entity.LoomSalespersonSubWorker do
  @moduledoc """
  Salesperson sub-worker Kind (2026-06-12) — composes only
  `Ezagent.Behavior.LoomSalespersonSubWorker`. One per Salesperson role,
  `entity://agent/<workspace>/loomsalespersonsub_<sid>_<role>` (flavor
  `loomsalespersonsub`). Ephemeral, under the chat domain's AgentSupervisor —
  role comes from the URI name, no per-instance state to persist.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomsalespersonsub

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomSalespersonSubWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
