Code.require_file(Path.expand("refresh_exchange_backend_support.ex", __DIR__))

defmodule Ezagent.ProviderConnection.Test.RemoteRefreshExchangeEndpoint do
  @moduledoc false

  use GenServer

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.Test.RefreshExchangeBackendSupport

  def begin(backend, command) do
    with {:ok, %RefreshUse{} = protected_use} <-
           RefreshExchangeBackendSupport.begin(backend, command),
         {:ok, endpoint} <- GenServer.start(__MODULE__, {backend, protected_use}) do
      proxy_use =
        RefreshUse.new(
          RefreshUse.authority(protected_use),
          RefreshUse.token(protected_use),
          RefreshUse.binding_digest(protected_use),
          backend,
          %{endpoint: endpoint}
        )

      observe_proxy(proxy_use)
      {:ok, proxy_use}
    end
  end

  def consume(backend, %{refresh_use: %RefreshUse{} = proxy_use, provider_exchange: exchange})
      when is_function(exchange, 1) do
    with %{endpoint: endpoint} when is_pid(endpoint) <- RefreshUse.private(proxy_use) do
      GenServer.call(endpoint, {:consume, backend, proxy_use, exchange})
    else
      _ -> {:error, :correlation_conflict}
    end
  catch
    :exit, _reason -> {:error, :correlation_conflict}
  end

  def consume(_backend, _request), do: {:error, :correlation_conflict}

  @impl true
  def init({backend, protected_use}) do
    monitor = Process.monitor(RefreshUse.authority(protected_use))
    {:ok, %{backend: backend, protected_use: protected_use, monitor: monitor}}
  end

  @impl true
  def handle_call(
        {:consume, backend, proxy_use, exchange},
        _from,
        %{backend: backend, protected_use: protected_use} = state
      ) do
    with true <- RefreshUse.authority(proxy_use) == RefreshUse.authority(protected_use),
         true <- RefreshUse.token(proxy_use) == RefreshUse.token(protected_use),
         true <- RefreshUse.binding_digest(proxy_use) == RefreshUse.binding_digest(protected_use),
         proof when is_reference(proof) <- RefreshUse.claim_proof(proxy_use) do
      claimed_protected_use = RefreshUse.claimed(protected_use, proof)

      result =
        RefreshExchangeBackendSupport.consume(backend, %{
          refresh_use: claimed_protected_use,
          provider_exchange: exchange
        })

      {:stop, :normal, result, state}
    else
      _ -> {:reply, {:error, :correlation_conflict}, state}
    end
  end

  def handle_call({:consume, _backend, _proxy_use, _exchange}, _from, state),
    do: {:reply, {:error, :correlation_conflict}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _authority, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  defp observe_proxy(use) do
    case Application.get_env(:ezagent_domain_provider_connection, :refresh_use_observer) do
      observer when is_function(observer, 2) -> observer.(:remote_proxy, use)
      _ -> :ok
    end
  end
end
