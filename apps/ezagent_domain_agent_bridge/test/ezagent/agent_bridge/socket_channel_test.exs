defmodule Ezagent.AgentBridge.SocketChannelTest do
  use EzagentCore.DataCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.AgentBridge.{Channel, Registry, Socket, TokenStore}

  defmodule TestAdapter do
    @moduledoc false
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "testchan"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(_payload, _channel_pid), do: :ok

    @impl true
    def handle_client_event(event, params, socket) do
      {:reply, {:ok, %{"event" => event, "params" => params}}, socket}
    end
  end

  defmodule SyncAdapter do
    @moduledoc false
    # An :in_process_sync flavor has NO WebSocket; a Channel join must reject
    # it. Note: NO WS callbacks defined (handle_client_event/3 etc.).
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "syncchan"

    @impl true
    def transport_class, do: :in_process_sync

    @impl true
    def deliver(_payload, _channel_ref), do: {:ok, :noop}
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

    Ezagent.UriQuery.init()
    previous_flavor_query = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    on_exit(fn ->
      for {uri, _pid} <- Registry.list_all() do
        Registry.unbind(uri)
      end

      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for entry <- previous_flavor_query do
        :ets.insert(Ezagent.UriQuery.table(), entry)
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

  test "Socket.connect/3 authenticates agent_uri against token" do
    agent_uri = uri!("entity://team-alpha/agent/cc_socket-auth-#{u()}")
    {:ok, _authority} = Ezagent.Cap.Authority.open(agent_uri, :agent)
    {:ok, token} = TokenStore.mint(agent_uri)

    assert {:ok, socket} =
             Socket.connect(
               %{"agent_uri" => URI.to_string(agent_uri), "token" => token},
               %Phoenix.Socket{},
               %{}
             )

    assert socket.assigns.agent_uri == agent_uri
    assert Socket.id(socket) == "agent_bridge:" <> URI.to_string(agent_uri)

    other_uri = uri!("entity://team-alpha/agent/cc_socket-other-#{u()}")

    assert :error =
             Socket.connect(
               %{"agent_uri" => URI.to_string(other_uri), "token" => token},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "canonical agent_bridge:cc topic joins and forwards BEAM pushes" do
    agent_uri = uri!("entity://team-alpha/agent/cc_new-topic-#{u()}")
    put_flavor(agent_uri, "cc")

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
    assert_push("to_claude", ^payload)
  end

  test "canonical topic verifies flavor through UriQuery for prefixless agent URIs" do
    agent_uri = uri!("entity://team-alpha/agent/new-topic-#{u()}")
    put_flavor(agent_uri, "cc")

    {:ok, _reply, socket} =
      @endpoint
      |> socket("agent_bridge:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(agent_uri)}", %{})

    assert {:ok, socket.channel_pid} == Registry.lookup(agent_uri)
  end

  test "legacy cc:bridge topic still joins during the deprecation window" do
    agent_uri = uri!("entity://team-alpha/agent/cc_legacy-topic-#{u()}")
    put_flavor(agent_uri, "cc")

    {:ok, _reply, socket} =
      @endpoint
      |> socket("cc_socket:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "cc:bridge:#{URI.to_string(agent_uri)}", %{})

    assert {:ok, socket.channel_pid} == Registry.lookup(agent_uri)
  end

  test "client events delegate to the registered flavor adapter" do
    agent_uri = uri!("entity://team-alpha/agent/testchan_bridge-#{u()}")
    :ok = Ezagent.AgentBridge.AdapterRegistry.register("testchan", TestAdapter)
    put_flavor(agent_uri, "testchan")

    {:ok, _reply, socket} =
      @endpoint
      |> socket("agent_bridge:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
      |> subscribe_and_join(Channel, "agent_bridge:testchan:#{URI.to_string(agent_uri)}", %{})

    ref = push(socket, "custom_event", %{"value" => "ok"})

    assert_reply(ref, :ok, %{
      "event" => "custom_event",
      "params" => %{"value" => "ok"}
    })
  end

  test "join rejects a topic URI different from the token-authenticated socket URI" do
    authed_uri = uri!("entity://team-alpha/agent/cc_authed-#{u()}")
    topic_uri = uri!("entity://team-alpha/agent/cc_spoofed-#{u()}")

    assert {:error, %{reason: reason}} =
             @endpoint
             |> socket("agent_bridge:#{URI.to_string(authed_uri)}", %{agent_uri: authed_uri})
             |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(topic_uri)}", %{})

    assert reason == "topic_uri_mismatch"
    assert :error = Registry.lookup(authed_uri)
  end

  test "join rejects a topic flavor different from the stored agent flavor" do
    codex_uri = uri!("entity://team-alpha/agent/codex_wrong-topic-#{u()}")
    put_flavor(codex_uri, "codex")

    assert {:error, %{reason: reason}} =
             @endpoint
             |> socket("agent_bridge:#{URI.to_string(codex_uri)}", %{agent_uri: codex_uri})
             |> subscribe_and_join(Channel, "agent_bridge:cc:#{URI.to_string(codex_uri)}", %{})

    assert reason =~ "topic_flavor_mismatch"
    assert :error = Registry.lookup(codex_uri)
  end

  test "join REJECTS an :in_process_sync flavor — it has no WS endpoint (PR-0 MED-2)" do
    agent_uri = uri!("entity://team-alpha/agent/syncchan_reject-#{u()}")
    :ok = Ezagent.AgentBridge.AdapterRegistry.register("syncchan", SyncAdapter)
    put_flavor(agent_uri, "syncchan")

    assert {:error, %{reason: reason}} =
             @endpoint
             |> socket("agent_bridge:#{URI.to_string(agent_uri)}", %{agent_uri: agent_uri})
             |> subscribe_and_join(
               Channel,
               "agent_bridge:syncchan:#{URI.to_string(agent_uri)}",
               %{}
             )

    assert reason == "transport_class_mismatch"
    assert :error = Registry.lookup(agent_uri)
  end

  defp uri!(value), do: URI.new!(value)
  defp u, do: System.unique_integer([:positive])

  defp put_flavor(agent_uri, flavor) do
    :ets.insert(Ezagent.UriQuery.table(), {:flavor, fn ^agent_uri -> {:ok, flavor} end})
  end
end
