defmodule Ezagent.Entity.Agent.OwnershipObligations do
  @moduledoc false

  @doc false
  def establish(workers, spawned_by, workspace, attempt, inventory_mode \\ :record)

  # #201 PR-3 — `inventory_mode` scopes the durable creation-inventory write
  # to the core receipt verdict:
  #   * `:record`        — default; a genuine logical create records its winner row;
  #   * `:replace_stale` — destroy→recreate (`created?` with a PRIOR incarnation's
  #     winner row still durable): delete the stale row, then record N→N+1;
  #   * `:skip`          — rehydrating winner (`:started ∧ ¬created?`): the
  #     original winner row already exists; this attempt is NOT a logical create
  #     and must not touch it.
  def establish(workers, spawned_by, workspace, nil, inventory_mode) do
    case establish_runtime(workers, spawned_by, workspace) do
      {:ok, receipts} ->
        record_inventory(workers, spawned_by, workspace, receipts, inventory_mode)

      {:error, reason, receipts} ->
        {:error, reason, receipts}
    end
  end

  def establish(workers, spawned_by, workspace, attempt, _inventory_mode)
      when is_binary(attempt) and attempt != "" do
    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      case Ezagent.Agent.CreationInventory.exact(attempt, worker, spawned_by, workspace) do
        {:ok, _receipt} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :ownership_receipt_missing}}
      end
    end)
    |> case do
      :ok -> {:ok, []}
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp establish_runtime(workers, spawned_by, workspace) do
    Enum.reduce_while(workers, {:ok, []}, fn worker, {:ok, receipts} ->
      case Ezagent.Entity.Agent.SpawnObligations.record_lineage_with_status(
             worker,
             spawned_by
           ) do
        {:ok, statuses} ->
          receipts =
            receipts
            |> maybe_add_receipt(
              statuses.lineage,
              {:lineage_fact, worker, spawned_by}
            )
            |> maybe_add_receipt(
              statuses.derivation_edge,
              {:spawned_by_edge, worker, spawned_by}
            )

          case Ezagent.Entity.Agent.SpawnObligations.bind_workspace(worker, workspace) do
            :ok ->
              {:cont, {:ok, receipts}}

            other ->
              {:halt, {:error, {:post_spawn_obligation_failed, worker, other}, receipts}}
          end

        other ->
          {:halt, {:error, {:post_spawn_obligation_failed, worker, other}, receipts}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      {:error, reason, receipts} -> {:error, reason, Enum.reverse(receipts)}
    end
  rescue
    error -> {:error, {:post_spawn_obligation_failed, :exception, error}, []}
  end

  defp maybe_add_receipt(receipts, :inserted, receipt), do: [receipt | receipts]
  defp maybe_add_receipt(receipts, :exists, _receipt), do: receipts

  defp record_inventory(_workers, _spawned_by, _workspace, receipts, :skip), do: {:ok, receipts}

  defp record_inventory(workers, spawned_by, workspace, lineage_receipts, mode)
       when mode in [:record, :replace_stale] do
    Enum.reduce_while(workers, {:ok, lineage_receipts}, fn worker, {:ok, receipts} ->
      if mode == :replace_stale do
        :ok = Ezagent.Agent.CreationInventory.delete_winner(worker)
      end

      attempt = Ezagent.Agent.CreationInventory.new_attempt_id()
      receipt = {:creation_inventory, attempt, worker, spawned_by, workspace}

      case Ezagent.Agent.CreationInventory.record(attempt, worker, spawned_by, workspace) do
        :ok ->
          {:cont, {:ok, [receipt | receipts]}}

        {:error, reason} ->
          {:halt, {:error, {:creation_inventory_failed, reason}, [receipt | receipts]}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      {:error, reason, receipts} -> {:error, reason, Enum.reverse(receipts)}
    end
  end
end
