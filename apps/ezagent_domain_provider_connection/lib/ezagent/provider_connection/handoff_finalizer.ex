defmodule Ezagent.ProviderConnection.HandoffFinalizer do
  @moduledoc false

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias EzagentCore.Repo

  @doc false
  def prepare(authorization_ref) when is_binary(authorization_ref) do
    case Repo.get_by(AuthorizationBackendRecord, authorization_ref: authorization_ref) do
      %AuthorizationBackendRecord{shredded_at: nil} = row ->
        row
        |> Ecto.Changeset.change(lifecycle_status: "handoff_finalization_pending")
        |> Repo.update()
        |> normalize()

      %AuthorizationBackendRecord{lifecycle_status: "shredded"} ->
        :ok

      _ ->
        {:error, :credential_conflict}
    end
  end

  def prepare(_authorization_ref), do: {:error, :credential_conflict}

  @doc false
  def finalize(authorization_ref) when is_binary(authorization_ref) do
    case Repo.get_by(AuthorizationBackendRecord, authorization_ref: authorization_ref) do
      %AuthorizationBackendRecord{
        shredded_at: nil,
        lifecycle_status: "handoff_finalization_pending"
      } = row ->
        row
        |> Ecto.Changeset.change(
          handoff_ciphertext: nil,
          shredded_at: DateTime.utc_now(),
          lifecycle_status: "shredded"
        )
        |> Repo.update()
        |> normalize()

      %AuthorizationBackendRecord{} ->
        :ok

      nil ->
        {:error, :credential_conflict}
    end
  end

  def finalize(_authorization_ref), do: {:error, :credential_conflict}

  defp normalize({:ok, _row}), do: :ok
  defp normalize({:error, _changeset}), do: {:error, :credential_conflict}
end
