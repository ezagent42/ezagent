defmodule EzagentPluginForgejo.CredentialSourceTest do
  @moduledoc """
  Resolving a stored connection into a usable access token.

  This is the step a GitHub App does not need: it mints per operation. Forgejo's
  credential was issued once at authorization time, so the adapter must find
  the right connection first — keyed by the workspace, the credential owner
  (`OperationContext.credential_owner_uri`), the provider, and the instance
  host.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.Connection
  alias EzagentPluginForgejo.{CredentialSource, ForgejoCredentialBackend}
  alias EzagentCore.Repo

  @ws "workspace://acme"
  @owner "entity://acme/user/dev"
  @host "code.hyprial.test"
  @credential Jason.encode!(%{"access_token" => "at-live", "refresh_token" => "rt-live"})

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    assert is_pid(Process.whereis(ForgejoCredentialBackend))

    {:ok, %{credential_ref: ref}} =
      ForgejoCredentialBackend.store(%{credential_material: {:write_only_handoff, @credential}})

    {:ok, ref: ref}
  end

  defp connection!(ref, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          connection_id: Ecto.UUID.generate(),
          workspace_uri: @ws,
          owner_uri: @owner,
          provider_id: "forgejo",
          governed_host: @host,
          execution_identity: "connected_user",
          external_account_id: "7",
          acquisition_method: "oauth_user",
          status: "active",
          credential_backend_ref: ref,
          credential_version: 1,
          authorization_backend_ref: "auth-#{System.unique_integer([:positive])}",
          # provider_connections_backend_binding_check: pair / authorization /
          # credential backend ids are all-or-nothing.
          backend_pair_id: "pair-forgejo-v1",
          authorization_backend_id: "local-authorization-v1",
          credential_backend_id: "forgejo-credential-v1"
        },
        overrides
      )

    Repo.insert!(struct!(Connection, attrs))
  end

  describe "access_token/2" do
    test "resolves the stored connection and returns its access token", %{ref: ref} do
      connection!(ref)

      assert {:ok, "at-live"} = CredentialSource.access_token(@ws, @owner, @host)
    end

    # The refresh token is custody-only: it exists so renewal can happen, and
    # handing it to an HTTP call would be handing out a long-lived capability
    # where a short-lived one was asked for.
    test "returns the access token, never the refresh token", %{ref: ref} do
      connection!(ref)

      assert {:ok, token} = CredentialSource.access_token(@ws, @owner, @host)
      refute token == "rt-live"
    end

    test "an absent connection is a closed error" do
      assert {:error, :provider_account_not_connected} =
               CredentialSource.access_token(@ws, @owner, @host)
    end

    # Tenant isolation: the connection row is keyed on workspace, and a lookup
    # from another workspace must miss rather than borrow.
    test "another workspace cannot resolve this connection", %{ref: ref} do
      connection!(ref)

      assert {:error, :provider_account_not_connected} =
               CredentialSource.access_token("workspace://globex", @owner, @host)
    end

    test "another owner cannot resolve this connection", %{ref: ref} do
      connection!(ref)

      assert {:error, :provider_account_not_connected} =
               CredentialSource.access_token(@ws, "entity://acme/user/other", @host)
    end

    # Self-hosted: two instances are two providers. A connection to one must
    # not satisfy an operation against the other.
    test "another instance host cannot resolve this connection", %{ref: ref} do
      connection!(ref)

      assert {:error, :provider_account_not_connected} =
               CredentialSource.access_token(@ws, @owner, "git.elsewhere.test")
    end

    # A revoked or disconnected connection is terminal. Serving its credential
    # would keep a withdrawn authorization working.
    test "a revoked connection does not serve its credential", %{ref: ref} do
      connection!(ref, %{status: "revoked"})

      assert {:error, :provider_account_not_connected} =
               CredentialSource.access_token(@ws, @owner, @host)
    end

    # `refresh_required` still holds a usable credential -- the rotation is a
    # background concern, and refusing reads during it would make every
    # expiring connection briefly unusable.
    test "a connection awaiting refresh still serves its credential", %{ref: ref} do
      connection!(ref, %{status: "refresh_required"})

      assert {:ok, "at-live"} = CredentialSource.access_token(@ws, @owner, @host)
    end

    test "a connection whose credential is gone is a backend error, not a missing account", %{
      ref: ref
    } do
      connection!(ref)
      :ok = ForgejoCredentialBackend.revoke(%{credential_ref: ref, idempotency_key: "k"})

      assert {:error, :credential_backend_unavailable} =
               CredentialSource.access_token(@ws, @owner, @host)
    end

    # A credential that is not the JSON bundle this plugin stores means
    # something else wrote that row; using it as a bearer token would send an
    # unknown blob to the instance.
    test "a credential that is not this plugin's bundle is refused" do
      {:ok, %{credential_ref: bad_ref}} =
        ForgejoCredentialBackend.store(%{credential_material: {:write_only_handoff, "not-json"}})

      connection!(bad_ref)

      assert {:error, :credential_backend_unavailable} =
               CredentialSource.access_token(@ws, @owner, @host)
    end
  end
end
