defmodule Ezagent.DomainGit.TaskAccessSupervisor do
  @moduledoc """
  Owns the live, ephemeral `GitTaskAccess` entity processes.

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

  @doc "Starts or reconciles the entity instance for an authoritative policy."
  @spec ensure_started(term()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_started(policy) do
    with {:ok, validated} <- GitTaskAccess.revalidate(policy) do
      uri = GitTaskAccess.uri_from_args(validated)
      with_lifecycle(uri, fn -> spawn_or_reconcile(uri, validated) end)
    end
  end

  @doc "Synchronously removes a live entity; absent teardown is idempotent."
  @spec teardown(URI.t()) :: :ok | {:error, :teardown_incomplete}
  def teardown(%URI{} = uri) do
    with_lifecycle(uri, fn ->
      :ok = Ezagent.Kind.terminate(uri)
      await_unregistered(uri, 100)
    end)
  end

  @doc "Serializes a lifecycle or operation-entry decision for one entity URI."
  @spec with_lifecycle(URI.t(), (-> result)) :: result when result: var
  def with_lifecycle(%URI{} = uri, fun) when is_function(fun, 0) do
    lock_id = {{__MODULE__, URI.to_string(uri)}, self()}
    :global.trans(lock_id, fun, [node()])
  end

  defp spawn_or_reconcile(uri, policy) do
    # derivation-edge: non-principal ephemeral task-access policy Kind
    # V5 A1c — the public contract carries the entity URI; the Kind pid
    # stays behind the actor-app seam (Kind.spawn / KindRegistry).
    case Ezagent.Kind.spawn(GitTaskAccess, %{uri: uri, policy: policy}) do
      {:ok, _pid} -> {:ok, uri}
      {:error, {:already_registered, _uri}} -> reconcile_duplicate(uri, policy)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_duplicate(uri, policy) do
    # §2.2 read surface (`Kind.alive?/1`) — no KindRegistry reach-in (V5 A1c).
    with :ok <- GitTaskAccess.initialization_result(uri, policy),
         true <- Ezagent.Kind.alive?(uri) do
      {:ok, uri}
    else
      :error -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_unregistered(uri, attempts) when attempts > 0 do
    if Ezagent.Kind.alive?(uri) do
      receive do
      after
        1 -> await_unregistered(uri, attempts - 1)
      end
    else
      :ok
    end
  end

  defp await_unregistered(_uri, 0), do: {:error, :teardown_incomplete}
end
