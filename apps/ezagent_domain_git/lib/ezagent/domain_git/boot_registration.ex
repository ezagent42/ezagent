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

    registrations =
      Enum.map(@actions, &{:capability, GitTaskAccess, &1, @action_set}) ++
        Enum.map(Keyword.get(opts, :adapters, []), fn {id, module} -> {:adapter, id, module} end)

    case register_all(registrations, Keyword.get(opts, :fail_at)) do
      {:ok, owned} ->
        {:ok, owned}

      {:error, reason, owned} ->
        rollback(owned)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, owned) do
    rollback(owned)
    :ok
  end

  @impl true
  def handle_info(:reconcile_adapters, owned) do
    Enum.each(owned, fn
      {:adapter, id, module} ->
        case AdapterRegistry.register(id, module) do
          :ok -> :ok
          {:ok, :already_registered} -> :ok
        end

      _ ->
        :ok
    end)

    {:noreply, owned}
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
end
