defmodule EzagentDomainInstanceMessage.Integration.ChatRouterInlineCapAuthorizationTest do
  @moduledoc """
  System-principal elimination (#154, 甲-4) — `system://chat-router` LINCHPIN
  regression.

  The Session delivery fan-out used to borrow the `system://chat-router`
  WILDCARD principal's caps in `ctx.caps` for three dispatches. That ambient
  wildcard is now DELETED; each dispatch instead presents a narrow inline cap
  as the step-5.5 authorizer (`granted_via_ctx_caps?`). This test pins that
  each inline cap actually AUTHORIZES the runtime needed-map AND is
  least-privilege — without it, a future drift in cap resolution would
  silently drop deliveries (no shape-only test would catch it). It also pins
  the cross-session-forward same-workspace guard, the only genuinely new
  branch in the elimination.

  The three re-attributed sites:
    1. `dispatch_receive_call` — per-recipient `:receive` cap (member
       self-consent, `granted_by: recipient_uri`).
    2. `dispatch_cross_session_call` — `session.send` on the concrete target
       (`granted_by: source_session`) + same-workspace guard.
    3. `sync_result_effect` — the agent's own `:sync_result` self-cap.
  """

  use EzagentCore.DataCase, async: false

  # NOTE: bare `%URI{}` is Elixir's stdlib URI struct — what `Ezagent.URI.new!/1`
  # returns. Function calls go through `Ezagent.URI` (NOT aliased, to avoid
  # shadowing the struct module). Mirrors the sibling
  # agent_reply_inline_cap_authorization_test (甲-3).
  alias Ezagent.{BehaviorRegistry, Capability, Message}
  alias Ezagent.ActionSet.Session.Delivery

  # --- (1) receive fan-out -------------------------------------------------

  # The exact inline cap `dispatch_receive_call` mints (kept in lock-step with
  # `delivery.ex member_receive_caps/1`). `kind`/`behavior` are `:any` because
  # the needed (kind, behavior) pair varies across the OPEN plugin set;
  # `action: :receive` + `instance` (THIS recipient) carry the least-privilege.
  defp inline_receive_cap(%URI{} = recipient_uri) do
    %Capability{
      Capability.cap(
        :any,
        :any,
        :receive,
        Ezagent.URI.instance(recipient_uri),
        Capability.workspace_of(recipient_uri)
      )
      | granted_by: recipient_uri,
        granted_at: DateTime.utc_now()
    }
  end

  describe "BehaviorRegistry resolution (the pinned receive behavior axis)" do
    test "Entity.User resolves :receive → Behavior.User.Receive" do
      assert {:ok, Ezagent.ActionSet.User.Receive} =
               BehaviorRegistry.lookup(Ezagent.Entity.User, :receive),
             "user.receive must resolve to Behavior.User.Receive — the needed-cap " <>
               "behavior axis the per-recipient inline cap must field-match."
    end

    test "Entity.Agent resolves :receive → Behavior.Agent.Receive" do
      assert {:ok, Ezagent.ActionSet.Agent.Receive} =
               BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive),
             "agent.receive must resolve to Behavior.Agent.Receive."
    end
  end

  describe "inline receive cap authorizes the runtime needed_map" do
    test "per-recipient receive cap matches the dispatch-derived needed_map (user recipient)" do
      recipient = Ezagent.URI.new!("entity://team-alpha/user/bob")
      target = Ezagent.URI.with_action(recipient, :user, :receive)

      cap = inline_receive_cap(recipient)
      needed = Capability.cap_for_action(Ezagent.Entity.User, :receive, target)

      assert Capability.matches?(cap, needed),
             "the recipient's OWN inline :receive cap must authorize the runtime " <>
               "needed_map (#{inspect(needed)}); else the fan-out drops the delivery."
    end

    test "per-recipient receive cap matches the dispatch-derived needed_map (agent recipient)" do
      recipient = Ezagent.URI.new!("entity://team-alpha/agent/echo_1")
      target = Ezagent.URI.with_action(recipient, :agent, :receive)

      cap = inline_receive_cap(recipient)
      needed = Capability.cap_for_action(Ezagent.Entity.Agent, :receive, target)

      assert Capability.matches?(cap, needed),
             "the agent recipient's OWN inline :receive cap must authorize the " <>
               "runtime needed_map (#{inspect(needed)})."
    end

    test "receive cap does NOT authorize a DIFFERENT recipient (instance-pinned)" do
      recipient = Ezagent.URI.new!("entity://team-alpha/user/bob")
      other = Ezagent.URI.new!("entity://team-alpha/user/carol")
      other_target = Ezagent.URI.with_action(other, :user, :receive)

      cap = inline_receive_cap(recipient)
      needed_other = Capability.cap_for_action(Ezagent.Entity.User, :receive, other_target)

      refute Capability.matches?(cap, needed_other),
             "bob's receive cap must NOT authorize a receive into carol — the " <>
               "instance axis is the member-consent boundary."
    end

    test "receive cap does NOT authorize :send on the recipient (least-privilege)" do
      recipient = Ezagent.URI.new!("entity://team-alpha/user/bob")
      # A `session.send` need on a session sharing the recipient's workspace.
      session = Ezagent.URI.new!("session://team-alpha/default/main")
      send_target = Ezagent.URI.with_action(session, :session, :send)

      cap = inline_receive_cap(recipient)
      needed_send = Capability.cap_for_action(Ezagent.Entity.Session, :send, send_target)

      refute Capability.matches?(cap, needed_send),
             "the :receive cap must NOT authorize :send — action axis is pinned."
    end
  end

  # --- (2) cross-session forward ------------------------------------------

  defp inline_cross_session_send_cap(%URI{} = target_session, %URI{} = source_session) do
    %Capability{
      Capability.cap(
        :session,
        :any,
        :send,
        Ezagent.URI.instance(target_session),
        Capability.workspace_of(target_session)
      )
      | granted_by: source_session,
        granted_at: DateTime.utc_now()
    }
  end

  describe "inline cross-session send cap authorizes the runtime needed_map" do
    test "cross-session send cap matches the :send needed_map for the target session" do
      target = Ezagent.URI.new!("session://team-alpha/default/oncall")
      source = Ezagent.URI.new!("session://team-alpha/default/main")
      send_target = Ezagent.URI.with_action(target, :session, :send)

      cap = inline_cross_session_send_cap(target, source)
      needed = Capability.cap_for_action(Ezagent.Entity.Session, :send, send_target)

      assert Capability.matches?(cap, needed),
             "the cross-session forward's inline session.send cap must authorize " <>
               "the runtime needed_map (#{inspect(needed)})."
    end

    test "cross-session send cap does NOT authorize :join (least-privilege)" do
      target = Ezagent.URI.new!("session://team-alpha/default/oncall")
      source = Ezagent.URI.new!("session://team-alpha/default/main")
      join_target = Ezagent.URI.with_action(target, :session, :join)

      cap = inline_cross_session_send_cap(target, source)
      needed_join = Capability.cap_for_action(Ezagent.Entity.Session, :join, join_target)

      refute Capability.matches?(cap, needed_join),
             "the forward cap must NOT authorize session.join — action-pinned."
    end
  end

  describe "cross-session forward same-workspace guard" do
    test "same-workspace sessions share a workspace (guard predicate would PASS)" do
      a = Ezagent.URI.new!("session://team-alpha/default/main")
      b = Ezagent.URI.new!("session://team-alpha/default/oncall")

      wa = Capability.workspace_of(a)
      wb = Capability.workspace_of(b)

      assert match?(%URI{}, wa) and match?(%URI{}, wb),
             "workspace_of must resolve session URIs to a %URI{} — else the guard " <>
               "fails closed and silently blocks legitimate same-ws forwards."

      assert URI.to_string(wa) == URI.to_string(wb),
             "two sessions in the same workspace must resolve to the same workspace URI."
    end

    test "cross-workspace forward is REFUSED before any dispatch" do
      source = Ezagent.URI.new!("session://team-alpha/default/main")
      target = Ezagent.URI.new!("session://team-beta/default/oncall")
      msg = Message.new(Ezagent.URI.new!("entity://team-alpha/user/sender"), %{text: "hi"})

      assert {:error, :cross_workspace_forward_forbidden} =
               Delivery.dispatch_cross_session_call(target, msg, source),
             "a cross-WORKSPACE forward must be refused by the same-workspace guard " <>
               "(no designed use case; #154 甲-4 containment)."
    end

    test "cross-workspace workspaces differ (guard predicate would REJECT)" do
      a = Ezagent.URI.new!("session://team-alpha/default/main")
      b = Ezagent.URI.new!("session://team-beta/default/oncall")

      refute URI.to_string(Capability.workspace_of(a)) ==
               URI.to_string(Capability.workspace_of(b)),
             "sessions in different workspaces must resolve to different workspace URIs."
    end
  end

  # --- (3) sync_result self-dispatch --------------------------------------

  defp inline_sync_result_self_cap(%URI{} = self_uri) do
    %Capability{
      Capability.cap(
        :any,
        :any,
        :sync_result,
        Ezagent.URI.instance(self_uri),
        Capability.workspace_of(self_uri)
      )
      | granted_by: self_uri,
        granted_at: DateTime.utc_now()
    }
  end

  describe "inline sync_result self-cap authorizes the runtime needed_map" do
    test "self-cap matches a :sync_result need on the agent's OWN instance" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_1")
      # The flavor Behavior's required_caps[:sync_result] is
      # cap(:agent, <FlavorBehavior>, :sync_result) with instance/workspace
      # substituted at dispatch. Build a representative concrete needed-map.
      needed = %{
        kind: :agent,
        behavior: Ezagent.ActionSet.Agent.Receive,
        action: :sync_result,
        instance: Ezagent.URI.instance(self_uri),
        workspace_uri: Capability.workspace_of(self_uri)
      }

      cap = inline_sync_result_self_cap(self_uri)

      assert Capability.matches?(cap, needed),
             "the agent's OWN :sync_result self-cap must authorize the sync_result " <>
               "need on its own instance (#{inspect(needed)})."
    end

    test "sync_result self-cap does NOT authorize a different action (least-privilege)" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_1")

      needed_configure = %{
        kind: :agent,
        behavior: Ezagent.ActionSet.Agent.Receive,
        action: :configure,
        instance: Ezagent.URI.instance(self_uri),
        workspace_uri: Capability.workspace_of(self_uri)
      }

      cap = inline_sync_result_self_cap(self_uri)

      refute Capability.matches?(cap, needed_configure),
             "the sync_result self-cap must NOT authorize :configure — action-pinned."
    end

    test "sync_result self-cap does NOT authorize sync_result on a DIFFERENT agent" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_1")
      other = Ezagent.URI.new!("entity://team-alpha/agent/curl_2")

      needed_other = %{
        kind: :agent,
        behavior: Ezagent.ActionSet.Agent.Receive,
        action: :sync_result,
        instance: Ezagent.URI.instance(other),
        workspace_uri: Capability.workspace_of(other)
      }

      cap = inline_sync_result_self_cap(self_uri)

      refute Capability.matches?(cap, needed_other),
             "curl_1's self-cap must NOT authorize curl_2's sync_result — instance-pinned."
    end
  end
end
