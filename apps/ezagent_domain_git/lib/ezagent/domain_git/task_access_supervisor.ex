defmodule Ezagent.DomainGit.TaskAccessSupervisor do
  @moduledoc """
  Owns the live, ephemeral `GitTaskAccess` Resource processes.

  Policies are revalidated before spawning. A duplicate URI is reconciled
  against the one authoritative live Lifecycle slice: equal policy is
  idempotent and unequal policy is rejected.
  """

  use DynamicSupervisor

  alias Ezagent.Entity.GitTaskAccess

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts or reconciles the Resource instance for an authoritative policy."
  @spec ensure_started(term()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(policy) do
    with {:ok, validated} <- GitTaskAccess.revalidate(policy) do
      uri = GitTaskAccess.uri_from_args(validated)

      case Ezagent.Kind.spawn(GitTaskAccess, %{uri: uri, policy: validated}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_registered, _uri}} ->
          reconcile_duplicate(uri, validated)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Synchronously removes a live Resource; absent teardown is idempotent."
  @spec teardown(URI.t()) :: :ok | {:error, :teardown_incomplete}
  def teardown(%URI{} = uri) do
    :ok = Ezagent.Kind.terminate(uri)
    await_unregistered(uri, 100)
  end

  defp reconcile_duplicate(uri, policy) do
    with :ok <- GitTaskAccess.initialization_result(uri, policy),
         {:ok, pid} <- Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_unregistered(uri, attempts) when attempts > 0 do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        :ok

      {:ok, _pid} ->
        receive do
        after
          1 -> await_unregistered(uri, attempts - 1)
        end
    end
  end

  defp await_unregistered(_uri, 0), do: {:error, :teardown_incomplete}
end
