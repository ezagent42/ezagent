defmodule EzagentPluginGithub.GitHubCredentialBackendTest do
  use ExUnit.Case, async: false

  alias EzagentPluginGithub.{GitHubCredentialBackend, GitHubTokenStore}

  @backend GitHubCredentialBackend

  setup do
    # Ensure the ETS table exists and is clean for each test.
    # The table is created once by start_link but may not be started in test.
    ensure_table()
    :ets.delete_all_objects(:github_credential_tokens)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(:github_credential_tokens) do
      :undefined ->
        :ets.new(:github_credential_tokens, [:set, :public, :named_table])

      _tid ->
        :ok
    end
  end

  describe "TokenStore encrypt/decrypt" do
    test "encrypt/decrypt round trip" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "gho_sample_token_value"

      {nonce, ciphertext_with_tag} = GitHubTokenStore.encrypt(plaintext, key)
      assert byte_size(nonce) == 12
      assert byte_size(ciphertext_with_tag) > byte_size(plaintext)

      assert {:ok, decrypted} = GitHubTokenStore.decrypt({nonce, ciphertext_with_tag}, key)
      assert decrypted == plaintext
    end

    test "wrong key fails decrypt" do
      key = :crypto.strong_rand_bytes(32)
      wrong_key = :crypto.strong_rand_bytes(32)
      plaintext = "gho_secret_token"

      encrypted = GitHubTokenStore.encrypt(plaintext, key)
      assert {:error, :authentication_failed} = GitHubTokenStore.decrypt(encrypted, wrong_key)
    end
  end

  describe "store" do
    test "persists a token and returns a credential_ref" do
      assert {:ok, %{credential_ref: ref, credential_version: version}} =
               @backend.store(%{
                 credential_material: {:write_only_handoff, "gho-sample-token"},
                 backend_pair_id: "pair-github-v1",
                 correlation_id: "store-1"
               })

      assert is_binary(ref)
      assert version == 1
    end
  end

  describe "store + status round trip" do
    test "status returns stored credential info" do
      {:ok, %{credential_ref: ref}} =
        @backend.store(%{
          credential_material: {:write_only_handoff, "gho-status-test"},
          backend_pair_id: "pair-github-v1",
          correlation_id: "store-2"
        })

      assert {:ok, %{credential_ref: ^ref, credential_version: 1}} =
               @backend.status(%{credential_ref: ref})
    end
  end

  describe "replace" do
    test "bumps credential version on replace" do
      {:ok, %{credential_ref: ref}} =
        @backend.store(%{
          credential_material: {:write_only_handoff, "token-v1"},
          backend_pair_id: "pair-github-v1",
          correlation_id: "store-replace"
        })

      assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
               @backend.replace(%{
                 credential_ref: ref,
                 credential_material: {:write_only_handoff, "token-v2"},
                 backend_pair_id: "pair-github-v1",
                 correlation_id: "replace-1",
                 expected_credential_version: 1
               })
    end

    test "rejects stale version" do
      {:ok, %{credential_ref: ref}} =
        @backend.store(%{
          credential_material: {:write_only_handoff, "token-v1"},
          backend_pair_id: "pair-github-v1",
          correlation_id: "store-stale"
        })

      # Replace first time: v1 -> v2
      {:ok, %{credential_version: 2}} =
        @backend.replace(%{
          credential_ref: ref,
          credential_material: {:write_only_handoff, "token-v2"},
          backend_pair_id: "pair-github-v1",
          correlation_id: "replace-stale-1",
          expected_credential_version: 1
        })

      # Second replace with stale version (expected 1, but current is 2)
      assert {:error, :stale_version} =
               @backend.replace(%{
                 credential_ref: ref,
                 credential_material: {:write_only_handoff, "token-v3"},
                 backend_pair_id: "pair-github-v1",
                 correlation_id: "replace-stale-2",
                 expected_credential_version: 1
               })
    end
  end

  describe "revoke" do
    test "makes subsequent status return error" do
      {:ok, %{credential_ref: ref}} =
        @backend.store(%{
          credential_material: {:write_only_handoff, "token-to-revoke"},
          backend_pair_id: "pair-github-v1",
          correlation_id: "store-revoke"
        })

      assert :ok = @backend.revoke(%{credential_ref: ref, idempotency_key: "rev-1"})
      assert {:error, :credential_conflict} = @backend.status(%{credential_ref: ref})
    end
  end

  describe "lease_for_operation" do
    test "returns decrypted token and stashes it in process dictionary" do
      token_value = "gho_live_token_abc123"

      {:ok, %{credential_ref: ref}} =
        @backend.store(%{
          credential_material: {:write_only_handoff, token_value},
          backend_pair_id: "pair-github-v1",
          correlation_id: "store-lease"
        })

      assert {:ok, %{credential: ^token_value, credential_ref: ^ref, expires_at: nil}} =
               @backend.lease_for_operation(%{credential_ref: ref})

      # Verify the token was stashed in the process dictionary
      assert GitHubCredentialBackend.current_token() == token_value
    end

    test "returns credential_conflict for unknown ref" do
      assert {:error, :credential_conflict} =
               @backend.lease_for_operation(%{credential_ref: "nonexistent-ref"})
    end
  end

  describe "consume_lease" do
    test "returns :ok" do
      assert :ok = @backend.consume_lease(%{})
    end
  end

  describe "begin_refresh_exchange" do
    test "returns backend_unavailable" do
      assert {:error, :backend_unavailable} = @backend.begin_refresh_exchange(%{})
    end
  end

  describe "consume_refresh_exchange" do
    test "returns backend_unavailable" do
      assert {:error, :backend_unavailable} = @backend.consume_refresh_exchange(%{})
    end
  end
end
