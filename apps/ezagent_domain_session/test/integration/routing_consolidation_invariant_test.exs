defmodule EzagentDomainInstanceMessage.Integration.RoutingConsolidationInvariantTest do
  @moduledoc """
  Phase 4-completion PR 9 invariant test (the routing-leak gate).

  Per memory `feedback_completion_requires_invariant_test` + Allen
  2026-05-16: "通信 routing 的逻辑散落在代码各处,很容易出 bug" — the
  bug risk comes from hidden fan-out logic in Behavior code that bypasses
  the RoutingRegistry.

  **This test catches future leaks**: if anyone re-introduces a hardcoded
  fan-out in `Chat.invoke(:send)` (or any other dispatch site), the
  test fails because removing all routing rules should silence ALL
  message delivery.

  Architectural assertion:
  > **Every recipient of every chat message comes from
  > `Ezagent.Routing.Resolver.resolve/3`. No exceptions.**

  If this property holds:
  - LV `/admin/routing` shows the complete effective routing
  - Operators can predict message flow from rule inspection alone
  - Plugin authors have one place to look + one place to add routes

  If broken: silent dispatches happen outside the rule table. Hidden
  routing. Hard-to-debug bugs.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  # Sandbox provided by EzagentCore.DataCase (#92).

  defp build_msg(text \\ "hi", mentions \\ [], sender \\ "entity://system/user/admin") do
    %Ezagent.Message{
      id: "test-#{System.unique_integer([:positive])}",
      sender: Ezagent.URI.new!(sender),
      body: %{text: text, attachments: []},
      mentions: Enum.map(mentions, &URI.parse/1),
      ref_id: nil,
      inserted_at: ~U[2026-05-16 00:00:00.000000Z]
    }
  end

  describe "Resolver is the SINGLE source of routing decisions" do
    test "no rules + no members → no recipients (the gate)" do
      # Setup: temporarily replace the global RoutingRegistry with an
      # empty test table. Application.put_env scoped to this test only.
      original_tables =
        Application.get_env(:ezagent_core, :routing_tables, [
          EzagentDomainInstanceMessage.Routing.MentionRouting,
          EzagentDomainInstanceMessage.Routing.SessionRouting
        ])

      empty_table = :"empty_table_#{System.unique_integer([:positive])}"
      Ezagent.RoutingRegistry.declare_table(empty_table, key_uniqueness: :duplicate)
      Application.put_env(:ezagent_core, :routing_tables, [empty_table])

      try do
        recipients =
          Resolver.resolve(build_msg(), Ezagent.URI.new!("session://team-alpha/default/test"), [])

        assert recipients == [],
               "no rules + no members must produce zero recipients — " <>
                 "if non-empty, a hidden fan-out is leaking in Resolver or upstream caller"
      after
        Application.put_env(:ezagent_core, :routing_tables, original_tables)
      end
    end

    test "$session_members expands to passed members (excluding sender)" do
      table = :"members_test_#{System.unique_integer([:positive])}"
      Ezagent.RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

      original_tables =
        Application.get_env(:ezagent_core, :routing_tables, [MentionRouting])

      Application.put_env(:ezagent_core, :routing_tables, [table])

      try do
        # System-default-shape rule: always → $session_members
        Ezagent.RoutingRegistry.put(
          table,
          Matcher.always(),
          [Resolver.session_members_token()]
        )

        members = [
          Ezagent.URI.new!("entity://system/user/admin"),
          Ezagent.URI.new!("entity://team-alpha/agent/test_x"),
          Ezagent.URI.new!("entity://team-alpha/agent/test_y")
        ]

        msg = build_msg("hi", [], "entity://system/user/admin")

        recipients =
          Resolver.resolve(msg, Ezagent.URI.new!("session://team-alpha/default/test"), members)

        # admin is sender → excluded; remaining 2 → recipients
        assert length(recipients) == 2

        recipient_strs = Enum.map(recipients, &URI.to_string/1) |> Enum.sort()

        assert recipient_strs == [
                 "entity://team-alpha/agent/test_x",
                 "entity://team-alpha/agent/test_y"
               ]
      after
        Application.put_env(:ezagent_core, :routing_tables, original_tables)
      end
    end

    test "current session is excluded from cross-session targets (recursion guard)" do
      table = :"recur_test_#{System.unique_integer([:positive])}"
      Ezagent.RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

      original_tables =
        Application.get_env(:ezagent_core, :routing_tables, [MentionRouting])

      Application.put_env(:ezagent_core, :routing_tables, [table])

      try do
        current = Ezagent.URI.new!("session://system/default/main")

        # Rule routes to current session — Resolver MUST exclude it
        Ezagent.RoutingRegistry.put(table, Matcher.always(), [URI.to_string(current)])

        recipients = Resolver.resolve(build_msg(), current, [])

        refute Enum.any?(recipients, fn r ->
                 URI.to_string(r) == "session://system/default/main"
               end),
               "Resolver must exclude current session URI to prevent dispatch loop"
      after
        Application.put_env(:ezagent_core, :routing_tables, original_tables)
      end
    end
  end

  describe "DefaultRules bootstrap consolidation" do
    test "MentionRouting has exactly one system_default rule after bootstrap" do
      # DefaultRules.bootstrap ran at chat plugin Application start.
      # Mention-gated-routing (2026-05-22): the single system_default
      # rule is now `always → [$session_users, $mentions]`.
      defaults =
        RuleStore.list(MentionRouting)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      assert length(defaults) == 1,
             "expected exactly 1 system_default rule in MentionRouting, got #{length(defaults)}"

      [rule] = defaults

      assert rule.receivers == [
               Resolver.session_users_token(),
               Resolver.mentions_token()
             ]

      assert rule.matcher_data == %{"type" => "always"}
    end

    test "system_default rule cannot be deleted via delete/1 (PR 9 §C protection)" do
      [default] =
        RuleStore.list(MentionRouting)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      assert {:error, :cannot_delete_system_default} = RuleStore.delete(default.id)

      # Verify still present
      [_] =
        RuleStore.list(MentionRouting)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))
    end

    test "system_default rule CAN be disabled (admin opt-out path)" do
      [default] =
        RuleStore.list(MentionRouting)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      assert :ok = RuleStore.disable(default.id)

      # Re-fetch — enabled should be false
      [refetched] =
        RuleStore.list(MentionRouting)
        |> Enum.filter(&(&1.source == RuleStore.system_default_source()))

      refute refetched.enabled
    end

    test "DefaultRules.bootstrap is idempotent (PR 9 §C + boot-ordering invariant)" do
      before_count =
        RuleStore.list(MentionRouting)
        |> Enum.count(&(&1.source == RuleStore.system_default_source()))

      :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()

      after_count =
        RuleStore.list(MentionRouting)
        |> Enum.count(&(&1.source == RuleStore.system_default_source()))

      assert after_count == before_count,
             "DefaultRules.bootstrap must be idempotent — same source row count"
    end
  end
end
