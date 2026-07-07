defmodule EzagentDomainUi.Routing.RoutingViewTest do
  @moduledoc """
  V1 Allen #2 — coverage for `EzagentDomainUi.Routing.RoutingView`.

  Verifies SessionView contract (id/label/icon + behaviour attr) +
  render/1 output for both empty-state and populated rule list.
  """

  use ExUnit.Case, async: true

  alias EzagentDomainUi.Routing.RoutingView

  describe "SessionView contract" do
    test "id/label/icon are stable" do
      assert RoutingView.id() == :routing
      assert RoutingView.label() == "Routing"
      assert RoutingView.icon() == "route"
    end

    test "implements Ezagent.UI.SessionView" do
      behaviours = RoutingView.module_info(:attributes)[:behaviour] || []
      assert Ezagent.UI.SessionView in behaviours
    end

    test "applies_to?/1 returns true for any session URI" do
      assert RoutingView.applies_to?(Ezagent.URI.new!("session://system/default/main"))
      assert RoutingView.applies_to?(Ezagent.URI.new!("session://team-alpha/default/foo"))
    end

    test "applies_to?/1 returns false for non-URI input" do
      refute RoutingView.applies_to?(nil)
      refute RoutingView.applies_to?("session://system/default/main")
      refute RoutingView.applies_to?(:atom)
    end
  end

  describe "render/1" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "renders header + session URI + link to /admin/routing" do
      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: []
        )

      assert html =~ "Session Routing Rules"
      assert html =~ "session://system/default/main"
      # 2026-05-25 — /routing relocated to /admin/routing (admin scope).
      assert html =~ ~s(href="/admin/routing")
    end

    test "renders empty state when no rules" do
      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: []
        )

      assert html =~ ~s(id="session-routing-rules-empty")
      assert html =~ "No session-scoped rules"
    end

    test "renders rule list when rules present" do
      rules = [
        %{
          id: 42,
          table_name: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
          matcher:
            {:and,
             [
               {:in_session, "session://system/default/main"},
               {:mention, "entity://team-alpha/agent/cc_demo"}
             ]},
          matcher_repr:
            "{:and, [{:in_session, \"session://system/default/main\"}, {:mention, \"entity://team-alpha/agent/cc_demo\"}]}",
          receivers: ["entity://team-alpha/agent/py_default"],
          receivers_repr: "entity://team-alpha/agent/py_default",
          source: "admin",
          enabled: true
        }
      ]

      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: rules
        )

      refute html =~ ~s(id="session-routing-rules-empty")
      assert html =~ ~s(id="session-routing-rule-42")
      assert html =~ "entity://team-alpha/agent/cc_demo"
      assert html =~ "entity://team-alpha/agent/py_default"
      assert html =~ "Disable"
      # Toggle button carries the row metadata.
      assert html =~ ~s(phx-click="routing_rule_toggle")
      assert html =~ ~s(phx-value-id="42")
      assert html =~ ~s(phx-value-enabled="true")
    end

    test "disabled rule shows Enable button + opacity hint" do
      rules = [
        %{
          id: 7,
          table_name: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
          matcher: {:always},
          matcher_repr: "{:always}",
          receivers: ["entity://team-alpha/agent/py_default"],
          receivers_repr: "entity://team-alpha/agent/py_default",
          source: "admin",
          enabled: false
        }
      ]

      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: rules
        )

      assert html =~ "Enable"
      refute html =~ ">Disable<"
      assert html =~ "opacity-50"
    end

    test "renders system_default badge when source is system_default" do
      rules = [
        %{
          id: 1,
          table_name: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
          matcher: {:always},
          matcher_repr: "{:always}",
          receivers: ["$session_members"],
          receivers_repr: "$session_members",
          source: "system_default",
          enabled: true
        }
      ]

      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: rules
        )

      assert html =~ "system_default"
    end

    test "renders add-rule form with matcher_type + receivers inputs" do
      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: []
        )

      assert html =~ ~s(id="session-routing-add-form")
      assert html =~ ~s(phx-submit="routing_rule_add_session")
      # Matcher type select + arg input + receivers input present.
      assert html =~ ~s(name="rule[matcher_type]")
      assert html =~ ~s(name="rule[matcher_arg]")
      assert html =~ ~s(name="rule[receivers]")
      assert html =~ "Add rule"
      assert html =~ "+ Add session-scoped rule"
    end

    test "renders role-aware matcher and receiver authoring affordances" do
      html =
        render_component(&RoutingView.render/1,
          session_uri: Ezagent.URI.new!("session://system/default/main"),
          session_routing_rules: []
        )

      assert html =~ ~s(<option value="from_role">from_role</option>)
      assert html =~ ~s(data-allow-freetext="true")
      assert html =~ "role:builder"
    end

    test "renders gracefully with nil session_uri" do
      html = render_component(&RoutingView.render/1, [])

      assert html =~ "Session Routing Rules"
      assert html =~ "(no session)"
    end
  end
end
