defmodule Ezagent.Agent.TestLaunchPersistence do
  @behaviour Ezagent.Agent.LaunchPersistence

  alias Ezagent.Agent.LaunchPersistence.Production

  def inject(attempt_id, instruction, owner) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, attempt_id, {instruction, owner}))
  end

  def clear(attempt_id) do
    ensure_started()
    Agent.update(__MODULE__, &Map.delete(&1, attempt_id))
  end

  @impl true
  def before_transaction(facts) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, facts.attempt_id)) do
      {:barrier_before_commit, owner} ->
        send(owner, {:before_commit, facts.attempt_id, self()})

        receive do
          :release_commit -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def persist(repo, facts) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, facts.attempt_id)) do
      {{:fail, :inventory}, owner} ->
        send(owner, {:persistence_failed, facts.attempt_id, :inventory})
        {:error, :injected_inventory_failure}

      {{:fail, :lineage}, owner} ->
        with {:ok, _} <- Production.record_inventory(repo, facts) do
          send(owner, {:persistence_failed, facts.attempt_id, :lineage})
          {:error, :injected_lineage_failure}
        end

      {:barrier_before_commit, owner} ->
        _ = owner
        Production.persist(repo, facts)

      nil ->
        Production.persist(repo, facts)
    end
  end

  defp ensure_started do
    case Agent.start_link(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
