defmodule Ezagent.ProviderConnection.AssuranceValidator do
  @moduledoc "Validates backend-owned authorization assurances before owner commands execute."

  @type action :: :reauthorize | :revoke | :disconnect
  @type assurance :: Ezagent.ProviderConnection.Assurance.t()
  @type context :: %{
          required(:self_uri) => URI.t(),
          required(:caller) => URI.t(),
          optional(atom()) => term()
        }
  @type error_reason ::
          :assurance_rejected
          | :assurance_validation_unavailable
          | :invalid_assurance_validator_config

  @callback validate(action(), assurance(), context()) :: :ok | {:error, error_reason()}

  @doc "Validates assurance through a configured implementation that satisfies this behaviour."
  @spec validate(module(), action(), assurance(), context()) :: :ok | {:error, error_reason()}
  def validate(module, action, assurance, context) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :validate, 3) do
      module.validate(action, assurance, context)
    else
      _ -> {:error, :invalid_assurance_validator_config}
    end
  end
end
