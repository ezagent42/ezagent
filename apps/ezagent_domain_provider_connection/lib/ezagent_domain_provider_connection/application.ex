defmodule EzagentDomainProviderConnection.Application do
  @moduledoc false
  use Application

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.User

  @impl true
  def start(_type, _args) do
    case register_actions() do
      {:ok, owned} ->
        children = Application.get_env(:ezagent_domain_provider_connection, :children, [])

        case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
          {:ok, supervisor} ->
            {:ok, supervisor}

          {:error, reason} ->
            rollback(owned)
            {:error, reason}
        end

      {:error, reason, owned} ->
        rollback(owned)
        {:error, reason}
    end
  end

  defp register_actions do
    Enum.reduce_while(ProviderConnection.actions(), {:ok, []}, fn action, {:ok, owned} ->
      case CapabilityRegistry.lookup_subject(User, action) do
        {:ok, %{behavior: ProviderConnection}} ->
          {:cont, {:ok, owned}}

        :error ->
          try do
            :ok = CapabilityRegistry.register(User, action, ProviderConnection)
            {:cont, {:ok, [action | owned]}}
          rescue
            error -> {:halt, {:error, error, owned}}
          end

        {:ok, subject} ->
          {:halt, {:error, {:action_conflict, action, subject.behavior}, owned}}
      end
    end)
  end

  defp rollback(actions) do
    Enum.each(actions, fn action ->
      :ok = CapabilityRegistry.unregister(User, action, ProviderConnection)
    end)
  end
end
