defmodule Ezagent.ProviderConnection.Types do
  @moduledoc "Closed provider-connection values used by the durable aggregate."
  @statuses ~w(pending_authorization active refresh_required refreshing degraded expired revoking revoked disconnecting disconnected)a
  @attempt_statuses ~w(pending consuming consumed cancelled expired)a
  @operation_statuses ~w(prepared backend_committed connection_committed finalized fenced cleanup_pending)a
  @errors ~w(invalid_subject invalid_method invalid_host state_mismatch pkce_mismatch callback_expired callback_replayed callback_in_progress correlation_conflict account_conflict stale_version reauthentication_failed backend_unavailable credential_conflict credential_revocation_failed refresh_lease_lost provider_denied provider_protocol_failed cleanup_pending connection_terminal)a
  def statuses, do: @statuses
  def attempt_statuses, do: @attempt_statuses
  def operation_statuses, do: @operation_statuses
  def errors, do: @errors
end
