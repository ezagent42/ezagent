defmodule Ezagent.PluginNative.Template.NativeAgentLaunchContextTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginNative.Template

  test "instantiate/4 forwards the identical launch context to Kind.spawn/3" do
    launch_context = make_ref()

    tmpl = %{
      "class" => "native.agent",
      "agent_uri" => "entity://test/agent/native-launch-#{System.unique_integer([:positive])}"
    }

    Ezagent.Agent.TemplateLaunchTrace.trace_call(Ezagent.Kind, :spawn, 3, fn ->
      assert {:error, _reason} =
               Template.instantiate("native.agent", tmpl, URI.new!("workspace://test"),
                 launch_context: launch_context
               )

      assert_receive {:trace, _, :call,
                      {Ezagent.Kind, :spawn,
                       [Ezagent.Entity.Agent, _, [launch_context: ^launch_context]]}}
    end)
  end

  test "instantiate/4 rejects non-sole options on otherwise-valid data" do
    tmpl = %{
      "class" => "native.agent",
      "agent_uri" => "entity://test/agent/native-invalid-options"
    }

    assert {:error, :invalid_launch_options} =
             Template.instantiate("native.agent", tmpl, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  test "instantiate/3 remains available" do
    assert function_exported?(Template, :instantiate, 3)
    assert function_exported?(Template, :instantiate, 4)

    assert {:error, {:invalid_template, %{}}} =
             Template.instantiate("native.agent", %{}, URI.new!("workspace://test"))
  end
end
