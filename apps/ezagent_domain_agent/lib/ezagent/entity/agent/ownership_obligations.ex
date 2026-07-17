defmodule Ezagent.Entity.Agent.OwnershipObligations do
  @moduledoc false

  @doc false
  def establish(workers, spawned_by, workspace, nil) do
    with :ok <- establish_runtime(workers, spawned_by, workspace) do
      record_inventory(workers, spawned_by, workspace)
    end
  end

  def establish(workers, spawned_by, workspace, attempt)
      when is_binary(attempt) and attempt != "" do
    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      case Ezagent.Agent.CreationInventory.exact(attempt, worker, spawned_by, workspace) do
        {:ok, _receipt} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :ownership_receipt_missing}}
      end
    end)
  end

  defp establish_runtime(workers, spawned_by, workspace) do
    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      with :ok <- Ezagent.Entity.Agent.SpawnObligations.record_lineage(worker, spawned_by),
           :ok <- Ezagent.Entity.Agent.SpawnObligations.bind_workspace(worker, workspace) do
        {:cont, :ok}
      else
        other -> {:halt, {:error, {:post_spawn_obligation_failed, worker, other}}}
      end
    end)
  rescue
    error -> {:error, {:post_spawn_obligation_failed, :exception, error}}
  end

  defp record_inventory(workers, spawned_by, workspace) do
    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      attempt = Ezagent.Agent.CreationInventory.new_attempt_id()

      case Ezagent.Agent.CreationInventory.record(attempt, worker, spawned_by, workspace) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:creation_inventory_failed, reason}}}
      end
    end)
  end
end
