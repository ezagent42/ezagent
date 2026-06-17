defmodule Ezagent.Entity.Loom do
  @moduledoc """
  Loom Kind — a fixed-reply test bot. Always answers
  "你好！我是测试机器人！" regardless of the inbound message.

  `entity://agent/<workspace>/loom_<name>` — flavor `loom` prefix on the
  name segment (SPEC v3 §3). Composes only the Loom Behavior; the
  smallest Kind that exercises chat fan-out + a canned reply. Modeled
  on `Ezagent.Entity.Echo` (ephemeral, lives under the chat domain's
  AgentSupervisor) minus the PTY opt-in.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :loom

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Loom]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  # Loom Kinds live under the chat domain's AgentSupervisor (chat's
  # flavor-prefix `spawn_agent/1` resolver routes them there, same as
  # Echo). `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentSupervisor
end
