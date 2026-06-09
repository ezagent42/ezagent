defmodule EzagentPluginCodex.BridgeAdapterTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentBridge.Payload
  alias EzagentPluginCodex.BridgeAdapter

  test "deliver/2 converts generic payload to codex_turn channel frame" do
    payload = %Payload{
      message_id: "m1",
      session_uri: URI.new!("session://team-alpha/default/s1"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: "hello codex",
      event_type: :chat_send,
      meta: %{"sender" => "entity://system/user/admin"}
    }

    assert :ok = BridgeAdapter.deliver(payload, self())

    assert_receive {:agent_bridge_push, "codex_turn",
                    %{
                      "content" => "hello codex",
                      "event_type" => "chat_send",
                      "message_id" => "m1",
                      "meta" => %{"sender" => "entity://system/user/admin"},
                      "session_uri" => "session://team-alpha/default/s1",
                      "sender_uri" => "entity://system/user/admin"
                    }}
  end

  test "join_info/2 preserves codex-specific connect metadata" do
    assert BridgeAdapter.join_info(
             %{"codex_info" => %{"version" => "0.1.0"}, "tools" => ["reply"]},
             %Phoenix.Socket{}
           ) == %{
             codex_info: %{"version" => "0.1.0"},
             tools: ["reply"]
           }
  end

  test "handle_client_event/3 validates reply payload shape" do
    socket = %Phoenix.Socket{assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/codex_test")}}

    assert {:reply, {:error, %{reason: "reply requires text + session_uris"}}, ^socket} =
             BridgeAdapter.handle_client_event("reply", %{"text" => "missing sessions"}, socket)
  end
end

defmodule EzagentPluginCodex.BridgeSidecarTest do
  use ExUnit.Case, async: true

  alias EzagentPluginCodex.BridgeSidecar

  test "bridge_runner/1 honors explicit python_path before ambient uv" do
    assert {:ok, {"/custom/python3", []}} =
             BridgeSidecar.bridge_runner(%{python_path: "/custom/python3"})
  end

  test "bridge_runner/1 honors explicit uv_path with PEP 723 script args" do
    assert {:ok, {"/custom/uv", ["run", "--script"]}} =
             BridgeSidecar.bridge_runner(%{uv_path: "/custom/uv", python_path: "/custom/python3"})
  end
end
