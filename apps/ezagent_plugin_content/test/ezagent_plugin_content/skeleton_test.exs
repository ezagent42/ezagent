defmodule EzagentPluginContent.SkeletonTest do
  use ExUnit.Case

  @app :ezagent_plugin_content

  test "priv/skeleton/ files are accessible" do
    assert File.exists?(Path.join(:code.priv_dir(@app), "platform/framework/customer/soul.md"))
    assert File.exists?(Path.join(:code.priv_dir(@app), "platform/templates/customer/soul.md"))
    assert File.exists?(Path.join(:code.priv_dir(@app), "skeleton/config/agents.yaml"))
  end

  test "agents.yaml parses correctly" do
    path = Path.join(:code.priv_dir(@app), "skeleton/config/agents.yaml")
    {:ok, config} = YamlElixir.read_from_file(path)
    assert %{"fast" => %{"provider" => "deepseek", "model" => "deepseek-v4-flash"}} = config
    assert %{"slow" => %{"provider" => "claude", "effort" => "low"}} = config
  end
end
