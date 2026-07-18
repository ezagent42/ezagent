defmodule Ezagent.ProviderConnection.AssuranceValidator do
  @moduledoc "Validates backend-owned authorization assurances before owner commands execute."

  @type action :: :reauthorize | :revoke | :disconnect
  @type assurance :: map()
  @type context :: map()

  @callback validate(action(), assurance(), context()) :: :ok | {:error, term()}

  @spec validate(module(), action(), assurance(), context()) :: :ok | {:error, term()}
  def validate(module, action, assurance, context) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :validate, 3) do
      module.validate(action, assurance, context)
    else
      _ -> {:error, :invalid_assurance_validator_config}
    end
  end
end
