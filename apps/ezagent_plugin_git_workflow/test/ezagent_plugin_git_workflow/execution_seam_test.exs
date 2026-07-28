defmodule EzagentPluginGitWorkflow.ExecutionSeamTest do
  # async: false — "no runtime mutation can change what implementation/0
  # resolves to" deliberately mutates the GLOBAL application environment for
  # this app. The compiled seam is immune to that (it reads a compile-time
  # module attribute), but a concurrent test reading the raw config key could
  # transiently observe the bogus values this test writes.
  use ExUnit.Case, async: false

  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.FakeExecutionSeam
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture

  @moduletag :execution_seam

  # The eight actions Ezagent.ActionSet.GitTaskAccess declares. Restated here
  # so this test fails if the seam's guard list ever diverges from the
  # ActionSet's — asserting against the seam's own @actions would be circular.
  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace,
    :collect_workspace_changes
  ]

  defp authorized_task do
    {:ok, task} = AuthorizedTask.new(GitTaskAccessFixture.authorized_task_attrs())
    task
  end

  # Elixir 1.19's type checker infers the fixture's concrete shape and warns at
  # the call site about exactly the calls the guard tests exist to prove raise.
  # Routing the value through a `term()`-returning function leaves the RUNTIME
  # value untouched (that is what is under test) without the compile-time noise.
  defp opaque(value), do: Process.get(:__never_set__, value)

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

  test "authorize/2 dispatches to the compile-time-selected backend, failing closed with no per-process backend installed" do
    ExecutionSeamTestDelegate.clear_backend()

    assert {:error, :authorization_unavailable} = ExecutionSeam.authorize(:anything, :anything)
  end

  test "authorize/2 dispatches through an injected fake backend, same as implementation/0 would" do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)

    assert {:ok, %{authorized: true}} =
             ExecutionSeam.authorize(%{binding_id: "whatever"}, :some_binding)

    ExecutionSeamTestDelegate.clear_backend()

    assert {:error, :authorization_unavailable} = ExecutionSeam.authorize(:anything, :anything)
  end

  test "Unavailable.authorize/2 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} = Unavailable.authorize(:anything, :anything)
    assert {:error, :authorization_unavailable} = Unavailable.authorize(nil, nil)
  end

  test "Unavailable.invoke/3 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} =
             Unavailable.invoke(:anything, :any_action, %{})
  end

  test "invoke/3 dispatches to the compile-time-selected backend, failing closed with no per-process backend installed" do
    ExecutionSeamTestDelegate.clear_backend()

    assert {:error, :authorization_unavailable} =
             ExecutionSeam.invoke(authorized_task(), :resolve_repository, %{})
  end

  test "invoke/3 raises rather than dispatching a hand-assembled task" do
    # A map that mimics AuthorizedTask's shape but never went through its
    # validating constructor. Fail closed and LOUD: an {:error, _} here would
    # be indistinguishable from a legitimate refusal in a runner's logs.
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)
    on_exit(&ExecutionSeamTestDelegate.clear_backend/0)

    attrs = GitTaskAccessFixture.authorized_task_attrs()

    assert_raise FunctionClauseError, fn ->
      ExecutionSeam.invoke(opaque(attrs), :resolve_repository, %{})
    end

    assert_raise FunctionClauseError, fn ->
      ExecutionSeam.invoke(opaque(attrs.policy), :resolve_repository, %{})
    end
  end

  test "invoke/3 raises for an action outside the closed vocabulary" do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)
    on_exit(&ExecutionSeamTestDelegate.clear_backend/0)

    task = authorized_task()

    assert_raise FunctionClauseError, fn ->
      ExecutionSeam.invoke(task, :delete_repository, %{})
    end

    assert_raise FunctionClauseError, fn ->
      ExecutionSeam.invoke(task, "resolve_repository", %{})
    end
  end

  test "invoke/3 accepts each of the eight GitTaskAccess actions and reaches the backend" do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)
    on_exit(&ExecutionSeamTestDelegate.clear_backend/0)

    task = authorized_task()

    for action <- @actions do
      assert {:ok, %{reached: :backend, action: ^action, task: ^task}} =
               ExecutionSeam.invoke(task, action, %{}),
             "seam did not pass #{inspect(action)} through to the backend"
    end
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
