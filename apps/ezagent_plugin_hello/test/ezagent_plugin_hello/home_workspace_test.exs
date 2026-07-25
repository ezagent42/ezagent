defmodule EzagentPluginHello.HomeWorkspaceTest do
  use ExUnit.Case, async: false

  alias EzagentPluginHello.OfficialSiteSeed

  test "the default home workspace is ezagent" do
    assert EzagentPluginHello.home_workspace() == "ezagent"
  end

  test "a home-workspace override also moves the official site URI" do
    previous = Application.get_env(:ezagent_plugin_hello, :home_workspace)
    Application.put_env(:ezagent_plugin_hello, :home_workspace, "hello-home-override")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezagent_plugin_hello, :home_workspace, previous),
        else: Application.delete_env(:ezagent_plugin_hello, :home_workspace)
    end)

    assert EzagentPluginHello.home_workspace() == "hello-home-override"

    assert OfficialSiteSeed.site_uri() ==
             Ezagent.URI.session("hello-home-override", :hello, "ezagent-official")
  end
end
