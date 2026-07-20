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
  @doc """
  Revokes a credential with an explicit stable idempotency key.

  Implementations must treat `command.idempotency_key` as the logical-effect
  identity and return the same success for exact retries. Multiple physical
  calls may overlap after a lease expires; they must apply at most one logical
  destructive effect for the same key.
  """
  @callback revoke(%{required(:idempotency_key) => String.t(), optional(atom()) => term()}) ::
              :ok | result()
end
