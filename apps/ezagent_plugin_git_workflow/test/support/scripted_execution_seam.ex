defmodule EzagentPluginGitWorkflow.ScriptedExecutionSeam do
  @moduledoc """
  A per-process, scriptable `ExecutionSeam` backend for the Slice P4c stage
  runner tests.

  `EzagentPluginGitWorkflow.FakeExecutionSeam` (P4a) answers every `invoke/3`
  with the same echo, which is enough to prove a call REACHED a backend but
  cannot express "this action fails", "this action raises", or "this action
  was never called at all" — the three things P4c's ordering and non-invocation
  claims are made of. This module adds exactly that and nothing else.

  `authorize/2` is NOT scripted: it delegates to
  `EzagentPluginGitWorkflow.ExecutionSeam.CapBacked`, which is pure and has
  zero side effects on every path. So the `%AuthorizedTask{}` a scripted test
  works against is the real one, derived from the real two durable rows — only
  the INVOCATIONS are stubbed.

  Every `invoke/3` reports `{:seam_invoke, action, args}` to the process that
  installed the script BEFORE it produces its result, so a test can assert
  both what was called and — with `refute_receive` — what was not.

  The script and the reporting target live in the calling process's dictionary,
  same as `ExecutionSeamTestDelegate`'s backend slot: injection is scoped to
  one test process and cannot leak into another.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate

  @script_key {__MODULE__, :script}
  @owner_key {__MODULE__, :owner}

  @doc """
  Installs this backend for the calling process with `script`.

  `script` maps an action to either a literal result (`{:ok, term}` /
  `{:error, term}`) or a one-argument function of the invocation args
  returning one — a function is how a test makes an action RAISE.

  An action with no entry raises: a stage reaching an unscripted action is a
  test that does not describe what it is exercising, and answering it with a
  plausible default is how such a test passes vacuously.
  """
  @spec install(map()) :: :ok
  def install(script) when is_map(script) do
    Process.put(@script_key, script)
    Process.put(@owner_key, self())
    ExecutionSeamTestDelegate.put_backend(__MODULE__)
  end

  @doc "Replaces the script for the calling process, keeping the backend installed."
  @spec rescript(map()) :: :ok
  def rescript(script) when is_map(script) do
    Process.put(@script_key, script)
    :ok
  end

  @impl true
  def authorize(run, binding), do: CapBacked.authorize(run, binding)

  @impl true
  def invoke(_authorized_task, action, typed_args) do
    report(action, typed_args)

    case Map.fetch(Process.get(@script_key, %{}), action) do
      {:ok, fun} when is_function(fun, 1) -> fun.(typed_args)
      {:ok, result} -> result
      :error -> raise "ScriptedExecutionSeam: no script for #{inspect(action)}"
    end
  end

  defp report(action, typed_args) do
    if owner = Process.get(@owner_key), do: send(owner, {:seam_invoke, action, typed_args})
    :ok
  end
end
