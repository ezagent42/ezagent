defmodule EzagentPluginCc.AgentBridgeCompatTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias EzagentPluginCc.{BridgeRegistry, Channel, Socket, TokenStore}

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ezagent_plugin_cc
  end

  @endpoint TestEndpoint

  setup_all do
    Application.put_env(:ezagent_plugin_cc, TestEndpoint,
      secret_key_base: String.duplicate("a", 64),
      pubsub_server: EzagentCore.PubSub,
      server: false
    )

    start_supervised!(TestEndpoint)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    tmp = Path.join(System.tmp_dir!(), "ezagent-cc-agent-bridge-compat-#{u()}")
    profile = "test"
    File.mkdir_p!(Path.join([tmp, profile, "credentials"]))

    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", profile)

    BridgeRegistry.init()

    for {uri, _pid} <- BridgeRegistry.list_all() do
      BridgeRegistry.unbind(uri)
    end

    on_exit(fn ->
      for {uri, _pid} <- BridgeRegistry.list_all() do
        BridgeRegistry.unbind(uri)
      end

      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      _ = File.rm_rf(tmp)
    end)

    :ok
  end

  test "legacy cc modules still authenticate and join cc:bridge topics" do
    agent_uri = URI.new!("entity://team-alpha/agent/cc_compat-#{u()}")
    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")
    {:ok, token} = TokenStore.mint(agent_uri)

    assert {:ok, authed_socket} =
             Socket.connect(
               %{"agent_uri" => URI.to_string(agent_uri), "token" => token},
               %Phoenix.Socket{},
               %{}
             )

    assert authed_socket.assigns.agent_uri == agent_uri

    {:ok, _reply, joined_socket} =
      @endpoint
      |> socket("cc_socket:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "cc:bridge:#{URI.to_string(agent_uri)}", %{})

    assert {:ok, joined_socket.channel_pid} == BridgeRegistry.lookup(agent_uri)
  end

  test "deprecated token shim mint/1 result matches promoted token store mint/1" do
    agent_uri = URI.new!("entity://team-alpha/agent/cc_token-shim-#{u()}")

    promoted_result = Ezagent.AgentBridge.TokenStore.mint(agent_uri)
    shim_result = TokenStore.mint(agent_uri)

    assert shim_result == promoted_result
  end

  defp u, do: System.unique_integer([:positive])
end
