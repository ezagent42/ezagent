defmodule EzagentPluginKanban.ApplicationTest do
  use ExUnit.Case, async: true

  test "config_surface 声明 /plugins/kanban 路由入口（Plugins 页可点）" do
    assert %{kind: :route, path: "/plugins/kanban", label: label} =
             EzagentPluginKanban.Application.config_surface()

    assert is_binary(label) and label != ""
  end

  # nav_surfaces/0 — DELETED（2026-06-30）：看板 = 一个 agent，不占顶层 nav，且
  # `nav_surfaces/0` 已不再是 core 契约 callback（搬到 World UiSurfaceProvider）。
  # 「没这个函数」= 「不贡献顶层 nav」，与原先返 `[]` 等价。故无 nav_surfaces 测试。

  # session_tabs/0 — Layer-3 会话内 kanban tab（实现 World 的 UiSurfaceProvider 约定，
  # 普通 public def，world 经 function_exported? 读取）。一个 session 绑板后多一个 tab。
  test "session_tabs 声明 kanban 会话 tab（绑板可见 condition）" do
    [tab] = EzagentPluginKanban.Application.session_tabs()
    assert tab.id == "kanban"
    assert tab.label == "看板"
    assert is_function(tab.condition, 1)
  end
end
