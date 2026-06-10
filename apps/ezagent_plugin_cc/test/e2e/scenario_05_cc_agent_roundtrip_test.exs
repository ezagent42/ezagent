defmodule Ezagent.PluginCc.E2E.Scenario05CcAgentRoundtripTest do
  @moduledoc """
  Scenario 05 — cc agent: spawn → first-run → message → reply.

  Cross-reference: `docs/scenarios/05-cc-agent-roundtrip/scenario.md`.

  ## What this proves

  The cc agent message roundtrip works via the new contract WITHOUT
  invoking the real `claude` CLI / MCP bridge subprocess. We use the
  `EzagentPluginCc.BridgeAdapter` API directly + a mock channel pid
  to assert the production flow's effect shape end-to-end:

  1. AgentBridge deliver payload → adapter sends `to_claude` channel
     push (the production wiring the cc bridge consumes)
  2. Bridge `handle_client_event("reply", ...)` dispatches a fresh
     `chat.send` from the agent URI to the session URI
  3. The session fan-out broadcasts the reply on its PubSub topic

  The deterministic full-stack runbook lives at
  `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`
  — that test exercises a fake `claude` PTY + the real WS channel.
  Per `feedback_let_it_crash_no_workarounds`, this scenario file
  provides the FAST regression for the bridge adapter contract +
  the mocked-channel reply shape; the real-binary smoke is the
  manual operator runbook.

  ## ALLEN MANUAL action

  - Real-claude full smoke: `docs/runbook/cc-agent-e2e.md` Test B
  - LiveView screenshot: per `feedback_esr_e2e_standards`, ANY UI
    sign-off requires an agent-browser screenshot of
    `/admin/sessions/<uri>` showing admin + agent messages. The
    fast tests below do not constitute a sign-off without that.
  """

  use ExUnit.Case, async: false

  @moduletag scenario: "05-cc-agent-roundtrip"
  @moduletag :e2e

  alias Ezagent.AgentBridge.Payload
  alias EzagentPluginCc.BridgeAdapter

  # ---------------------------------------------------------------
  # 1. AgentBridge → cc adapter → "to_claude" channel push
  # ---------------------------------------------------------------

  describe "BridgeAdapter.deliver/2 — outbound to claude bridge" do
    test "converts an inbound chat payload into a `to_claude` channel frame" do
      payload = %Payload{
        message_id: "m-#{System.unique_integer([:positive])}",
        session_uri: URI.new!("session://team-alpha/default/scenario05"),
        sender_uri: URI.new!("entity://system/user/admin"),
        text: "say hello",
        event_type: :chat_send,
        meta: %{"sender" => "entity://system/user/admin"}
      }

      assert :ok = BridgeAdapter.deliver(payload, self())

      assert_receive {:agent_bridge_push, "to_claude", frame}, 500

      assert frame == %{
               "content" => "say hello",
               "meta" => %{"sender" => "entity://system/user/admin"}
             }
    end

    test "deliver/2 omits session/sender from the to_claude frame (cc bridge protocol)" do
      # The cc bridge only consumes `content` + `meta`; session URI /
      # sender URI / message id are NOT in the frame. This is the
      # cc-specific shape that differs from codex (which includes
      # `session_uri` / `sender_uri` / `message_id` per
      # EzagentPluginCodex.BridgeAdapter.deliver/2).
      payload = %Payload{
        message_id: "m-shouldnt-leak",
        session_uri: URI.new!("session://team-alpha/default/x"),
        sender_uri: URI.new!("entity://system/user/admin"),
        text: "ping",
        event_type: :chat_send
      }

      assert :ok = BridgeAdapter.deliver(payload, self())
      assert_receive {:agent_bridge_push, "to_claude", frame}, 500
      refute Map.has_key?(frame, "session_uri")
      refute Map.has_key?(frame, "sender_uri")
      refute Map.has_key?(frame, "message_id")
    end
  end

  # ---------------------------------------------------------------
  # 2. claude → BridgeAdapter.handle_client_event("reply", ...)
  # ---------------------------------------------------------------

  describe "BridgeAdapter.handle_client_event/3 — inbound reply" do
    test "rejects a reply without `text`" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/cc_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{"session_uris" => ["session://team-alpha/default/x"]},
                 socket
               )

      assert msg =~ "text + session_uris"
    end

    test "rejects a reply without `session_uris`" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/cc_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{"text" => "missing sessions"},
                 socket
               )

      assert msg =~ "text + session_uris"
    end

    test "rejects empty `session_uris` (Invariant #9 closure r3)" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/cc_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{"text" => "x", "session_uris" => []},
                 socket
               )

      assert msg =~ "non-empty"
    end

    test "rejects malformed attachments (must be a list)" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://team-alpha/agent/cc_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{
                   "text" => "x",
                   "session_uris" => ["session://team-alpha/default/x"],
                   "attachments" => "not-a-list"
                 },
                 socket
               )

      assert msg =~ "list"
    end
  end

  # ---------------------------------------------------------------
  # 3. dispatch_reply/5 — the agent-side chat.send fan-out
  # ---------------------------------------------------------------

  describe "BridgeAdapter.dispatch_reply/5 — three-bucket classifier" do
    test "skipped: malformed session URI is classified, NOT dispatched" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_alpha")

      assert {:ok, %{dispatched: dispatched, failed: _failed, skipped: skipped}} =
               BridgeAdapter.dispatch_reply(
                 agent_uri,
                 ["not a uri at all"],
                 "hello",
                 nil,
                 []
               )

      assert dispatched == []
      assert skipped == ["not a uri at all"]
    end

    test "failed: a session URI with no live Kind yields `{uri, :no_such_actor}`" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_alpha")

      stale_session =
        "session://team-alpha/default/never_spawned_#{System.unique_integer([:positive])}"

      assert {:ok, %{dispatched: dispatched, failed: failed, skipped: skipped}} =
               BridgeAdapter.dispatch_reply(
                 agent_uri,
                 [stale_session],
                 "hi",
                 nil,
                 []
               )

      assert dispatched == []
      assert skipped == []
      # Invariant #9: failed bucket carries {uri, reason} pairs.
      assert [{^stale_session, _reason}] = failed
    end
  end

  # ---------------------------------------------------------------
  # 4. join_info passes through claude-specific connect metadata
  # ---------------------------------------------------------------

  describe "BridgeAdapter.join_info/2" do
    test "preserves the claude_info + tools fields from a join params map" do
      assert BridgeAdapter.join_info(
               %{"claude_info" => %{"version" => "1.2.3"}, "tools" => ["reply"]},
               %Phoenix.Socket{}
             ) == %{
               claude_info: %{"version" => "1.2.3"},
               tools: ["reply"]
             }
    end

    test "defaults to empty claude_info + empty tools list when keys absent" do
      assert BridgeAdapter.join_info(%{}, %Phoenix.Socket{}) == %{
               claude_info: %{},
               tools: []
             }
    end
  end

  # ---------------------------------------------------------------
  # 5. Adapter-contract surface
  # ---------------------------------------------------------------

  describe "AgentBridge.Adapter contract" do
    test "flavor is \"cc\"" do
      assert BridgeAdapter.flavor() == "cc"
    end

    test "agent_uri_prefix callback is removed; flavor is stored, not URI-derived" do
      refute function_exported?(BridgeAdapter, :agent_uri_prefix, 0)
    end

    test "channel_topic_prefix routes to the shared agent_bridge socket" do
      assert BridgeAdapter.channel_topic_prefix() == "agent_bridge:cc:"
    end

    test "socket_path is the unified agent_bridge mount" do
      assert BridgeAdapter.socket_path() == "/agent_bridge"
    end
  end

  # ---------------------------------------------------------------
  # 6. ALLEN MANUAL — real-claude full smoke (skeleton)
  # ---------------------------------------------------------------

  describe "real-claude full roundtrip (ALLEN MANUAL)" do
    @tag :requires_allen
    @tag :skip
    test "real cc agent → admin chat.send → claude reply → session events broadcast" do
      # This is the full-binary smoke covered by
      # `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`
      # (uses `fake_claude.py` to stand in for the real `claude` binary).
      # For a REAL `claude` smoke (per `feedback_esr_e2e_standards`):
      #
      # 1. Allen runs `mix ezagent.demo.seed_cc_sandbox --name my-cc-agent`
      # 2. Allen runs `mix phx.server` and creates the cc agent
      #    via /admin/templates → "Create cc.agent"
      # 3. Allen joins the agent into a session
      # 4. Allen sends "say hello" mentioning the agent
      # 5. agent-browser screenshots `/admin/sessions/<uri>` showing
      #    BOTH messages — this is the ESR e2e standard sign-off.
      #
      # No automation here — manual operator step.
      flunk("@tag :requires_allen — operator-driven; do not run in CI")
    end
  end
end
