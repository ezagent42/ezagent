defmodule Ezagent.ProviderConnection.Types do
  @moduledoc "Closed provider-connection values used by the durable aggregate."
  @statuses ~w(pending_authorization active refresh_required refreshing degraded expired revoking revoked disconnecting disconnected failed)a
  @attempt_statuses ~w(beginning pending consuming consumed cancelled expired)a
  @operation_statuses ~w(prepared backend_committed connection_committed finalized fenced cleanup_pending)a
  @errors ~w(invalid_subject invalid_method invalid_host state_mismatch pkce_mismatch callback_expired callback_replayed callback_in_progress correlation_conflict account_conflict stale_version reauthentication_failed backend_unavailable credential_conflict credential_revocation_failed refresh_lease_lost provider_denied provider_protocol_failed cleanup_pending connection_terminal)a
  @type connection_id :: String.t()
  @type attempt_ref :: String.t()
  @type authorization_ref :: String.t()
  @type provider_id :: String.t()
  @type operation_class :: :store | :replace | :refresh | :revoke | :disconnect
  @type status ::
          :pending_authorization
          | :active
          | :refresh_required
          | :refreshing
          | :degraded
          | :expired
          | :revoking
          | :revoked
          | :disconnecting
          | :disconnected
          | :failed
  @type attempt_status :: :beginning | :pending | :consuming | :consumed | :cancelled | :expired
  @type operation_status ::
          :prepared
          | :backend_committed
          | :connection_committed
          | :finalized
          | :fenced
          | :cleanup_pending
  @type consume_status :: :pending | :committed
  @type error ::
          :invalid_subject
          | :invalid_method
          | :invalid_host
          | :state_mismatch
          | :pkce_mismatch
          | :callback_expired
          | :callback_replayed
          | :callback_in_progress
          | :correlation_conflict
          | :account_conflict
          | :stale_version
          | :reauthentication_failed
          | :backend_unavailable
          | :credential_conflict
          | :credential_revocation_failed
          | :refresh_lease_lost
          | :provider_denied
          | :provider_protocol_failed
          | :cleanup_pending
          | :connection_terminal

  @doc "Returns every valid durable connection status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
  @doc "Returns every valid authorization-attempt status."
  @spec attempt_statuses() :: [attempt_status()]
  def attempt_statuses, do: @attempt_statuses
  @doc "Returns every valid idempotent-operation status."
  @spec operation_statuses() :: [operation_status()]
  def operation_statuses, do: @operation_statuses
  @doc "Returns the closed set of safe provider-connection error codes."
  @spec errors() :: [error()]
  def errors, do: @errors
end
