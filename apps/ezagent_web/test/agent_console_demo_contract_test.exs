defmodule AgentConsoleDemoContractTest do
  use ExUnit.Case, async: true

  @demo_path Path.expand("../priv/static/agent-console-demo/index.html", __DIR__)

  test "static demo reflects the approved operate-first PRD contract" do
    html = File.read!(@demo_path)

    assert html =~ ~s(data-demo-contract="agent-console-operate-first-v1")
    assert html =~ "独立静态设计确认 demo"
    assert html =~ "不接后端"

    for nav <- ["概览", "会话", "模板"] do
      assert html =~ nav
    end

    for section <- [
          "健康",
          "拓扑",
          "路由策略",
          "模板来源",
          "审计",
          "高级"
        ] do
      assert html =~ section
    end

    assert html =~ "对象优先"
    assert html =~ "运营活会话优先"

    for operation <- ["read_topology", "routing-rule-add", "templates-read", "migrate_session"] do
      assert html =~ operation
    end

    for authority_term <- [
          "Phase-1 ctx.caller",
          "Phase-2 ctx.caller",
          "authorized_operator_uri",
          "execution_principal_uri",
          "request_id"
        ] do
      assert html =~ authority_term
    end

    for failure_state <- [
          ":manage_unauthorized",
          "{:unknown_member_role, role_name}",
          ":session_not_live"
        ] do
      assert html =~ failure_state
    end

    assert html =~ "session://acme/storefront/storefront-7f3a"
    assert html =~ "template://acme/session/storefront@a1b2c3d4"
    assert html =~ "entity://acme/agent/cc_orchestrator-7f3a"
    refute html =~ "entity://agent/acme"

    assert html =~ "Create / Fork / Tag / publish 均禁用"
    assert html =~ "UI 不铸 cap"
  end
end
