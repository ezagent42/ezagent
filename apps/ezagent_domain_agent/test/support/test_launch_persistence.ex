defmodule Ezagent.Agent.TestLaunchPersistence do
  def inject(attempt_id, instruction, owner) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, attempt_id, {instruction, owner}))
  end

  def clear(attempt_id) do
    ensure_started()
    Agent.update(__MODULE__, &Map.delete(&1, attempt_id))
  end

  def hook(stage, facts) do
    ensure_started()

    case {stage, Agent.get(__MODULE__, &Map.get(&1, facts.attempt_id))} do
      {:before_inventory, {{:fail, :inventory}, owner}} ->
        send(owner, {:persistence_failed, facts.attempt_id, :inventory})
        {:error, :injected_inventory_failure}

      {:before_lineage, {{:fail, :lineage}, owner}} ->
        send(owner, {:persistence_failed, facts.attempt_id, :lineage})
        {:error, :injected_lineage_failure}

      {:before_commit, {:barrier_before_commit, owner}} ->
        send(owner, {:before_commit, facts.attempt_id, self()})

        receive do
          :release_commit -> :ok
        end

      _ ->
        :ok
    end
  end

  defp ensure_started do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
