defmodule Mix.Tasks.Ezagent.Demo.SeedHelloFusionTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    Mix.Task.reenable("ezagent.demo.seed_hello_fusion")
    :ok
  end

  test "prints the stable Fusion session and public URL" do
    output = capture_io(fn -> Mix.Task.run("ezagent.demo.seed_hello_fusion") end)

    # hello-A: the Fusion demo lives in the single-source hello HOME workspace
    # (default "ezagent"), not the retired `system` pin.
    home = EzagentPluginHello.home_workspace()
    assert output =~ "session://#{home}/hello/fusion"
    assert output =~ "/hello/fusion"
  end
end
