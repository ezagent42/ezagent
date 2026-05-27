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

  test "handle_client_event/3 rejects empty session_uris with structured error (Invariant #9 r3 closure)" do
    # Codex r3 HIGH closure — an empty `session_uris` list previously
    # produced `{:ok, %{dispatched: []}}` with no Logger / telemetry,
    # silently ACKing a delivery to zero targets. The boundary now
    # rejects the case with a structured `:error` ACK + Logger
    # warning + telemetry.
    socket = %Phoenix.Socket{
      assigns: %{agent_uri: Ezagent.URI.parse!("entity://agent/team-alpha/cc_test")}
    }

    assert {:reply,
            {:error, %{reason: "session_uris must be a non-empty list"}},
            ^socket} =
             BridgeAdapter.handle_client_event(
               "reply",
               %{"text" => "hi", "session_uris" => []},
               socket
             )
  end

  test "dispatch_reply/5 returns dispatched + skipped breakdown for malformed session URIs (SPEC 2026-05-27 §3.3 + Invariant #9)" do
    # Codex r2 HIGH closure — malformed session URIs from the cc bridge
    # MUST NOT be silently dropped. dispatch_reply/5 returns the split
    # so the channel ACK can carry the `skipped` list back to claude
    # AND Logger/telemetry emit observable signals for operators.
    agent_uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_test")

    # No real Kind alive at the target session URIs — dispatch will
    # produce errors / :not_ready, but the SHAPE of dispatch_reply/5's
    # return is what we're locking here.
    sessions = [
      "session://default/system/main",
      "garbage://not-a-real-scheme",
      "",
      "session://default/team-alpha/real"
    ]

    assert {:ok, %{dispatched: dispatched, skipped: skipped}} =
             BridgeAdapter.dispatch_reply(agent_uri, sessions, "hi", nil, [])

    # Canonical Ezagent-scheme strings dispatched; malformed strings
    # got the skipped path with their original input preserved.
    assert "session://default/system/main" in dispatched
    assert "session://default/team-alpha/real" in dispatched
    assert "garbage://not-a-real-scheme" in skipped
    assert "" in skipped
    assert length(dispatched) + length(skipped) == length(sessions)
  end
end
