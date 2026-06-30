defmodule EzagentPluginWorld.KanbanBindSessionTest do
  use ExUnit.Case, async: true

  test "kanban.bind_session 在 world 动作白名单（UI 可触发）" do
    wl = EzagentPluginWorld.WorldLive.__kanban_actions__()
    assert "kanban.bind_session" in wl
  end
end
