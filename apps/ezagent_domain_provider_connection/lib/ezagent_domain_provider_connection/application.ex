defmodule EzagentDomainProviderConnection.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [{Ezagent.ProviderConnection.RegistryOwner, []}] ++
        Application.get_env(:ezagent_domain_provider_connection, :children, [])

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
