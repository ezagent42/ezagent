defmodule EzagentPluginGitWorkflow.ExecutionSeamTestDelegate do
  @moduledoc """
  Test-build-only `ExecutionSeam` backend — the ONLY module `config/test.exs`
  is allowed to name for `:execution_seam` (see
  `EzagentPluginGitWorkflow.ExecutionSeam` moduledoc + `architecture_test.exs`).

  Compiled only under `MIX_ENV=test` (`test/support` is not on the
  `elixirc_paths` for any other env — see `mix.exs`), so this module cannot
  exist in a production or dev build at all, regardless of config.

  `EzagentPluginGitWorkflow.ExecutionSeam.implementation/0` is fixed at
  compile time (`Application.compile_env/3`), so a test cannot inject a fake
  by mutating the global application env anymore — that mutation would have
  zero effect. Instead, this delegator IS the compile-time-selected backend
  for `:test`, and it resolves the REAL per-test backend from **process
  dictionary** state at call time via `put_backend/1`. Because the process
  dictionary is private to the calling process, injection is scoped to a
  single test process: it cannot leak into a concurrently running `async:
  true` test, and it disappears automatically when the test process exits
  (an explicit `clear_backend/0` in `on_exit/1` is still recommended for
  clarity, but is not load-bearing for isolation).

  With no backend installed for the calling process, delegates to
  `EzagentPluginGitWorkflow.ExecutionSeam.Unavailable` — i.e. a test that
  never calls `put_backend/1` observes exactly the same fail-closed
  behavior production does.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable

  @pdict_key {__MODULE__, :backend}

  @doc "Installs `backend` as the ExecutionSeam implementation for the CALLING process only."
  @spec put_backend(module()) :: :ok
  def put_backend(backend) when is_atom(backend) do
    Process.put(@pdict_key, backend)
    :ok
  end

  @doc "Clears this process's backend override, restoring fail-closed (`Unavailable`) behavior."
  @spec clear_backend() :: :ok
  def clear_backend do
    Process.delete(@pdict_key)
    :ok
  end

  @doc "The backend currently installed for the calling process, or `Unavailable` if none."
  @spec current_backend() :: module()
  def current_backend, do: Process.get(@pdict_key, Unavailable)

  @impl true
  def authorize(run, binding), do: current_backend().authorize(run, binding)

  @impl true
  def invoke(authorized_task, action, typed_args),
    do: current_backend().invoke(authorized_task, action, typed_args)
end
