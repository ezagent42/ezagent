defmodule EzagentDomainAgentBridge.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Ezagent.AgentBridge.Registry.init()

    Supervisor.start_link([], strategy: :one_for_one, name: EzagentDomainAgentBridge.Supervisor)
  end
end
