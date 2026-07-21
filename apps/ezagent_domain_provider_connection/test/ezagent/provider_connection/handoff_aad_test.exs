defmodule Ezagent.ProviderConnection.HandoffAadTest do
  use ExUnit.Case, async: true

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  defp row do
    %{
      authorization_ref: "auth-1",
      bound_input_digest: "digest-1",
      begin_correlation_id: "begin-1",
      owner_uri: "entity://acme/user/alice",
      workspace_uri: "workspace://acme",
      connection_id: Ecto.UUID.generate(),
      connection_version: 3,
      backend_pair_id: "pair-1",
      provider_id: "provider-1",
      governed_host: "git.example",
      acquisition_method: "oauth_user",
      execution_identity: "connected_user",
      requested_permissions_digest: "perm-1",
      redirect_uri_id: "callback-1"
    }
  end

  test "the AAD names the real credential-command correlation for initial bind" do
    aad = Support.handoff_aad(row(), "corr-1", "handoff-1", "store")

    assert aad.correlation_id == "corr-1"
    assert aad.credential_correlation_id == "store:corr-1"
    assert aad.handoff_ref == "handoff-1"
  end

  test "the AAD names the real credential-command correlation for reauthorization" do
    aad = Support.handoff_aad(row(), "corr-1", "handoff-1", "replace")

    assert aad.credential_correlation_id == "replace:corr-1"
  end

  test "non-callback classes are not a valid handoff AAD class" do
    assert_raise FunctionClauseError, fn ->
      Support.handoff_aad(row(), "corr-1", "handoff-1", "refresh")
    end
  end
end
