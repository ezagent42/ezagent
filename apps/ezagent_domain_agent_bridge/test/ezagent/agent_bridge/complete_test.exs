defmodule Ezagent.AgentBridge.CompleteTest do
  use ExUnit.Case, async: false

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload}

  defmodule SyncAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "completion-test"

    @impl true
    def transport_class, do: :in_process_sync

    @impl true
    def deliver(%Payload{text: text, message_id: id}, nil),
      do: {:ok, %{content: text <> ":" <> id}}
  end

  defmodule WsAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "completion-ws-test"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(%Payload{} = payload, channel_pid) when is_pid(channel_pid) do
      send(channel_pid, {:completion_ws_payload, payload})
      :ok
    end

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    Ezagent.UriQuery.init()
    Ezagent.AgentBridge.Registry.init()
    :ok = AdapterRegistry.register("completion-test", SyncAdapter)
    :ok = AdapterRegistry.register("completion-ws-test", WsAdapter)

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for {uri, _pid} <- Ezagent.AgentBridge.Registry.list_all(),
          do: Ezagent.AgentBridge.Registry.unbind(uri)
    end)

    :ok
  end

  test "complete/2 on an unresolvable agent returns {:error, _} (never raises, never leaks a key)" do
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")
    assert {:error, _} = Ezagent.AgentBridge.complete(ghost, "hello")
  end

  test "complete/2 exists with the documented arity/spec" do
    # function_exported? never loads — force-load so an umbrella-root run
    # (module not yet touched by another test) can't flake on order.
    assert Code.ensure_loaded!(Ezagent.AgentBridge)
    assert function_exported?(Ezagent.AgentBridge, :complete, 2)
  end

  test "Ezagent.Entity.Agent.complete/3 on a ghost agent returns {:error, :agent_owner_unresolvable}" do
    caller = Ezagent.Entity.User.admin_uri()
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")

    assert {:error, :agent_owner_unresolvable} =
             Ezagent.Entity.Agent.complete(caller, ghost, "hello")
  end

  test "complete/3 exists with the documented arity/spec" do
    assert Code.ensure_loaded!(Ezagent.Entity.Agent)
    assert function_exported?(Ezagent.Entity.Agent, :complete, 3)
  end

  test "request_completion resolves the durable flavor instead of forcing curl" do
    agent = Ezagent.URI.entity("team-alpha", :agent, "completion-test")
    session = Ezagent.URI.session("team-alpha", "default", "hello")
    put_flavor(agent, "completion-test")

    assert {:ok, "prompt:hello-completion-1"} =
             Ezagent.AgentBridge.request_completion(
               agent,
               session,
               "prompt",
               "hello-completion-1"
             )
  end

  test "request_completion returns pending for a WebSocket flavor" do
    agent = Ezagent.URI.entity("team-alpha", :agent, "completion-ws-test")
    session = Ezagent.URI.session("team-alpha", "default", "hello")
    put_flavor(agent, "completion-ws-test")
    :ok = Ezagent.AgentBridge.Registry.bind(agent, self())

    assert {:pending, "hello-completion-2"} =
             Ezagent.AgentBridge.request_completion(
               agent,
               session,
               "prompt",
               "hello-completion-2"
             )

    assert_receive {:completion_ws_payload,
                    %{
                      message_id: "hello-completion-2",
                      meta: %{"completion_request_id" => "hello-completion-2"} = meta
                    }},
                   500

    refute Map.has_key?(meta, "hello_completion_request_id")
  end

  defp put_flavor(uri, flavor) do
    :ets.insert(Ezagent.UriQuery.table(), {:flavor, fn ^uri -> {:ok, flavor} end})
  end
end
