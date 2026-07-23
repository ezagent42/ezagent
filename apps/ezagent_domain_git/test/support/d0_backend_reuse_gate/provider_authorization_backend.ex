defmodule Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend do
  @moduledoc false

  alias Ezagent.DomainGit.D0BackendReuseGate.Types

  @callback begin_authorization(Types.authorization_request()) ::
              {:ok, Types.authorization_started()} | {:error, Types.authorization_error()}

  @callback consume_callback(Types.callback_request()) ::
              {:ok, Types.authorization_result()} | {:error, Types.authorization_error()}

  @callback reauthenticate(Types.reauthentication_request()) ::
              {:ok, Types.reauthentication_result()} | {:error, Types.authorization_error()}

  @callback cancel_authorization(Types.cancellation_request()) ::
              :ok | {:error, Types.authorization_error()}
end
