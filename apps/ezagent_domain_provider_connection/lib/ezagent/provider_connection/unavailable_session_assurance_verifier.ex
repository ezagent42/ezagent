defmodule Ezagent.ProviderConnection.UnavailableSessionAssuranceVerifier do
  @moduledoc """
  Production fail-closed verifier for deferred session assurance.

  D1 intentionally provides no production path for reauthorize, revoke, or
  disconnect. Their public boundary is hard-wired to this implementation.
  """

  @behaviour Ezagent.ProviderConnection.SessionAssuranceVerifier

  @doc false
  def verify_and_consume(action, assurance, context),
    do: verify_and_consume(nil, action, assurance, context)

  @impl true
  def verify_and_consume(_state, _action, _assurance, _context),
    do: {:error, :assurance_validation_unavailable}
end
