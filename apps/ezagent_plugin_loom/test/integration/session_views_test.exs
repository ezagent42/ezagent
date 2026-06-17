defmodule EzagentPluginLoom.Integration.SessionViewsTest do
  @moduledoc """
  loom 在 admin view-switcher 注册 "Loom"/"Dashboard" 标签(SessionView 插件)。
  迁移自 loom-stitch 的 admin 集成;零改 admin —— loom 自己注册进 SessionViewRegistry。
  """
  use ExUnit.Case, async: true

  alias EzagentPluginLoom.View.{LoomDashboardView, LoomSessionView}

  @loom_uri Ezagent.URI.session("demo", :loom, "main")
  @non_loom_uri Ezagent.URI.session("demo", :default, "main")

  test "view metadata (id/label/icon)" do
    assert LoomSessionView.id() == :loom
    assert LoomSessionView.label() == "Loom"
    assert LoomDashboardView.id() == :loom_dashboard
    assert LoomDashboardView.label() == "Dashboard"
  end

  test "applies_to? only loom sessions" do
    assert LoomSessionView.applies_to?(@loom_uri)
    assert LoomDashboardView.applies_to?(@loom_uri)

    refute LoomSessionView.applies_to?(@non_loom_uri)
    refute LoomDashboardView.applies_to?(@non_loom_uri)
    refute LoomSessionView.applies_to?(Ezagent.URI.workspace("demo"))
  end

  test "loom boot registers both views → admin view-switcher shows them for a loom session" do
    # loom Application.start/2 已在测试启动时注册(register_session_views/0)。
    ids = @loom_uri |> Ezagent.UI.SessionViewRegistry.applicable_views() |> Enum.map(& &1.id)
    assert :loom in ids
    assert :loom_dashboard in ids

    # 非 loom session 不应出现这两个标签。
    non_loom_ids =
      @non_loom_uri |> Ezagent.UI.SessionViewRegistry.applicable_views() |> Enum.map(& &1.id)

    refute :loom in non_loom_ids
    refute :loom_dashboard in non_loom_ids
  end
end
