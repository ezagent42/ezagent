defmodule Ezagent.ProviderConnection.AuthorizationKeyRingTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias EzagentCore.Repo

  @key_a :binary.copy(<<17>>, 32)
  @key_b :binary.copy(<<34>>, 32)

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "rotation preflight rejects malformed and duplicate keys without exposing material" do
    encoded = Base.encode64(@key_a)

    for config <- [
          [source: :runtime_env, active_key_id: "missing", keys_json: "{}"],
          [source: :runtime_env, active_key_id: "bad id", keys_json: ~s({"bad id":"#{encoded}"})],
          [source: :runtime_env, active_key_id: "k1", keys_json: ~s({"k1":"AQ=="})],
          [
            source: :runtime_env,
            active_key_id: "k1",
            keys_json: ~s({"k1":"#{encoded}","k1":"#{encoded}"})
          ]
        ] do
      assert {:error, {:invalid_authorization_key_ring, reason}} =
               with_config(config, &AuthorizationKeyRing.validate_rotation_config/0)

      refute inspect(reason) =~ encoded
      refute inspect(reason) =~ Base.encode16(@key_a)
    end
  end

  test "production entry is singleton-only and accepts no caller-supplied bypass" do
    assert {:error, :singleton_only} =
             AuthorizationKeyRing.start_link(
               name: nil,
               config_env: :test,
               validate_references: false,
               keys: %{"attacker" => @key_a}
             )
  end

  test "old decrypt-only key removal fails while an unexpired record references it" do
    attrs = %{
      id: Ecto.UUID.generate(),
      workspace_uri: "workspace://acme/workspace/main",
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "auth-old-key",
      key_id: "old-v1",
      key_fingerprint: :crypto.hash(:sha256, @key_a),
      nonce: :binary.copy(<<1>>, 12),
      ciphertext: :binary.copy(<<2>>, 17),
      bound_input_digest: "digest",
      begin_correlation_id: "begin-1",
      owner_uri: "entity://acme/user/alice",
      connection_id: "conn-1",
      connection_version: 1,
      provider_id: "task6-provider",
      governed_host: "example.test",
      acquisition_method: "oauth_user",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      lifecycle_status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    assert {:ok, _record} = Repo.insert(AuthorizationBackendRecord.create_changeset(attrs))

    assert {:error, {:invalid_authorization_key_ring, {:referenced_key_missing, "old-v1"}}} =
             with_config(
               [source: :explicit_test, active_key_id: "test-v2", keys: %{"test-v2" => @key_b}],
               &AuthorizationKeyRing.validate_rotation_config/0
             )
  end

  test "rotation rejects replacing bytes beneath an unexpired key id" do
    attrs = %{
      id: Ecto.UUID.generate(),
      workspace_uri: "workspace://acme/workspace/main",
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "auth-changed-key",
      key_id: "test-v1",
      key_fingerprint: :crypto.hash(:sha256, @key_a),
      nonce: :binary.copy(<<1>>, 12),
      ciphertext: :binary.copy(<<2>>, 17),
      bound_input_digest: "digest",
      begin_correlation_id: "begin-changed-key",
      owner_uri: "entity://acme/user/alice",
      connection_id: "conn-1",
      connection_version: 1,
      provider_id: "task6-provider",
      governed_host: "example.test",
      acquisition_method: "oauth_user",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      lifecycle_status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    assert {:ok, _record} = Repo.insert(AuthorizationBackendRecord.create_changeset(attrs))

    assert {:error, {:invalid_authorization_key_ring, {:referenced_key_changed, "test-v1"}}} =
             with_config(
               [source: :explicit_test, active_key_id: "test-v1", keys: %{"test-v1" => @key_b}],
               &AuthorizationKeyRing.validate_rotation_config/0
             )
  end

  test "there is no raw key cache or purpose/plaintext oracle" do
    assert :missing ==
             :persistent_term.get({AuthorizationKeyRing, :validated_keys}, :missing)

    for {name, arity} <- [
          encrypt: 3,
          decrypt: 3,
          open: 4,
          prepare_begin: 2,
          resume_begin: 2,
          invoke_begin: 4,
          consume_and_seal: 6
        ] do
      refute function_exported?(AuthorizationKeyRing, name, arity)
    end

    refute function_exported?(AuthorizationKeyRing, :reload, 0)
  end

  defp with_config(config, fun) do
    key = AuthorizationKeyRing
    previous = Application.get_env(:ezagent_domain_provider_connection, key)
    Application.put_env(:ezagent_domain_provider_connection, key, config)

    try do
      fun.()
    after
      Application.put_env(:ezagent_domain_provider_connection, key, previous)
    end
  end
end
