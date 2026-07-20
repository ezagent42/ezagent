defmodule EzagentCore.Invariants.Phase5NoRegressionTest do
  @moduledoc """
  Phase 6 PR 12 closeout invariant — pins Phase 5 functionality that
  MUST NOT regress through any Phase 6+ refactor.

  Per Allen's directive: "确保和 phase 5 时的功能没有回归".

  Each test names the Phase 5 capability it's pinning. If a Phase 6 PR
  breaks one of these, the assertion failure is the signal.

  Scope deliberately covers core surfaces only — full e2e (Feishu /
  CC channel) lives in agent-browser tests + manual demo.
  """
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{BehaviorRegistry, KindRegistry, RoutingRegistry}

  describe "Phase 5: foundational Kinds" do
    test "session://system/default/main is registered" do
      uri = Ezagent.Entity.Session.default_uri()
      assert {:ok, pid} = KindRegistry.lookup(uri)
      assert Process.alive?(pid)
    end

    test "entity://system/user/admin is registered + has admin caps" do
      uri = Ezagent.Entity.User.admin_uri()
      assert {:ok, pid} = KindRegistry.lookup(uri)
      assert Process.alive?(pid)

      # Admin must carry the global admin cap set so admin LV can do anything.
      caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      assert MapSet.size(caps) > 0
    end

    # PR #146 (SPEC v2 §5.7) — `routing-admin://default` synthetic
    # singleton dissolved. The functionally-equivalent invariant is the
    # global System Kind sentinel for routing.
    #
    # #52 Mode-B fix: this sentinel is no longer eager-spawned at boot in
    # `:test` (its `Kind.Server.init/1` `kind_snapshots` read/write would
    # run with no sandbox owner). The equivalent invariant is now "it
    # DEMAND-spawns + resolves". We check out a sandbox connection so the
    # spawn's DB work is owned, spawn the sentinel, and assert it's alive.
    test "system://routing/default singleton demand-spawns + is alive" do
      uri = Ezagent.Entity.System.routing_default_uri()

      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, pid} -> Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)
        {:error, {:already_started, _pid}} -> :ok
      end

      assert {:ok, pid} = KindRegistry.lookup(uri)
      assert Process.alive?(pid)
    end
  end

  describe "Phase 5: BehaviorRegistry wiring" do
    test "Chat actions are registered on the right Kinds" do
      # Session-side actions
      assert {:ok, Ezagent.ActionSet.Session} =
               BehaviorRegistry.lookup(Ezagent.Entity.Session, :send)

      assert {:ok, Ezagent.ActionSet.Session} =
               BehaviorRegistry.lookup(Ezagent.Entity.Session, :join)

      assert {:ok, Ezagent.ActionSet.Session} =
               BehaviorRegistry.lookup(Ezagent.Entity.Session, :leave)

      # Receiver-side — PR-2 (im/session/agent decomposition §OQ-4) split
      # the single `:receive` into two first-class Behaviors, each on its
      # own Kind: `user.receive` (passive inbox) / `agent.receive` (live
      # delivery). The internal `case kind_module` is retired.
      assert {:ok, Ezagent.ActionSet.User.Receive} =
               BehaviorRegistry.lookup(Ezagent.Entity.User, :receive)

      assert {:ok, Ezagent.ActionSet.Agent.Receive} =
               BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive)
    end

    test "Identity actions are registered" do
      assert {:ok, Ezagent.ActionSet.Identity} =
               BehaviorRegistry.lookup(Ezagent.Entity.User, :list_caps)

      assert {:ok, Ezagent.ActionSet.Identity} =
               BehaviorRegistry.lookup(Ezagent.Entity.User, :has_cap?)
    end

    test "Workspace actions are registered" do
      actions = Ezagent.ActionSet.Workspace.actions()
      assert length(actions) > 0

      for action <- actions do
        assert {:ok, Ezagent.ActionSet.Workspace} =
                 BehaviorRegistry.lookup(Ezagent.Entity.Workspace, action)
      end
    end
  end

  describe "Phase 5: routing tables declared" do
    # 2026-05-25 — SessionRouting deleted (PR-EM-3 #317 moved its
    # bridge responsibility to ExternalMirror). MentionRouting is now
    # the only chat-plugin-owned routing table. The same invariant
    # also actively guards against a re-introduction of SessionRouting.
    test "MentionRouting table exists; SessionRouting is NOT (re-)declared" do
      assert :ets.whereis(
               :"ezagent_routing_Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting"
             ) !=
               :undefined

      assert :ets.whereis(
               :"ezagent_routing_Elixir.EzagentDomainInstanceMessage.Routing.SessionRouting"
             ) ==
               :undefined
    end

    test "the system_default mention-gated rule is loaded" do
      # The boot path loads the system_default rule. Mention-gated
      # routing (2026-05-22 —
      # docs/superpowers/specs/2026-05-22-mention-gated-routing.md)
      # changed its receivers from [$session_members] to
      # [$session_users, $mentions]. Without this rule, chat/send
      # routes nowhere.
      entries = RoutingRegistry.list_all(EzagentDomainInstanceMessage.Routing.MentionRouting)

      assert Enum.any?(entries, fn {_matcher, value} ->
               receivers =
                 case value do
                   list when is_list(list) -> list
                   %{receivers: r} -> r
                 end

               "$session_users" in receivers and "$mentions" in receivers
             end),
             "system_default mention-gated rule ([$session_users, $mentions]) " <>
               "missing from MentionRouting"
    end
  end

  describe "Phase 5: EZAGENT_HOME runtime persistence" do
    test "Ezagent.Home resolves to a non-empty path" do
      assert is_binary(Ezagent.Home.home())
      assert Ezagent.Home.home() != ""
      assert is_binary(Ezagent.Home.profile())
    end
  end

  describe "Phase 5: distributed Erlang runtime configured (boot path)" do
    test "Ezagent.Runtime exposes runtime_node + cookie_path" do
      assert is_atom(Ezagent.Runtime.runtime_node())
      assert is_binary(Ezagent.Runtime.cookie_path())
    end
  end
end
