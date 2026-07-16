defmodule Ezagent.DomainGit.BootRegistration do
  @moduledoc false

  use GenServer

  alias Ezagent.DomainGit.AdapterRegistry
  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]
  @action_set Ezagent.ActionSet.GitTaskAccess

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    desired_adapters = Keyword.get(opts, :adapters, [])

    registrations =
      Enum.map(@actions, &{:capability, GitTaskAccess, &1, @action_set}) ++
        Enum.map(desired_adapters, fn {id, module} -> {:adapter, id, module} end)

    case register_all(registrations, Keyword.get(opts, :fail_at)) do
      {:ok, owned} ->
        {:ok,
         %{
           desired_adapters: desired_adapters,
           owned_adapters: owned_adapters(owned),
           owned_capabilities: owned_capabilities(owned)
         }}

      {:error, reason, owned} ->
        rollback(owned)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    rollback(state.owned_adapters ++ state.owned_capabilities)
    :ok
  end

  @impl true
  def handle_info(:reconcile_adapters, state) do
    Enum.each(state.desired_adapters, fn {id, module} ->
      case AdapterRegistry.register(id, module) do
        :ok -> :ok
        {:ok, :already_registered} -> :ok
      end
    end)

    {:noreply, state}
  end

  defp register_all(registrations, fail_at) do
    registrations
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {registration, index}, {:ok, owned} ->
      if index == fail_at do
        {:halt, {:error, {:injected_registration_failure, index}, owned}}
      else
        case register(registration) do
          {:ok, true} -> {:cont, {:ok, [registration | owned]}}
          {:ok, false} -> {:cont, {:ok, owned}}
          {:error, reason} -> {:halt, {:error, reason, owned}}
        end
      end
    end)
  end

  defp register({:capability, kind, action, behavior} = registration) do
    case Ezagent.CapabilityRegistry.lookup_subject(kind, action) do
      {:ok, %{behavior: ^behavior}} ->
        {:ok, false}

      :error ->
        :ok = Ezagent.CapabilityRegistry.register(kind, action, behavior)
        {:ok, true}

      {:ok, %{behavior: other}} ->
        {:error, {:capability_conflict, registration, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp register({:adapter, id, module}) do
    case AdapterRegistry.register(id, module) do
      :ok -> {:ok, true}
      {:ok, :already_registered} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(owned) do
    Enum.each(owned, fn
      {:capability, kind, action, behavior} ->
        Ezagent.CapabilityRegistry.unregister(kind, action, behavior)

      {:adapter, id, module} ->
        AdapterRegistry.unregister(id, module)
    end)
  end

  defp owned_adapters(owned) do
    Enum.filter(owned, &match?({:adapter, _, _}, &1))
  end

  defp owned_capabilities(owned) do
    Enum.filter(owned, &match?({:capability, _, _, _}, &1))
  end
end
