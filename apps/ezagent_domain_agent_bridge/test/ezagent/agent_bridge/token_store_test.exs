defmodule Ezagent.AgentBridge.TokenStoreTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentBridge.TokenStore

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ezagent-agent-bridge-token-store-#{System.unique_integer([:positive])}"
      )

    profile = "test"
    File.mkdir_p!(Path.join([tmp, profile, "credentials"]))

    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", profile)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      _ = File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, profile: profile}
  end

  test "mint/1 persists token in the historical cc-channels.yaml path", %{
    tmp: tmp,
    profile: profile
  } do
    agent_uri = URI.new!("entity://team-alpha/agent/test_token-store")
    open_authority!(agent_uri)

    assert {:ok, token} = TokenStore.mint(agent_uri)
    assert String.starts_with?(token, "tok_")

    path = Path.join([tmp, profile, "credentials", "cc-channels.yaml"])
    assert File.exists?(path)

    mode = Bitwise.band(File.stat!(path).mode, 0o777)
    assert mode == 0o600
  end

  test "mint/1 is idempotent and lookup_by_token/1 returns the agent URI" do
    agent_uri = URI.new!("entity://team-alpha/agent/test_token-idempotent")
    open_authority!(agent_uri)

    assert {:ok, token1} = TokenStore.mint(agent_uri)
    assert {:ok, token2} = TokenStore.mint(agent_uri)
    assert token1 == token2

    assert {:ok, found_uri} = TokenStore.lookup_by_token(token1)
    assert URI.to_string(found_uri) == URI.to_string(agent_uri)
  end

  test "list_all/0 returns URI keys and token metadata" do
    agent_uri = URI.new!("entity://team-alpha/agent/test_token-list")
    open_authority!(agent_uri)
    assert {:ok, token} = TokenStore.mint(agent_uri)

    assert [
             {found_uri,
              %{"token" => ^token, "minted_at" => minted_at, "bound_generation" => 1}}
           ] = TokenStore.list_all()
    assert URI.to_string(found_uri) == URI.to_string(agent_uri)
    assert is_binary(minted_at)
  end

  describe "verify_token/2 — the SessionManager authz gate (no secret exposure)" do
    test "true only for the exact minted token; false otherwise (fail-closed)" do
      agent_uri = URI.new!("entity://team-alpha/agent/test_token-verify")
      open_authority!(agent_uri)
      assert {:ok, token} = TokenStore.mint(agent_uri)

      assert TokenStore.verify_token(agent_uri, token)
      refute TokenStore.verify_token(agent_uri, token <> "x")
      refute TokenStore.verify_token(agent_uri, "tok_wrong")
      refute TokenStore.verify_token(agent_uri, "")
      refute TokenStore.verify_token(agent_uri, nil)

      # An orchestrator with NO minted token never verifies.
      refute TokenStore.verify_token(URI.new!("entity://team-alpha/agent/test_token-none"), "x")
    end

    test "the module exposes NO getter that returns the secret (codex C-r6-P1)" do
      # Decision C §2 step 0 — the unforgeable-token threat model requires the
      # secret stay inside TokenStore. Any function returning the raw token would
      # let co-resident code forge a SessionManager call. Assert no such getter.
      refute function_exported?(TokenStore, :token_for, 1),
             "TokenStore must NOT expose the secret token via a getter — verify in-module."
    end
  end

  test "unified resolver authenticates only the connection-bound bridge principal" do
    principal = URI.new!("entity://team-alpha/agent/test_unified_bridge")
    other = URI.new!("entity://team-alpha/agent/test_unified_bridge_other")
    open_authority!(principal)
    assert {:ok, token} = TokenStore.mint(principal)

    assert {:ok, ^principal} =
             Ezagent.Authentication.authenticate(%Ezagent.Authentication.BridgeCredential{
               token: token,
               principal: principal
             })

    assert {:error, :invalid_credentials} =
             Ezagent.Authentication.authenticate(%Ezagent.Authentication.BridgeCredential{
               token: token,
               principal: other
             })
  end

  test "G-2 rejects a stale-generation bearer and does not auto-remint it" do
    principal =
      URI.new!(
        "entity://team-alpha/agent/test_bridge_generation-#{System.unique_integer([:positive])}"
      )

    assert {:ok, first} = Ezagent.Cap.Authority.open(principal, :agent)
    assert {:ok, token} = TokenStore.mint(principal)
    assert TokenStore.verify_token(principal, token)

    assert [{^principal, %{"bound_generation" => generation}}] = TokenStore.list_all()
    assert generation == first.generation

    assert {:ok, bumped} = Ezagent.Cap.Authority.regenesis(principal, :agent)
    assert bumped.generation == first.generation + 1

    refute TokenStore.verify_token(principal, token)
    assert :error = TokenStore.lookup_by_token(token)
    assert {:error, :principal_revoked} = TokenStore.mint(principal)
  end

  defp open_authority!(agent_uri) do
    assert {:ok, _authority} = Ezagent.Cap.Authority.open(agent_uri, :agent)
    agent_uri
  end
end
