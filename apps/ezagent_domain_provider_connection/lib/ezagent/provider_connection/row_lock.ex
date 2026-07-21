defmodule Ezagent.ProviderConnection.RowLock do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias EzagentCore.Repo

  @doc false
  @spec authorization_attempt(Ecto.UUID.t()) :: AuthorizationAttempt.t() | nil
  def authorization_attempt(attempt_ref) do
    AuthorizationAttempt
    |> where([row], row.attempt_ref == ^attempt_ref)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc false
  @spec authorization_backend_record(String.t()) :: AuthorizationBackendRecord.t() | nil
  def authorization_backend_record(authorization_ref) do
    AuthorizationBackendRecord
    |> where([row], row.authorization_ref == ^authorization_ref)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end
end
