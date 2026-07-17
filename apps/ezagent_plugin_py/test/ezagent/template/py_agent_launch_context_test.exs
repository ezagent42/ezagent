defmodule Ezagent.PluginPy.Template.PyAgentLaunchContextTest do
  use ExUnit.Case, async: true

  alias Ezagent.Template.PyAgent

  test "instantiate/4 accepts only the launch_context option before template effects" do
    assert {:error, :invalid_launch_options} =
             PyAgent.instantiate("py.agent", %{}, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  test "instantiate/3 remains available" do
    assert function_exported?(PyAgent, :instantiate, 3)
    assert function_exported?(PyAgent, :instantiate, 4)
  end
end
