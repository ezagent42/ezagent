defmodule Ezagent.ProviderConnection.ProviderAuthorizationBackend do
  @moduledoc """
  Frozen D0 authorization-backend replacement boundary.

  Mutating commands reconcile by their durable correlation id. Implementations
  must return only closed, secret-safe results.
  """

  @type command :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback begin_authorization(command()) :: result()
  @callback consume_callback(command()) :: result()
  @callback reauthenticate(command()) :: result()
  @callback cancel_authorization(command()) :: :ok | result()
end
