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
          | :assurance_validator_misconfigured

  @callback validate(action(), assurance(), context()) :: :ok | {:error, error_reason()}

  @doc "Validates assurance through a configured implementation that satisfies this behaviour."
  @spec validate(module(), action(), assurance(), context()) :: :ok | {:error, error_reason()}
  def validate(module, action, assurance, context) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :validate, 3) do
      closed_validate(module, action, assurance, context)
    else
      _ -> {:error, :invalid_assurance_validator_config}
    end
  end

  defp closed_validate(module, action, assurance, context) do
    try do
      case module.validate(action, assurance, context) do
        :ok ->
          :ok

        {:error, reason}
        when reason in [:assurance_rejected, :assurance_validation_unavailable] ->
          {:error, reason}

        _other ->
          {:error, :assurance_validator_misconfigured}
      end
    catch
      _kind, _reason -> {:error, :assurance_validator_misconfigured}
    end
  end
end
