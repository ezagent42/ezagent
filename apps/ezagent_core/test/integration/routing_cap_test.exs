defmodule Ezagent.Integration.RoutingCapTest do
  @moduledoc """
  PR #146 (SPEC v2 §5.7) invariant test — routing rule mutations
  dispatch to **scope-owning Kinds** (the `routing-admin://default`
  synthetic singleton has been dissolved):

  - Global rules → `system://routing/default?action=routing.<action>`
  - Workspace rules → `workspace://<name>?action=routing.<action>`
    (this test covers global; workspace/session paths share the same
    Behavior + same Capability shape modulo `kind:`/`instance:`)

  CapBAC step 5.5 fires against the scope-owning Kind. Non-admin
  without an explicit per-scope routing cap gets `:unauthorized`
  and an audit row written.

  If this test breaks, the per-rule cap-protect is broken regardless
  of green LV tests (admin's all-cap always passes; the gate is the
  non-admin path).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Routing.Matcher}
  alias EzagentDomainChat.Routing.MentionRouting

  defp admin_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }
  end

  defp non_admin_ctx do
    %{
      caller: URI.parse("entity://user/team-alpha/non-admin-test"),
      caps: MapSet.new(),
      reply: {:caller_inbox, self()}
    }
  end

  defp global_routing_target(action) do
    URI.parse(
      "#{URI.to_string(Ezagent.Entity.System.routing_default_uri())}?action=routing.#{action}"
    )
  end

  test "admin can add a rule via global Routing dispatch" do
    matcher =
      Matcher.text_contains("admin-test-#{System.unique_integer([:positive])}")

    assert {:ok, %{id: id}} =
             Invocation.dispatch(%Invocation{
               target: global_routing_target("add_rule"),
               mode: :call,
               args: %{
                 table: MentionRouting,
                 matcher_json: Matcher.to_json(matcher),
                 receivers: ["session://default/team-alpha/cap-test"]
               },
               ctx: admin_ctx()
             })

    assert is_integer(id)
  end

  test "non-admin gets :unauthorized when adding rule" do
    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: global_routing_target("add_rule"),
               mode: :call,
               args: %{
                 table: MentionRouting,
                 matcher_json: Matcher.to_json(Matcher.always()),
                 receivers: ["session://default/team-alpha/x"]
               },
               ctx: non_admin_ctx()
             })
  end

  test "non-admin gets :unauthorized for delete_rule" do
    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: global_routing_target("delete_rule"),
               mode: :call,
               args: %{table: MentionRouting, id: 999_999},
               ctx: non_admin_ctx()
             })
  end

  test "System Kind singleton is alive at boot at system://routing/default" do
    uri = Ezagent.Entity.System.routing_default_uri()
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(uri)
  end

  test "System Kind type_name is :system" do
    assert Ezagent.Entity.System.type_name() == :system
  end

  test "Behavior.Routing is registered on System Kind for all routing actions" do
    for action <- Ezagent.Behavior.Routing.actions() do
      assert {:ok, Ezagent.Behavior.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.System, action)
    end
  end

  test "Behavior.Routing is registered on Workspace + Session Kinds (scope-owning)" do
    for action <- Ezagent.Behavior.Routing.actions() do
      assert {:ok, Ezagent.Behavior.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Workspace, action)

      assert {:ok, Ezagent.Behavior.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, action)
    end
  end
end
