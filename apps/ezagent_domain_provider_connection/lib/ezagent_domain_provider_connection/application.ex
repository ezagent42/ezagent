defmodule EzagentDomainProviderConnection.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Ezagent.ProviderConnection.RegistryReadiness, []},
        {Ezagent.ProviderConnection.DriverRegistry, []},
        {Ezagent.ProviderConnection.BackendPairRegistry, []},
        {Ezagent.ProviderConnection.RegistryOwner, []}
      ] ++
        Application.get_env(:ezagent_domain_provider_connection, :children, []) ++
        [
          {Ezagent.ProviderConnection.Recovery,
           Application.get_env(:ezagent_domain_provider_connection, :recovery_options, [])}
        ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: __MODULE__)
  end
end
