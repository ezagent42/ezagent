defmodule EzagentPluginGithub.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info slug/name 就位" do
    info = EzagentPluginGithub.Application.plugin_info()
    assert info.slug == "github"
    assert info.name == "GitHub"
    assert info.version == "0.1.0"
  end
end
