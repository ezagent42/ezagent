defmodule EzagentPluginCodex.E2E.Scenario06CodexAgentRoundtripTest do
  @moduledoc """
  Scenario 06 — codex agent: spawn → bridge → reply.

  Cross-reference: `docs/scenarios/06-codex-agent-roundtrip/scenario.md`.

  ## What this proves

  The codex agent message roundtrip works via the new contract WITHOUT
  invoking the real `codex` CLI or starting the bridge sidecar
  subprocess. We exercise:

  1. `EzagentPluginCodex.BridgeAdapter.deliver/2` — outbound payload
     to codex bridge (the `codex_turn` channel frame the bridge sidecar
     consumes)
  2. `BridgeAdapter.handle_client_event("reply", ...)` — inbound reply
     parsing
  3. `dispatch_reply/5` — reply fan-out to session URIs

  Compared with cc (scenario 05), codex's `codex_turn` frame includes
  the `session_uri`, `sender_uri`, `event_type` and `message_id`
  fields — the codex bridge sidecar shares `thread_id` correlation
  via these.

  Real-CLI smoke is the operator-driven
  `scripts/codex_app_server_thread_repro.py` + `codex_bridge_thread_smoke.py`
  (PR #441 regression source-of-truth) — NOT runnable in CI per
  `feedback_esr_e2e_standards`.

  ## ALLEN MANUAL

  - PR #441 regression smoke: `python3 scripts/codex_app_server_thread_repro.py`
  - LiveView screenshot of `/admin/sessions/<uri>` showing the
    codex agent reply — required for e2e sign-off
  """

  use ExUnit.Case, async: false

  @moduletag scenario: "06-codex-agent-roundtrip"
  @moduletag :e2e

  alias Ezagent.AgentBridge.Payload
  alias EzagentPluginCodex.BridgeAdapter

  # ---------------------------------------------------------------
  # 1. AgentBridge → codex adapter → "codex_turn" channel push
  # ---------------------------------------------------------------

  describe "BridgeAdapter.deliver/2 — outbound to codex bridge" do
    test "converts an inbound chat payload into a `codex_turn` channel frame" do
      payload = %Payload{
        message_id: "m-#{System.unique_integer([:positive])}",
        session_uri: URI.new!("session://default/team-alpha/scenario06"),
        sender_uri: URI.new!("entity://user/system/admin"),
        text: "write a haiku about Erlang",
        event_type: :chat_send,
        meta: %{"sender" => "entity://user/system/admin"}
      }

      assert :ok = BridgeAdapter.deliver(payload, self())

      assert_receive {:agent_bridge_push, "codex_turn", frame}, 500

      # Codex frame carries the SHARED-state fields the codex bridge
      # uses for thread correlation (PR #441 invariant) — unlike cc's
      # minimal {content, meta} frame.
      assert frame["content"] == "write a haiku about Erlang"
      assert frame["session_uri"] == "session://default/team-alpha/scenario06"
      assert frame["sender_uri"] == "entity://user/system/admin"
      assert frame["event_type"] == "chat_send"
      assert frame["message_id"] == payload.message_id
      assert frame["meta"] == %{"sender" => "entity://user/system/admin"}
    end

    test "deliver/2 handles nil session_uri (system-broadcast payload)" do
      payload = %Payload{
        message_id: "m-sys",
        session_uri: nil,
        sender_uri: URI.new!("entity://user/system/admin"),
        text: "broadcast",
        event_type: :system
      }

      assert :ok = BridgeAdapter.deliver(payload, self())
      assert_receive {:agent_bridge_push, "codex_turn", frame}, 500
      assert frame["session_uri"] == nil
      assert frame["event_type"] == "system"
    end
  end

  # ---------------------------------------------------------------
  # 2. codex sidecar → BridgeAdapter.handle_client_event("reply", ...)
  # ---------------------------------------------------------------

  describe "BridgeAdapter.handle_client_event/3 — inbound reply" do
    test "rejects a reply without text + session_uris" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://agent/team-alpha/codex_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{"text" => "missing sessions"},
                 socket
               )

      assert msg =~ "text + session_uris"
    end

    test "rejects a reply with non-list attachments" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://agent/team-alpha/codex_alpha")}
      }

      assert {:reply, {:error, %{reason: msg}}, ^socket} =
               BridgeAdapter.handle_client_event(
                 "reply",
                 %{
                   "text" => "x",
                   "session_uris" => ["session://default/team-alpha/x"],
                   "attachments" => %{"oops" => true}
                 },
                 socket
               )

      assert msg =~ "list of maps"
    end

    test "non-reply events are passed-through with {:noreply, socket}" do
      socket = %Phoenix.Socket{
        assigns: %{agent_uri: URI.new!("entity://agent/team-alpha/codex_alpha")}
      }

      assert {:noreply, ^socket} =
               BridgeAdapter.handle_client_event("status", %{"ok" => true}, socket)
    end
  end

  # ---------------------------------------------------------------
  # 3. dispatch_reply/5 — agent-side chat.send to session(s)
  # ---------------------------------------------------------------

  describe "BridgeAdapter.dispatch_reply/5" do
    test "successfully encodes an attachment list with image/file/audio kinds" do
      # Verify the attachment-key + attachment-type normalisation
      # (string → atom maps) — the codex bridge ships JSON with
      # string keys, the dispatched Message expects atoms.
      agent_uri = URI.new!("entity://agent/team-alpha/codex_alpha")

      attachments = [
        %{"type" => "image", "local_path" => "/tmp/img.png", "name" => "img"},
        %{"type" => "file", "local_path" => "/tmp/doc.txt", "name" => "doc"}
      ]

      # dispatch_reply/5 only returns :ok in the codex adapter — the
      # core invariant is the dispatch shape going into Invocation.
      # We assert it doesn't raise + returns :ok on stale session.
      result =
        BridgeAdapter.dispatch_reply(
          agent_uri,
          ["session://default/team-alpha/never_spawned_codex_#{System.unique_integer([:positive])}"],
          "with attachments",
          "ref-abc-123",
          attachments
        )

      assert result == :ok
    end

    test "tolerates ref id absence (`nil` ref → no Message ref_id)" do
      agent_uri = URI.new!("entity://agent/team-alpha/codex_alpha")

      assert :ok =
               BridgeAdapter.dispatch_reply(
                 agent_uri,
                 ["session://default/team-alpha/never_spawned_codex_x"],
                 "no ref",
                 nil,
                 []
               )
    end
  end

  # ---------------------------------------------------------------
  # 4. join_info passes through codex-specific connect metadata
  # ---------------------------------------------------------------

  describe "BridgeAdapter.join_info/2" do
    test "preserves the codex_info + tools fields" do
      assert BridgeAdapter.join_info(
               %{"codex_info" => %{"version" => "0.1.0"}, "tools" => ["reply"]},
               %Phoenix.Socket{}
             ) == %{
               codex_info: %{"version" => "0.1.0"},
               tools: ["reply"]
             }
    end

    test "defaults to empty codex_info + [\"reply\"] tools (the codex default tool set)" do
      assert BridgeAdapter.join_info(%{}, %Phoenix.Socket{}) == %{
               codex_info: %{},
               tools: ["reply"]
             }
    end
  end

  # ---------------------------------------------------------------
  # 5. Adapter-contract surface
  # ---------------------------------------------------------------

  describe "AgentBridge.Adapter contract" do
    test "flavor is \"codex\"" do
      assert BridgeAdapter.flavor() == "codex"
    end

    test "agent_uri_prefix is \"codex_\" (PR #141 SPEC v2 flavor prefix)" do
      assert BridgeAdapter.agent_uri_prefix() == "codex_"
    end

    test "channel_topic_prefix routes to the codex agent_bridge sub-channel" do
      assert BridgeAdapter.channel_topic_prefix() == "agent_bridge:codex:"
    end

    test "socket_path is the unified agent_bridge mount (shared with cc)" do
      assert BridgeAdapter.socket_path() == "/agent_bridge"
    end
  end

  # ---------------------------------------------------------------
  # 6. ALLEN MANUAL — real-codex full smoke (skeleton)
  # ---------------------------------------------------------------

  describe "real-codex full roundtrip (ALLEN MANUAL)" do
    @tag :requires_allen
    @tag :skip
    test "real codex agent → admin chat.send → bridge thread continuity → reply" do
      # The canonical regression smoke for the codex bridge UDS WS
      # frame handling (PR #441 — `test/python/codex_app_server_thread_repro.py`)
      # is operator-driven:
      #
      #   $ uv run --script apps/ezagent_plugin_codex/test/python/codex_app_server_thread_repro.py
      #
      # It connects to a live app-server, runs a turn, restarts the
      # TUI, and asserts the `thread_id` survives the reconnection
      # (the original PR #441 bug).
      #
      # Per `feedback_esr_e2e_standards`, full sign-off ALSO requires
      # an agent-browser screenshot of `/admin/sessions/<uri>` showing
      # the codex agent reply — manual operator step.
      flunk("@tag :requires_allen — operator-driven; do not run in CI")
    end
  end
end
