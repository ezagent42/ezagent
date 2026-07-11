defmodule Ezagent.Agent.TransportRearmProbeKind do
  @moduledoc false

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Agent.TransportRearmProbeBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end
