defmodule Ezagent.Entity.LoomStitchSubWorker do
  @moduledoc """
  Stitch sub-worker Kind (2026-06-12) — composes only
  `Ezagent.Behavior.LoomStitchSubWorker`. One per Stitch role,
  `entity://agent/<workspace>/loomstitchsub_<sid>_<role>` (flavor
  `loomstitchsub`). Ephemeral, under the chat domain's AgentSupervisor —
  role comes from the URI name, no per-instance state to persist.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomstitchsub

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomStitchSubWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
