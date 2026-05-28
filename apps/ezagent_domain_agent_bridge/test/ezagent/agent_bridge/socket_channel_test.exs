defmodule Ezagent.AgentBridge.SocketChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Ezagent.AgentBridge.{Channel, Registry, Socket, TokenStore}

  defmodule TestAdapter do
    @moduledoc false
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "testchan"

    @impl true
    def agent_uri_prefix, do: "testchan_"

    @impl true
    def deliver(_payload, _channel_pid), do: :ok

    @impl true
    def handle_client_event(event, params, socket) do
      {:reply, {:ok, %{"event" => event, "params" => params}}, socket}
    end
  end

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ezagent_domain_agent_bridge
  end

  @endpoint TestEndpoint

  setup_all do
    Application.put_env(:ezagent_domain_agent_bridge, TestEndpoint,
      secret_key_base: String.duplicate("a", 64),
      pubsub_server: EzagentCore.PubSub,
      server: false
    )

    start_supervised!(TestEndpoint)
    :ok
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ezagent-agent-bridge-socket-channel-#{System.unique_integer([:positive])}"
      )

    profile = "test"
    File.mkdir_p!(Path.join([tmp, profile, "credentials"]))

    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", profile)

    Registry.init()

    for {uri, _pid} <- Registry.list_all() do
      Registry.unbind(uri)
    end

    on_exit(fn ->
      for {uri, _pid} <- Registry.list_all() do
        Registry.unbind(uri)
      end

      if prev_home, do: System.put_env("EZAGENT_HOME", prev_home), else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      _ = File.rm_rf(tmp)
    end)

    :ok
  end

  test "Socket.connect/3 authenticates agent_uri against token" do
    agent_uri = uri!("entity://agent/team-alpha/cc_socket-auth-#{u()}")
    {:ok, token} = TokenStore.mint(agent_uri)

    assert {:ok, socket} =
             Socket.connect(
               %{"agent_uri" => URI.to_string(agent_uri), "token" => token},
               %Phoenix.Socket{},
               %{}
             )

    assert socket.assigns.agent_uri == agent_uri
    assert Socket.id(socket) == "agent_bridge:" <> URI.to_string(agent_uri)

    other_uri = uri!("entity://agent/team-alpha/cc_socket-other-#{u()}")

    assert :error =
             Socket.connect(
               %{"agent_uri" => URI.to_string(other_uri), "token" => token},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "canonical agent_bridge:cc topic joins and forwards BEAM pushes" do
    agent_uri = uri!("entity://agent/team-alpha/cc_new-topic-#{u()}")

    {:ok, _reply, socket} =
      @endpoint
      |> socket("agent_bridge:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(agent_uri)}", %{
        "claude_info" => %{"version" => "test"},
        "tools" => ["reply"]
      })

    assert {:ok, channel_pid} = Registry.lookup(agent_uri)
    assert channel_pid == socket.channel_pid

    payload = %{"content" => "hello", "meta" => %{}}
    send(socket.channel_pid, {:agent_bridge_push, "to_claude", payload})
    assert_push "to_claude", ^payload
  end

  test "legacy cc:bridge topic still joins during the deprecation window" do
    agent_uri = uri!("entity://agent/team-alpha/cc_legacy-topic-#{u()}")

    {:ok, _reply, socket} =
      @endpoint
      |> socket("cc_socket:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "cc:bridge:#{URI.to_string(agent_uri)}", %{})

    assert {:ok, socket.channel_pid} == Registry.lookup(agent_uri)
  end

  test "client events delegate to the registered flavor adapter" do
    agent_uri = uri!("entity://agent/team-alpha/testchan_bridge-#{u()}")
    :ok = Ezagent.AgentBridge.AdapterRegistry.register("testchan", TestAdapter)

    {:ok, _reply, socket} =
      @endpoint
      |> socket("agent_bridge:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "agent_bridge:testchan:#{URI.to_string(agent_uri)}", %{})

    ref = push(socket, "custom_event", %{"value" => "ok"})

    assert_reply ref, :ok, %{
      "event" => "custom_event",
      "params" => %{"value" => "ok"}
    }
  end

  test "join rejects a topic URI different from the token-authenticated socket URI" do
    authed_uri = uri!("entity://agent/team-alpha/cc_authed-#{u()}")
    topic_uri = uri!("entity://agent/team-alpha/cc_spoofed-#{u()}")

    assert {:error, %{reason: reason}} =
             @endpoint
             |> socket("agent_bridge:#{URI.to_string(authed_uri)}", %{agent_uri: authed_uri})
             |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(topic_uri)}", %{})

    assert reason == "topic_uri_mismatch"
    assert :error = Registry.lookup(authed_uri)
  end

  test "join rejects a topic flavor different from the URI flavor" do
    codex_uri = uri!("entity://agent/team-alpha/codex_wrong-topic-#{u()}")

    assert {:error, %{reason: reason}} =
             @endpoint
             |> socket("agent_bridge:#{URI.to_string(codex_uri)}", %{agent_uri: codex_uri})
             |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(codex_uri)}", %{})

    assert reason =~ "topic_flavor_mismatch"
    assert :error = Registry.lookup(codex_uri)
  end

  defp uri!(value), do: URI.new!(value)
  defp u, do: System.unique_integer([:positive])
end
