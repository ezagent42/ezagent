defmodule EzagentPluginCc.BridgeAdapterTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentBridge.Payload
  alias EzagentPluginCc.BridgeAdapter

  test "deliver/2 converts generic payload to Claude channel frame" do
    payload = %Payload{
      message_id: "m1",
      session_uri: URI.new!("session://default/team-alpha/s1"),
      sender_uri: URI.new!("entity://user/system/admin"),
      text: "hello cc",
      event_type: :chat_send,
      meta: %{"sender" => "entity://user/system/admin"}
    }

    assert :ok = BridgeAdapter.deliver(payload, self())

    assert_receive {:agent_bridge_push, "to_claude",
                    %{
                      "content" => "hello cc",
                      "meta" => %{"sender" => "entity://user/system/admin"}
                    }}
  end

  test "handle_client_event/3 validates reply payload shape" do
    socket = %Phoenix.Socket{assigns: %{agent_uri: URI.new!("entity://agent/team-alpha/cc_test")}}

    assert {:reply, {:error, %{reason: "reply requires text + session_uris"}}, ^socket} =
             BridgeAdapter.handle_client_event("reply", %{"text" => "missing sessions"}, socket)
  end
end
