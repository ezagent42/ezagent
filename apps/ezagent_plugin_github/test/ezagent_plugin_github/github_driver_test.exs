defmodule EzagentPluginGithub.GitHubDriverTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubDriver
  alias EzagentPluginGithub.TestHelpers

  setup do
    TestHelpers.oauth_config()
    :ok
  end

  describe "begin_authorization/1" do
    test "returns a valid GitHub OAuth redirect URL via exchange function" do
      exchange = fn callback_fn ->
        callback_fn.(%{
          state: "test-state-123",
          pkce_verifier: "test-verifier-456"
        })
      end

      result =
        GitHubDriver.begin_authorization(%{
          authorization_ref: "auth-ref-1",
          correlation_id: "corr-1",
          callback_envelope_digest: "digest",
          exchange: exchange
        })

      assert {:ok, redirect_map} = result
      assert %{redirect: %{"authorization_uri" => uri}} = redirect_map

      # Verify the OAuth URL
      assert uri =~ "github.com/login/oauth/authorize"
      assert uri =~ "client_id=test-client-id"
      assert uri =~ "state=test-state-123"
      assert uri =~ "scope=repo"

      # Verify state passthrough
      assert redirect_map.redirect["state"] == "test-state-123"

      # pkce_digest must be URL-safe base64-encoded SHA256 of the verifier
      expected_pkce =
        :crypto.hash(:sha256, "test-verifier-456") |> Base.url_encode64(padding: false)

      assert redirect_map.redirect["pkce_digest"] == expected_pkce
    end

    test "without exchange function returns error" do
      assert {:error, :provider_protocol_failed} =
               GitHubDriver.begin_authorization(%{})
    end
  end

  describe "consume_callback/1" do
    test "formats credential material result via exchange boundary" do
      # The exchange simulates the framework providing a private_frame.
      # The test validates the shape of the result against all 10 keys that
      # validate_consume_result/5 requires. The exchange returns a fixture
      # result directly — it does NOT call the inner callback (the real
      # GitHubOAuth HTTP call is tested separately in GitHubOAuthTest).
      exchange = fn _callback_fn ->
        {:ok,
         %{
           provider_result_ref: "gh-result-test-fixture",
           external_account_id: "github-user-42",
           display_login: "test-user",
           execution_identity: %{kind: :connected_user, external_account_id: "github-user-42"},
           authorization_ref: "auth-ref-1",
           authorization_version: 1,
           credential_material: {:write_only_handoff, "github-token:gho_test_token_123"},
           granted_permissions_digest: "repo",
           expires_at: nil,
           provider_metadata: %{}
         }}
      end

      result =
        GitHubDriver.consume_callback(%{
          authorization_ref: "auth-ref-1",
          correlation_id: "corr-1",
          callback_envelope_digest: "digest",
          exchange: exchange
        })

      assert {:ok, resp} = result

      # Validate all 10 keys that validate_consume_result/5 checks
      assert resp.provider_result_ref == "gh-result-test-fixture"
      assert resp.external_account_id == "github-user-42"
      assert resp.display_login == "test-user"

      assert %{kind: :connected_user, external_account_id: "github-user-42"} =
               resp.execution_identity

      assert resp.authorization_ref == "auth-ref-1"
      assert resp.authorization_version == 1
      assert {:write_only_handoff, "github-token:gho_test_token_123"} = resp.credential_material
      assert resp.granted_permissions_digest == "repo"
      assert resp.expires_at == nil
      assert resp.provider_metadata == %{}
    end

    test "without exchange function returns error" do
      assert {:error, :provider_protocol_failed} =
               GitHubDriver.consume_callback(%{})
    end
  end

  describe "stub callbacks" do
    test "reconcile_callback returns not_completed" do
      assert {:ok, :not_completed} = GitHubDriver.reconcile_callback(%{})
    end

    test "refresh without refresh_use returns error" do
      assert {:error, :provider_protocol_failed} = GitHubDriver.refresh(%{})
    end

    test "reconcile_refresh returns not_completed" do
      assert {:ok, :not_completed} = GitHubDriver.reconcile_refresh(%{})
    end

    test "discard_callback_result returns ok" do
      assert :ok = GitHubDriver.discard_callback_result(%{})
    end

    test "discard_refresh_result returns ok" do
      assert :ok = GitHubDriver.discard_refresh_result(%{})
    end

    test "revoke returns revoked true" do
      assert {:ok, %{revoked: true}} = GitHubDriver.revoke(%{})
    end
  end
end
