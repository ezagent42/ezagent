defmodule Ezagent.ProviderConnection.HandoffFinalizer do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias EzagentCore.Repo

  @doc false
  def prepare(authorization_ref) when is_binary(authorization_ref) do
    locked_transition(authorization_ref, fn
      %AuthorizationBackendRecord{lifecycle_status: "handoff_finalization_pending"} = row ->
        if coherent_pending?(row), do: :ok, else: Repo.rollback(:credential_conflict)

      %AuthorizationBackendRecord{lifecycle_status: "shredded"} = row ->
        if coherent_shredded?(row), do: :ok, else: Repo.rollback(:credential_conflict)

      %AuthorizationBackendRecord{} = row ->
        row
        |> AuthorizationBackendRecord.prepare_handoff_finalization_changeset()
        |> Repo.update()
        |> normalize_or_rollback()
    end)
  end

  def prepare(_authorization_ref), do: {:error, :credential_conflict}

  @doc false
  def finalize(authorization_ref) when is_binary(authorization_ref) do
    locked_transition(authorization_ref, fn
      %AuthorizationBackendRecord{lifecycle_status: "shredded"} = row ->
        if coherent_shredded?(row), do: :ok, else: Repo.rollback(:credential_conflict)

      %AuthorizationBackendRecord{} = row ->
        row
        |> AuthorizationBackendRecord.finalize_handoff_changeset(DateTime.utc_now())
        |> Repo.update()
        |> normalize_or_rollback()
    end)
  end

  def finalize(_authorization_ref), do: {:error, :credential_conflict}

  defp locked_transition(authorization_ref, transition) do
    Repo.transaction(fn ->
      row =
        AuthorizationBackendRecord
        |> where([record], record.authorization_ref == ^authorization_ref)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if row, do: transition.(row), else: Repo.rollback(:credential_conflict)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :credential_conflict}
    end
  end

  defp coherent_pending?(record),
    do:
      present?(record.handoff_ref) and present?(record.handoff_ciphertext) and
        is_nil(record.shredded_at)

  defp coherent_shredded?(record),
    do:
      present?(record.handoff_ref) and is_nil(record.handoff_ciphertext) and
        is_struct(record.shredded_at, DateTime)

  defp present?(value), do: is_binary(value) and byte_size(value) > 0

  defp normalize_or_rollback({:ok, _row}), do: :ok
  defp normalize_or_rollback({:error, _changeset}), do: Repo.rollback(:credential_conflict)
end
