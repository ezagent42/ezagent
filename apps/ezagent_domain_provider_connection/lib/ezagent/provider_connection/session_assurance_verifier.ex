defmodule Ezagent.ProviderConnection.SessionAssuranceVerifier do
  @moduledoc """
  Trusted-session verification and replay-consumption port.

  An implementation must cryptographically authenticate every assurance field
  and atomically consume its `reauth_ref`/`reauth_version` proof coordinate.
  Returning `:ok` means both authentication and one-time consumption committed;
  a validate-then-consume split is not a valid implementation.

  D1 has no production implementation. A separately approved trusted-session
  authority may implement this port in a follow-up phase.
  """

  @type action :: :reauthorize | :revoke | :disconnect
  @type assurance :: Ezagent.ProviderConnection.Assurance.t()
  @type verification_context :: %{
          required(:owner_uri) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:grantee_uri) => URI.t(),
          required(:connection_id) => String.t(),
          required(:connection_version) => non_neg_integer(),
          required(:verified_at) => DateTime.t()
        }
  @type error_reason ::
          :assurance_rejected
          | :assurance_replayed
          | :assurance_validation_unavailable
          | :invalid_session_assurance_verifier
          | :session_assurance_verifier_misconfigured

  @callback verify_and_consume(term(), action(), assurance(), verification_context()) ::
              :ok
              | {:error,
                 :assurance_rejected
                 | :assurance_replayed
                 | :assurance_validation_unavailable}

  @doc "Calls a verifier instance through a closed, secret-free result boundary."
  @spec verify_and_consume(module(), term(), action(), assurance(), verification_context()) ::
          :ok | {:error, error_reason()}
  def verify_and_consume(module, verifier_state, action, assurance, context)
      when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :verify_and_consume, 4),
         true <- closed_context?(context) do
      closed_verify_and_consume(module, verifier_state, action, assurance, context)
    else
      _ -> {:error, :invalid_session_assurance_verifier}
    end
  end

  def verify_and_consume(_module, _state, _action, _assurance, _context),
    do: {:error, :invalid_session_assurance_verifier}

  defp closed_verify_and_consume(module, verifier_state, action, assurance, context) do
    try do
      case module.verify_and_consume(verifier_state, action, assurance, context) do
        :ok ->
          :ok

        {:error, reason}
        when reason in [
               :assurance_rejected,
               :assurance_replayed,
               :assurance_validation_unavailable
             ] ->
          {:error, reason}

        _other ->
          {:error, :session_assurance_verifier_misconfigured}
      end
    catch
      _kind, _reason -> {:error, :session_assurance_verifier_misconfigured}
    end
  end

  defp closed_context?(
         %{
           owner_uri: %URI{},
           workspace_uri: %URI{},
           grantee_uri: %URI{},
           connection_id: connection_id,
           connection_version: connection_version,
           verified_at: %DateTime{}
         } = context
       ) do
    MapSet.new(Map.keys(context)) ==
      MapSet.new([
        :owner_uri,
        :workspace_uri,
        :grantee_uri,
        :connection_id,
        :connection_version,
        :verified_at
      ]) and is_binary(connection_id) and byte_size(connection_id) > 0 and
      is_integer(connection_version) and connection_version >= 0
  end

  defp closed_context?(_context), do: false
end
