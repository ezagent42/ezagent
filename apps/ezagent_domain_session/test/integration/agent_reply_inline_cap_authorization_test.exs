defmodule EzagentDomainInstanceMessage.Integration.AgentReplyInlineCapAuthorizationTest do
  @moduledoc """
  System-principal elimination (#154, 甲-3) — `system://chat-reply` LINCHPIN
  regression.

  The 5 agent/plugin bridge adapters (curl_agent, plugin_codex, plugin_cc,
  echo, np_agent) used to reply into their session by borrowing the
  `system://chat-reply` WILDCARD principal's caps in `ctx.caps`. That ambient
  wildcard is now DELETED; each bridge instead presents its OWN narrow
  `session.send` cap on the concrete reply session as the step-5.5 authorizer
  (`granted_via_ctx_caps?`).

  The narrowing pins the cap's `behavior` axis from `:any` to the concrete
  `Ezagent.Behavior.Session`. A wildcard `behavior: :any` matched ANY runtime
  needed-behavior; a CONCRETE behavior only authorizes if the dispatch path's
  `cap_for_action(Entity.Session, :send, target)` derives EXACTLY
  `Ezagent.Behavior.Session` via `BehaviorRegistry.lookup/2`. If that runtime
  resolution ever drifts, all 5 reply paths silently stop authorizing and
  replies are dropped — a production break that no shape-only bridge test
  catches. This test is that gate.

  The cap shape asserted here is IDENTICAL across all 5 bridge sites, so
  proving ONE authorizing path proves the lot.
  """

  use EzagentCore.DataCase, async: false

  # NOTE: bare `%URI{}` is Elixir's stdlib URI struct — what `Ezagent.URI.new!/1`
  # returns. Function calls go through `Ezagent.URI` (NOT aliased, to avoid
  # shadowing the struct module). Mirrors the bridge sites + the sibling
  # behavior_template_dispatch_test.
  alias Ezagent.{BehaviorRegistry, Capability}

  # The exact inline cap the 5 bridges mint — kept in lock-step with the
  # bridge-site code (curl_agent.ex / bridge_adapter.ex (codex+cc) / echo.ex /
  # np_agent.ex). `granted_by` is the agent's own URI (genuine self-authority,
  # #154-ok); inline = provenance-only authorizer, never routed through Grant.
  defp inline_reply_cap(%URI{} = session, %URI{} = agent_uri) do
    %Capability{
      Capability.cap(
        :session,
        Ezagent.Behavior.Session,
        :send,
        Ezagent.URI.instance(session),
        Capability.workspace_of(session)
      )
      | granted_by: agent_uri,
        granted_at: DateTime.utc_now()
    }
  end

  describe "BehaviorRegistry resolution (the pinned behavior axis)" do
    test "Entity.Session resolves :send → Ezagent.Behavior.Session" do
      assert {:ok, Ezagent.Behavior.Session} =
               BehaviorRegistry.lookup(Ezagent.Entity.Session, :send),
             "session.send must resolve to Ezagent.Behavior.Session — the behavior " <>
               "axis the inline reply cap pins. If this drifts, all 5 bridge reply " <>
               "paths stop authorizing."
    end
  end

  describe "inline reply cap authorizes the runtime needed_map" do
    test "narrow session.send cap matches the dispatch-derived needed_map for a reply target" do
      session = Ezagent.URI.new!("session://team-alpha/default/reply-probe")
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/reply-probe")
      target = Ezagent.URI.with_action(session, :session, :send)

      cap = inline_reply_cap(session, agent_uri)

      # Build the needed-cap map the way dispatch step 5.5 does — through
      # `cap_for_action/3` (which calls `BehaviorRegistry.lookup/2` for the
      # behavior axis). NON-circular: we do NOT hand-build the needed map.
      needed = Capability.cap_for_action(Ezagent.Entity.Session, :send, target)

      assert Capability.matches?(cap, needed),
             "the agent's OWN inline narrow session.send cap must authorize the " <>
               "runtime needed_map (#{inspect(needed)}); if it does not, the bridge " <>
               "reply path is broken — replies would be dropped."
    end

    test "the cap does NOT authorize a different action (least-privilege proof)" do
      session = Ezagent.URI.new!("session://team-alpha/default/reply-probe-le")
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/reply-probe-le")
      join_target = Ezagent.URI.with_action(session, :session, :join)

      cap = inline_reply_cap(session, agent_uri)
      needed_join = Capability.cap_for_action(Ezagent.Entity.Session, :join, join_target)

      refute Capability.matches?(cap, needed_join),
             "the narrow send cap must NOT authorize session.join — it is least " <>
               "privilege (only session.send on the agent's own reply session), " <>
               "unlike the eliminated chat-reply wildcard."
    end
  end
end
