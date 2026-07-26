defmodule EzagentPluginGitWorkflow.ExecutionSeamTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable

  @moduletag :execution_seam

  test "implementation/0 defaults to Unavailable when unconfigured" do
    assert ExecutionSeam.implementation() == Unavailable
  end

  test "Unavailable.authorize/2 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} = Unavailable.authorize(:anything, :anything)
    assert {:error, :authorization_unavailable} = Unavailable.authorize(nil, nil)
  end

  test "Unavailable.invoke/3 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} =
             Unavailable.invoke(:anything, :any_action, %{})
  end
end
