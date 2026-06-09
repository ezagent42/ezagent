defmodule Ezagent.AgentBridge.TokenStoreTest do
  use ExUnit.Case, async: false

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

    assert {:ok, token} = TokenStore.mint(agent_uri)
    assert String.starts_with?(token, "tok_")

    path = Path.join([tmp, profile, "credentials", "cc-channels.yaml"])
    assert File.exists?(path)

    mode = Bitwise.band(File.stat!(path).mode, 0o777)
    assert mode == 0o600
  end

  test "mint/1 is idempotent and lookup_by_token/1 returns the agent URI" do
    agent_uri = URI.new!("entity://team-alpha/agent/test_token-idempotent")

    assert {:ok, token1} = TokenStore.mint(agent_uri)
    assert {:ok, token2} = TokenStore.mint(agent_uri)
    assert token1 == token2

    assert {:ok, found_uri} = TokenStore.lookup_by_token(token1)
    assert URI.to_string(found_uri) == URI.to_string(agent_uri)
  end

  test "list_all/0 returns URI keys and token metadata" do
    agent_uri = URI.new!("entity://team-alpha/agent/test_token-list")
    assert {:ok, token} = TokenStore.mint(agent_uri)

    assert [{found_uri, %{"token" => ^token, "minted_at" => minted_at}}] = TokenStore.list_all()
    assert URI.to_string(found_uri) == URI.to_string(agent_uri)
    assert is_binary(minted_at)
  end
end
