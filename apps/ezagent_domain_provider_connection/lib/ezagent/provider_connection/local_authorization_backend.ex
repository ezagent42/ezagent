defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend do
  @moduledoc "Durable local provider-authorization facade."
  @behaviour Ezagent.ProviderConnection.ProviderAuthorizationBackend

  alias Ezagent.ProviderConnection.HandoffFinalizer
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Exchange
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Lifecycle
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Reconciliation

  @impl true
  defdelegate begin_authorization(request), to: Exchange
  @impl true
  defdelegate consume_callback(request), to: Exchange
  @impl true
  defdelegate cancel_authorization(request), to: Lifecycle
  @impl true
  defdelegate reauthenticate(request), to: Lifecycle

  @doc false
  defdelegate reconcile_callback(operation_id, attempt_ref), to: Reconciliation, as: :reconcile
  @doc false
  defdelegate state_digest(raw_state), to: Exchange
  @doc false
  defdelegate stage_callback(pair_id, authorization_ref, correlation_id, raw_state, envelope),
    to: Exchange

  @doc false
  defdelegate handoff_to_registered_credential(operation_id, attempt_ref), to: Exchange
  @doc false
  defdelegate handoff_reconciled_to_registered_credential(operation_id, attempt_ref), to: Exchange
  @doc false
  def prepare_handoff_finalization(authorization_ref),
    do: HandoffFinalizer.prepare(authorization_ref)

  @doc false
  def finalize_handoff(authorization_ref), do: HandoffFinalizer.finalize(authorization_ref)
end
