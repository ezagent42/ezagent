defmodule Ezagent.PluginNative.Template.NativeAgentLaunchContextTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginNative.Template

  test "instantiate/4 accepts only the launch_context option before template effects" do
    assert {:error, :invalid_launch_options} =
             Template.instantiate("native.agent", %{}, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  test "instantiate/3 remains available" do
    assert function_exported?(Template, :instantiate, 3)
    assert function_exported?(Template, :instantiate, 4)
  end
end
