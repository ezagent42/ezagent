defmodule EzagentPluginGitWorkflow.ExecutionSeamTest do
  # async: false — "no runtime mutation can change what implementation/0
  # resolves to" deliberately mutates the GLOBAL application environment for
  # this app. The compiled seam is immune to that (it reads a compile-time
  # module attribute), but a concurrent test reading the raw config key could
  # transiently observe the bogus values this test writes.
  use ExUnit.Case, async: false

  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.FakeExecutionSeam

  @moduletag :execution_seam

  test "implementation/0 resolves to the compile-time-selected backend (the test delegate under MIX_ENV=test)" do
    assert ExecutionSeam.implementation() == ExecutionSeamTestDelegate
  end

  test "with no per-process backend installed, the configured implementation fails closed" do
    ExecutionSeamTestDelegate.clear_backend()

    assert {:error, :authorization_unavailable} =
             ExecutionSeam.implementation().authorize(:anything, :anything)

    assert {:error, :authorization_unavailable} =
             ExecutionSeam.implementation().invoke(:anything, :any_action, %{})
  end

  test "put_backend/1 scopes injection to the calling process, clear_backend/0 restores fail-closed" do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)

    assert {:ok, %{authorized: true}} =
             ExecutionSeam.implementation().authorize(%{binding_id: "whatever"}, :some_binding)

    ExecutionSeamTestDelegate.clear_backend()

    assert {:error, :authorization_unavailable} =
             ExecutionSeam.implementation().authorize(:anything, :anything)
  end

  test "Unavailable.authorize/2 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} = Unavailable.authorize(:anything, :anything)
    assert {:error, :authorization_unavailable} = Unavailable.authorize(nil, nil)
  end

  test "Unavailable.invoke/3 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} =
             Unavailable.invoke(:anything, :any_action, %{})
  end

  test "no runtime mutation can change what implementation/0 resolves to" do
    original = ExecutionSeam.implementation()

    on_exit(fn ->
      Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, original)
    end)

    Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, NotARealBackend)
    assert ExecutionSeam.implementation() == original

    Application.put_all_env(ezagent_plugin_git_workflow: [execution_seam: AnotherFakeBackend])
    assert ExecutionSeam.implementation() == original

    :application.set_env(:ezagent_plugin_git_workflow, :execution_seam, YetAnotherOne)
    assert ExecutionSeam.implementation() == original
  end
end
