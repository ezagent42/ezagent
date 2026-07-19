defmodule Ezagent.ProviderConnection.Test.FakeAuthorizationAlpha do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.ProviderAuthorizationBackend

  @impl true
  def begin_authorization(command), do: {:ok, command}
  @impl true
  def consume_callback(command), do: {:ok, command}
  @impl true
  def reauthenticate(command), do: {:ok, command}
  @impl true
  def cancel_authorization(command), do: {:ok, command}
end

defmodule Ezagent.ProviderConnection.Test.FakeAuthorizationBeta do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.ProviderAuthorizationBackend

  @impl true
  def begin_authorization(command), do: {:ok, command}
  @impl true
  def consume_callback(command), do: {:ok, command}
  @impl true
  def reauthenticate(command), do: {:ok, command}
  @impl true
  def cancel_authorization(command), do: {:ok, command}
end

defmodule Ezagent.ProviderConnection.Test.FakeCredentialAlpha do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @impl true
  def store(command), do: {:ok, command}
  @impl true
  def replace(command), do: {:ok, command}
  @impl true
  def status(command), do: {:ok, command}
  @impl true
  def lease_for_operation(command), do: {:ok, command}
  @impl true
  def consume_lease(command), do: {:ok, command}
  @impl true
  def revoke(command), do: {:ok, command}
end

defmodule Ezagent.ProviderConnection.Test.FakeCredentialBeta do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @impl true
  def store(command), do: {:ok, command}
  @impl true
  def replace(command), do: {:ok, command}
  @impl true
  def status(command), do: {:ok, command}
  @impl true
  def lease_for_operation(command), do: {:ok, command}
  @impl true
  def consume_lease(command), do: {:ok, command}
  @impl true
  def revoke(command), do: {:ok, command}
end

defmodule Ezagent.ProviderConnection.Test.FakeBackendPairs do
  @moduledoc false

  alias Ezagent.ProviderConnection.BackendPair

  def alpha do
    BackendPair.new!(%{
      pair_id: "pair-alpha-v1",
      authorization_backend: %{
        id: "authorization-alpha-v1",
        fingerprint: "authorization-alpha-contract-v1"
      },
      credential_backend: %{
        id: "credential-alpha-v1",
        fingerprint: "credential-alpha-contract-v1"
      }
    })
  end

  def beta do
    BackendPair.new!(%{
      pair_id: "pair-beta-v1",
      authorization_backend: %{
        id: "authorization-beta-v1",
        fingerprint: "authorization-beta-contract-v1"
      },
      credential_backend: %{
        id: "credential-beta-v1",
        fingerprint: "credential-beta-contract-v1"
      }
    })
  end
end
