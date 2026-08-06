defmodule EzagentPluginCurlAgent.BridgeAdapterTest do
  @moduledoc """
  PR-6 (im/session/agent decomposition, codex HIGH-1) — the curl flavor's
  `:in_process_sync` AgentBridge adapter is TRANSPORT-ONLY.

  These tests pin the adapter contract surface (`flavor/0`,
  `transport_class/0`) and its deadlock-safe request assembly. The HTTP
  boundary itself (`ApiClient` + `Req`) is NOT re-tested here (the
  ApiClient moduledoc + scenario 07 cover the wire shape); the adapter
  tests exercise the assembly + error-relay path that does NOT touch the
  network (missing api_key, missing agent_uri).
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginCurlAgent.BridgeAdapter
  alias Ezagent.AgentBridge.Payload
  alias Ezagent.{Kind, KindRegistry}

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp payload_for(agent_uri, text) do
    %Payload{
      message_id: "m-#{System.unique_integer([:positive])}",
      session_uri: Ezagent.URI.new!("session://team-alpha/default/main"),
      sender_uri: Ezagent.URI.new!("entity://team-alpha/user/alice"),
      text: text,
      event_type: :chat_send,
      attachments: [],
      meta: %{"agent_uri" => URI.to_string(agent_uri)}
    }
  end

  describe "adapter contract surface" do
    test "flavor/0 is \"curl\"" do
      assert BridgeAdapter.flavor() == "curl"
    end

    test "transport_class/0 is :in_process_sync" do
      assert BridgeAdapter.transport_class() == :in_process_sync
    end

    test "implements the Ezagent.AgentBridge.Adapter behaviour" do
      behaviours =
        BridgeAdapter.module_info(:attributes) |> Keyword.get(:behaviour, [])

      assert Ezagent.AgentBridge.Adapter in behaviours
    end

    test "does NOT implement the WS-only optional callbacks" do
      refute function_exported?(BridgeAdapter, :handle_client_event, 3)
      refute function_exported?(BridgeAdapter, :socket_path, 0)
      refute function_exported?(BridgeAdapter, :channel_topic_prefix, 0)
    end
  end

  describe "deliver/2 — error relay (no network)" do
    test "missing agent_uri in payload meta returns a structured error" do
      payload = %Payload{
        message_id: "m1",
        session_uri: Ezagent.URI.new!("session://team-alpha/default/main"),
        sender_uri: Ezagent.URI.new!("entity://team-alpha/user/alice"),
        text: "hi",
        event_type: :chat_send,
        attachments: [],
        meta: %{}
      }

      assert {:error, :no_agent_uri_in_payload} = BridgeAdapter.deliver(payload, nil)
    end

    test "no api key for the provider returns {:error, {:no_api_key, provider}} (no HTTP)" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_noadapterkey-#{System.unique_integer([:positive])}"
        )

      # PR-6+7 — spawn a real curl agent on the UNIFIED `Entity.Agent` Kind
      # with the curl per-instance behavior set so the :curl_agent + :api_keys
      # snapshot slices exist; NO key is seeded → the adapter must short-circuit
      # BEFORE any HTTP call and relay the no_api_key error.
      {:ok, _pid} =
        Kind.spawn(Ezagent.Entity.Agent, %{
          uri: uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek"
        })

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      assert {:error, {:no_api_key, "deepseek"}} =
               BridgeAdapter.deliver(payload_for(uri, "hello"), nil)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end
end
