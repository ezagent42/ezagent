defmodule Ezagent.Entity.LoomStitchWorker do
  @moduledoc """
  Loom stitchworker Kind — the in-session **preview-side AI** worker(Stitch + AiSpot)。
  和 `Ezagent.Entity.LoomV0Worker` 平级,只是 `type_name` 与绑定的 Behavior 不同。

  `entity://agent/<workspace>/loomstitch_<name>` — flavor `loomstitch`。Ephemeral
  (无状态;对话留在 session chat history)。2026-06-10。
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomstitch

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomStitchWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
