defmodule Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend do
  @moduledoc false

  alias Ezagent.DomainGit.D0BackendReuseGate.Types

  @callback store(Types.store_request()) ::
              {:ok, Types.credential_record()} | {:error, Types.credential_error()}

  @callback replace(Types.replace_request()) ::
              {:ok, Types.credential_record()} | {:error, Types.credential_error()}

  @callback status(Types.status_request()) ::
              {:ok, Types.credential_status()} | {:error, Types.credential_error()}

  @callback lease_for_operation(Types.operation_lease_request()) ::
              {:ok, Types.credential_lease()} | {:error, Types.credential_error()}

  @callback consume_lease(Types.consume_lease_request()) ::
              :ok | {:error, Types.credential_error()}

  @callback revoke(Types.revoke_request()) ::
              {:ok, Types.credential_record()} | {:error, Types.credential_error()}
end
