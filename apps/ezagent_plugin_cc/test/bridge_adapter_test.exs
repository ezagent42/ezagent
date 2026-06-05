defmodule EzagentPluginCc.BridgeAdapterTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentBridge.Payload
  alias EzagentPluginCc.BridgeAdapter

  test "deliver/2 converts generic payload to Claude channel frame" do
    payload = %Payload{
      message_id: "m1",
      session_uri: URI.new!("session://team-alpha/default/s1"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: "hello cc",
      event_type: :chat_send,
      meta: %{"sender" => "entity://system/user/admin"}
    }

    assert :ok = BridgeAdapter.deliver(payload, self())

    assert_receive {:agent_bridge_push, "to_claude",
                    %{
                      "content" => "hello cc",
                      "meta" => %{"sender" => "entity://system/user/admin"}
                    }}
  end

  test "handle_client_event/3 validates reply payload shape" do
    socket = %Phoenix.Socket{assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/cc_test")}}

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
      assigns: %{agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/cc_test")}
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

  test "dispatch_reply/5 returns dispatched + failed + skipped buckets (SPEC 2026-05-27 §3.3 + Invariant #9 r4 closure)" do
    # Codex r2/r3/r4 HIGH closure — boundary input MUST surface across
    # three distinct buckets so a canonical-but-stale URI does not
    # masquerade as successfully dispatched.
    #
    # - `dispatched`: Invocation.dispatch returned :ok / {:ok, _}.
    # - `failed`:     Invocation.dispatch returned {:error, reason}
    #                 (e.g. :no_such_actor for a stale-but-canonical URI).
    # - `skipped`:    safe_parse_session failed (malformed string).
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_test")

    # All test URIs are syntactically canonical but no Kinds are alive,
    # so dispatch will return {:error, :no_such_actor} for the
    # well-formed ones. The malformed ones go to skipped without
    # reaching dispatch.
    sessions = [
      "session://system/default/main",
      "garbage://not-a-real-scheme",
      "",
      "session://team-alpha/default/real"
    ]

    assert {:ok, %{dispatched: dispatched, failed: failed, skipped: skipped}} =
             BridgeAdapter.dispatch_reply(agent_uri, sessions, "hi", nil, [])

    # Malformed inputs land in skipped, with original string preserved.
    assert "garbage://not-a-real-scheme" in skipped
    assert "" in skipped

    # Canonical inputs reached dispatch. Since no Kind is alive at
    # either target, both should land in `failed` (the codex r4
    # finding — pre-fix they would have wrongly counted as dispatched).
    canonical_inputs = [
      "session://system/default/main",
      "session://team-alpha/default/real"
    ]

    canonical_outcomes = dispatched ++ Enum.map(failed, fn {s, _reason} -> s end)

    for input <- canonical_inputs do
      assert input in canonical_outcomes,
             "canonical input #{inspect(input)} must appear in dispatched or failed"
    end

    # Total accounting: every input lands in exactly one bucket.
    assert length(dispatched) + length(failed) + length(skipped) == length(sessions)
  end
end
