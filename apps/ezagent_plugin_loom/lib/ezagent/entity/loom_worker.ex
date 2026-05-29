defmodule Ezagent.Entity.LoomWorker do
  @moduledoc """
  Loom worker Kind (loom v0.2, G-E) — a DeepSeek "干活 agent" session
  member. Composes only `Ezagent.Behavior.LoomWorker`.

  `entity://agent/<workspace>/loomworker_<name>` — flavor `loomworker` prefix on
  the name segment (SPEC v3 §3). Modeled on `Ezagent.Entity.Loom`
  (ephemeral, lives under the chat domain's AgentSupervisor). The
  per-session theme prompt lives in the `:loom_worker` slice; a crash
  re-inits to the generic default and the SessionTemplate reconciler
  (G-F) re-applies the slot prompt — so `:ephemeral` is fine.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loomworker

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.LoomWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.AgentSupervisor
end
