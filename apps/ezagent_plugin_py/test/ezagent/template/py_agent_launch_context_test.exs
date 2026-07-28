defmodule Ezagent.PluginPy.Template.PyAgentLaunchContextTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Template.PyAgent

  test "instantiate/4 forwards the identical launch context to Kind.spawn_receipt/3" do
    launch_context = make_ref()
    config_dir = Path.join(System.tmp_dir!(), "py-launch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config_dir)
    on_exit(fn -> File.rm_rf!(config_dir) end)

    tmpl = %{
      "class" => "py.agent",
      "agent_uri" => "entity://test/agent/py-launch-#{System.unique_integer([:positive])}",
      "allocated_config_dir" => config_dir,
      "script" => "def handle(message):\n    return message\n"
    }

    Ezagent.Agent.TemplateLaunchTrace.trace_call(Ezagent.Kind, :spawn_receipt, 3, fn ->
      assert {:error, _reason} =
               PyAgent.instantiate("py.agent", tmpl, URI.new!("workspace://test"),
                 launch_context: launch_context
               )

      assert_receive {:trace, _, :call,
                      {Ezagent.Kind, :spawn_receipt,
                       [Ezagent.Entity.Agent, _, [launch_context: ^launch_context]]}}
    end)
  end

  test "instantiate/4 rejects non-sole options on otherwise-valid data" do
    tmpl = %{
      "class" => "py.agent",
      "agent_uri" => "entity://test/agent/py-invalid-options",
      "allocated_config_dir" => "/tmp",
      "script" => "def handle(message):\n    return message\n"
    }

    assert {:error, :invalid_launch_options} =
             PyAgent.instantiate("py.agent", tmpl, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  test "instantiate/3 remains available" do
    assert function_exported?(PyAgent, :instantiate, 3)
    assert function_exported?(PyAgent, :instantiate, 4)

    assert {:error, {:invalid_template, %{}}} =
             PyAgent.instantiate("py.agent", %{}, URI.new!("workspace://test"))
  end
end
