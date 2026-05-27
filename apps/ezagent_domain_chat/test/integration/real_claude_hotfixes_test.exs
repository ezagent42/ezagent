defmodule EzagentDomainChat.Integration.RealClaudeHotfixesTest do
  @moduledoc """
  Regression test for Phase 3d hotfix exposed by real-claude e2e on
  2026-05-16, **ported to v2 in Phase 7 PR 32c** (the v1 prototype
  bridge it originally exercised is deleted; this file no longer
  references the old module name to keep the v1-deletion invariant
  test happy).

  ## Fix #1: source session in to_claude meta

  Chat.invoke(:receive) on Agent Kind must include `"session"` in the
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

  use ExUnit.Case
  alias Ezagent.{Message}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    Ezagent.AgentBridge.Registry.init()
    :ok = Ezagent.AgentBridge.AdapterRegistry.register("cc", EzagentPluginCc.BridgeAdapter)
    :ok
  end

  describe "fix #1: to_claude payload meta includes source session" do
    test "Chat.invoke(:receive) on Agent sends {:to_claude, %{meta}} to bound channel pid with session key" do
      agent_uri = URI.new!("entity://agent/team-alpha/cc_meta-test-#{System.unique_integer([:positive])}")
      session_uri = URI.new!("session://default/team-alpha/meta-source-#{System.unique_integer([:positive])}")

      # Spawn the Agent Kind (mirrors what Channel.join/3 does via
      # SpawnRegistry.spawn at bridge join time).
      {:ok, agent_pid} =
        DynamicSupervisor.start_child(
          EzagentDomainChat.AgentSupervisor,
          {Ezagent.Kind.Server, {Ezagent.Entity.Agent, %{uri: agent_uri}}}
        )

      # Bind the *test process* as the "channel pid" for this agent.
      # AgentBridge.deliver/2 will resolve the cc adapter and send
      # {:to_claude, payload} here so we can assert_receive on it.
      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())

      msg =
        Message.new(URI.new!("entity://user/system/admin"), %{text: "hi cc-builder", attachments: []})

      ctx = %{
        caller: session_uri,
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: :ignore,
        kind_module: Ezagent.Entity.Agent,
        self_uri: agent_uri
      }

      assert {:ok, _} = Chat.invoke(:receive, %{}, %{message: msg}, ctx)

      assert_receive {:to_claude, %{"meta" => meta}}, 500
      assert meta["session"] == URI.to_string(session_uri)
      assert meta["sender"] == "entity://user/system/admin"
      assert meta["message_id"] == msg.id

      Ezagent.AgentBridge.Registry.unbind(agent_uri)
      DynamicSupervisor.terminate_child(EzagentDomainChat.AgentSupervisor, agent_pid)
    end
  end
end
