defmodule Ezagent.Entity.LoomBuilderWorker do
  @moduledoc """
  Loom builderworker Kind — the in-session "AI page generator" worker. Modeled
  on `Ezagent.Entity.LoomWorker`; only differences are `type_name` (axis
  for caps) and the bound Behavior.

  `entity://agent/<workspace>/loombuilder_<name>` — flavor `loombuilder`. Ephemeral
  (re-spawns clean; canonical state lives on the orchestrator's
  `:loom_source` slice + session chat history's `page_update` spans).

  See `docs/loom/2026-06-01-loom-as-session-redesign.md` §3.2.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loombuilder

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomBuilderWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
