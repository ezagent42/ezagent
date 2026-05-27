defmodule EzagentDomainAgentBridge.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Ezagent.AgentBridge.Registry.init()

    children = [
      Ezagent.AgentBridge.AdapterRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EzagentDomainAgentBridge.Supervisor)
  end
end
