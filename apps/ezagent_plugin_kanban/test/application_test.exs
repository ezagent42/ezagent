defmodule EzagentPluginKanban.ApplicationTest do
  use ExUnit.Case, async: true

  test "config_surface 声明 /plugins/kanban 路由入口（Plugins 页可点）" do
    assert %{kind: :route, path: "/plugins/kanban", label: label} =
             EzagentPluginKanban.Application.config_surface()

    assert is_binary(label) and label != ""
  end
end
