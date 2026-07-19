defmodule Ezagent.ProviderConnection.CredentialBackend do
  @moduledoc """
  Frozen D0 credential-backend replacement boundary.

  No callback provides generic plaintext retrieval. Credential use is released
  only through the operation-bound lease protocol.
  """

  @type command :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback store(command()) :: result()
  @callback replace(command()) :: result()
  @callback status(command()) :: result()
  @callback lease_for_operation(command()) :: result()
  @callback consume_lease(command()) :: :ok | result()
  @callback revoke(command()) :: :ok | result()
end
