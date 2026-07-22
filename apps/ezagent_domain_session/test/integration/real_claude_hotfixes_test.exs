defmodule EzagentDomainInstanceMessage.Integration.RealClaudeHotfixesTest do
  @moduledoc """
  Regression test for Phase 3d hotfix exposed by real-claude e2e on
  2026-05-16, **ported to v2 in Phase 7 PR 32c** (the v1 prototype
  bridge it originally exercised is deleted; this file no longer
  references the old module name to keep the v1-deletion invariant
  test happy).

  ## Fix #1: source session in to_claude meta

  EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(Ezagent.ActionSet.Session, :receive) on Agent Kind must include `"session"` in the
  meta map so claude can fill `session_uris` correctly on reply.
  Previously claude guessed (badly) from sender URI. The fix
  populates `meta["session"]` from `ctx.caller` before sending the
  `{:to_claude, payload}` message to the bound bridge pid.

  The v1 test bound an agent_uri to a bridge_id on
  `the v1 prototype Server` and subscribed to its per-bridge
  PubSub topic. The v2 path bypasses PubSub entirely: the bound
  channel pid receives `{:to_claude, payload}` directly. This test
  binds the test process pid into `Ezagent.AgentBridge.Registry` and
  uses `assert_receive` to capture the same payload.

  ## Fix #2 (dropped)

  The original test #2 exercised the `:reply_received` Agent-pid
  message path that v1 used. v2's Channel.handle_in("reply", ...)
  dispatches via `Ezagent.Invocation.dispatch/1` directly, bypassing
  that path. Telemetry for session-not-found at the Channel layer is
  a future enhancement.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.{Message}

  setup do
    # Shared sandbox provided by EzagentCore.DataCase (#92).
    Ezagent.AgentBridge.Registry.init()
    :ok = EzagentDomainInstanceMessage.AgentBridgeTestAdapter.ensure_registered()
    :ok
  end

  describe "fix #1: to_claude payload meta includes source session" do
    test "session.receive on Agent sends to_claude agent_bridge_push with session-keyed meta to bound channel pid" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_meta-test-#{System.unique_integer([:positive])}")

      session_uri =
        URI.new!("session://team-alpha/default/meta-source-#{System.unique_integer([:positive])}")

      # Spawn the Agent Kind with stored flavor metadata so AgentBridge
      # resolves the adapter through UriQuery, not the URI name prefix.
      {:ok, _agent_pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")

      # Bind the *test process* as the "channel pid" for this agent.
      # AgentBridge.deliver/2 resolves the cc adapter, which sends
      # {:agent_bridge_push, "to_claude", payload} (the wire shape the
      # AgentBridge.Channel re-pushes, since #429) here so we can
      # assert_receive on it.
      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())

      msg =
        Message.new(URI.new!("entity://system/user/admin"), %{
          text: "hi cc-builder",
          attachments: []
        })

      # A2.2 — :receive authorizes on the recipient's HELD member-cap over
      # ctx.caller (the source session); supply it in the pre-loaded :identity
      # sibling (the gate itself is proven in HeldCapReceiveTest).
      member_cap = %Ezagent.Capability{
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :receive,
          session_uri,
          Ezagent.Capability.workspace_of(session_uri)
        )
        | granted_by: URI.new!("entity://system/user/owner"),
          granted_at: DateTime.utc_now()
      }

      ctx = %{
        caller: session_uri,
        authenticated_principal: session_uri,
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: :ignore,
        kind_module: Ezagent.Entity.Agent,
        self_uri: agent_uri,
        siblings: %{identity: %{caps: MapSet.new([member_cap])}}
      }

      assert {:ok, _} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Agent.Receive,
                 :receive,
                 %{},
                 %{message: msg},
                 ctx
               )

      assert_receive {:agent_bridge_push, "to_claude", %{"meta" => meta}}, 500
      assert meta["session"] == URI.to_string(session_uri)
      assert meta["sender"] == "entity://system/user/admin"
      assert meta["message_id"] == msg.id

      Ezagent.AgentBridge.Registry.unbind(agent_uri)
      Ezagent.Kind.terminate(agent_uri)
    end
  end
end
