defmodule EzagentDomainPty.Test.PtyAgentKind do
  @moduledoc false

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Pty]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end
