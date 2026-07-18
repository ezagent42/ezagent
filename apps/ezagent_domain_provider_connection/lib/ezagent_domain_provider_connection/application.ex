defmodule EzagentDomainProviderConnection.Application do
  @moduledoc false
  use Application

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.User

  @impl true
  def start(_type, _args) do
    children = Application.get_env(:ezagent_domain_provider_connection, :children, [])

    with {:ok, supervisor} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      case register_actions() do
        {:ok, _owned} ->
          {:ok, supervisor}

        {:error, reason, owned} ->
          rollback(owned)
          Supervisor.stop(supervisor)
          {:error, reason}
      end
    end
  end

  defp register_actions do
    Enum.reduce_while(ProviderConnection.actions(), {:ok, []}, fn action, {:ok, owned} ->
      case CapabilityRegistry.register_owned(User, action, ProviderConnection) do
        :existing_identical ->
          {:cont, {:ok, owned}}

        :acquired ->
          {:cont, {:ok, [action | owned]}}

        {:error, reason} ->
          {:halt, {:error, reason, owned}}
      end
    end)
  end

  defp rollback(actions) do
    Enum.each(actions, fn action ->
      :ok = CapabilityRegistry.unregister(User, action, ProviderConnection)
    end)
  end
end
